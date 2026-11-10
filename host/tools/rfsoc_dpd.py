#!/usr/bin/env python3
"""rfsoc_dpd.py -- the board's TX DPD (Protocol §12) from Python with the stock
UHD API: check that the FPGA predistorts as its model says, and fit a set to
the TX chain (indirect learning, rfsoc_lib/dsp/dpd.py).

The DPD is the last block before each DAC (eth100g/tx_dpd); the property tree
drives it per converter channel c: /mboards/0/tx_dpd/<c>/{enable, coefs_q21,
gain_bound, stats, clear_stats, reset}. Run as root through the wrapper:

    uhd-rfsoc python3 tools/rfsoc_dpd.py --args type=rfsoc,addr=<board-ip> --check
    uhd-rfsoc python3 tools/rfsoc_dpd.py --args ... --fit 4 [--keep]
    uhd-rfsoc python3 tools/rfsoc_dpd.py --args ... --reset

Every measurement is one timed TX burst of --periods periods of a looping,
band-limited noise waveform x (occupied bandwidth --bw x rate, peak --peak x
full scale, sent in sc16 so the DAC input is exactly the model's) and one
timed RX capture of the periods after the first (the first one fills the
DPD's and the loop's memory): the periods are averaged into one, y. The TX
channel --chan must reach the RX channel --rx-chan (cable with attenuation,
a PA with a coupler, or the air).

--check (a near-linear loop: a cable with attenuation, or a PA well backed
off -- T2 sees the loop as the linear H; no PA nonlinearity is needed):
  T0 bypass, twice: the loop's noise floor (NMSE between the two);
  T1 identity with the DPD path on: must equal bypass to the noise floor
     (the identity set is bit-exact);
  T2 a strong nonlinear test set S that passes the model's gate: the measured
     change of the loop output must be the model's change seen through the
     loop -- Y_S = H Z_S per DFT bin, H = Y_bypass / X, Z_S the bit-exact
     model output -- to --match-db (in-band bins);
  the bypass reference of T1 and T2 is the mean of the bypass captures just
  before and after (a loop's gain drifts while the board warms up);
  T3 the DPD statistics of the T2 burst equal the model's of that burst
     (zero history before it): input and output peak, saturation counts.
--fit N: N indirect-learning iterations (damped, every set through the
  model's gate before it is committed, the loop gain fixed from the identity
  capture); per iteration NMSE and ACPR against x. The best-ACPR set (or
  identity, if none is better) is left committed and enabled with --keep,
  else every channel is reset to bypass + identity.

A real ADC behind a complex NCO folds the carrier's mirror to 2 x carrier: the
tool says where it lands in the capture and refuses a carrier whose image
falls inside the ACPR bands (pick another --freq or a lower --rate).

Prints one 'PASS' / 'FAIL' line for --check (exit 0 on PASS), one table row
per iteration for --fit.
"""
import argparse
import os
import sys
import time

import numpy as np
import uhd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rfsoc"))   # rfsoc_lib (numpy only)
from rfsoc_lib.dsp import dpd  # noqa: E402

T = uhd.types


def waveform(n: int, bw: float, peak: float, seed: int) -> np.ndarray:
    """One period of band-limited complex noise (|f| < bw/2 of the rate),
    int16-valued complex, peak `peak` x full scale; exactly periodic."""
    rng = np.random.default_rng(seed)
    f = np.fft.fftfreq(n)
    spec = (rng.normal(size=n) + 1j * rng.normal(size=n)) * (np.abs(f) < bw / 2) * (f != 0)
    x = np.fft.ifft(spec)
    x *= peak * 32767 / np.abs(x).max()
    return np.rint(x.real) + 1j * np.rint(x.imag)


def image_offset(carrier: float, fs: float) -> float:
    """Where the mirror of a carrier lands after a real ADC and an NCO at
    -carrier: at -2 x carrier, folded into +-fs/2."""
    return ((-2.0 * carrier + fs / 2) % fs) - fs / 2


class Loop:
    """The TX -> RX loop of one channel pair, through the UHD module."""

    def __init__(self, a):
        self.a = a
        self.usrp = uhd.usrp.MultiUSRP(a.args)
        u = self.usrp
        u.set_tx_rate(a.rate, a.chan)
        self.rate = u.get_tx_rate(a.chan)
        u.set_rx_freq(T.TuneRequest(a.freq), a.rx_chan)
        u.set_tx_freq(T.TuneRequest(a.freq), a.chan)
        if a.rx_gain is not None:
            u.set_rx_gain(a.rx_gain, a.rx_chan)
        self.tick = u.get_master_clock_rate()
        self.tps = self.tick / self.rate
        u.set_time_now(T.TimeSpec(0.0))
        time.sleep(0.1)
        self.tree = u.get_tree()
        self.base = f"/mboards/0/tx_dpd/{a.chan}"
        if not self.tree.exists(self.base + "/enable"):
            raise SystemExit("rfsoc_dpd: the loaded build has no TX DPD (Protocol §12; info dpd=0)")
        sa = uhd.usrp.StreamArgs("fc32", "sc16")
        sa.channels = [a.rx_chan]
        self.rx = u.get_rx_stream(sa)
        sa = uhd.usrp.StreamArgs("sc16", "sc16")
        sa.channels = [a.chan]
        self.tx = u.get_tx_stream(sa)

    # -- the DPD, through the tree -----------------------------------------
    def commit(self, cq: np.ndarray) -> None:
        self.tree.access_str(self.base + "/coefs_q21").set(
            ",".join(str(int(v)) for v in np.asarray(cq).reshape(-1)))

    def enable(self, on: bool) -> None:
        self.tree.access_bool(self.base + "/enable").set(bool(on))

    def reset(self) -> None:
        self.tree.access_bool(self.base + "/reset").set(True)

    def clear_stats(self) -> None:
        self.tree.access_bool(self.base + "/clear_stats").set(True)

    def stats(self) -> dict:
        s = self.tree.access_str(self.base + "/stats").get()
        return {k: int(v) for k, v in (x.split("=") for x in s.split(";"))}

    def read_set(self) -> np.ndarray:
        q = self.tree.access_str(self.base + "/coefs_q21").get()
        return np.array([int(v) for v in q.split(",")], dtype=np.int64).reshape(dpd.NCOEF, 2)

    # -- one measurement -----------------------------------------------------
    def measure(self, x: np.ndarray, tries: int = 3) -> np.ndarray:
        """One period of the loop output for the looping waveform x (complex
        int), the mean of periods-1 captured periods; a burst with a TX
        underflow, late start or an RX error is measured again."""
        a, n = self.a, x.size
        iq = np.zeros((n * a.periods, 2), dtype=np.int16)
        iq[:, 0] = np.tile(x.real, a.periods).astype(np.int16)
        iq[:, 1] = np.tile(x.imag, a.periods).astype(np.int16)
        burst = iq.view(np.uint32).reshape(1, -1)
        ncap = n * (a.periods - 2)
        for _ in range(tries):
            now = self.usrp.get_time_now().get_real_secs()
            q = int(round(16 * self.tps))
            t0 = (int(round((now + 0.15) * self.tick)) // q) * q
            cmd = T.StreamCMD(T.StreamMode.num_done)
            cmd.num_samps = ncap
            cmd.stream_now = False
            cmd.time_spec = T.TimeSpec.from_ticks(t0 + int(round(n * self.tps)), self.tick)
            self.rx.issue_stream_cmd(cmd)
            md = T.TXMetadata()
            md.start_of_burst, md.end_of_burst, md.has_time_spec = True, True, True
            md.time_spec = T.TimeSpec.from_ticks(t0, self.tick)
            if self.tx.send(burst, md, 2.0) != burst.shape[1]:
                raise RuntimeError("TX burst not accepted")
            buf = np.zeros((1, ncap), dtype=np.complex64)
            got, err = 0, None
            rmd = T.RXMetadata()
            while got < ncap:
                k = self.rx.recv(buf[:, got:], rmd, 2.0)
                if rmd.error_code != T.RXMetadataErrorCode.none:
                    err = rmd.strerror()
                    break
                got += k
            evs = []
            amd = T.TXAsyncMetadata()
            while self.tx.recv_async_msg(amd, 0.05):
                c = amd.event_code
                if c != T.TXMetadataEventCode.burst_ack:
                    evs.append(str(c).split(".")[-1])
            if err is None and not evs:
                return buf[0].reshape(a.periods - 2, n).astype(np.complex128).mean(axis=0)
            print(f"  burst discarded: {err or ''} {' '.join(evs)}", flush=True)
            time.sleep(0.1)
        raise RuntimeError("no clean burst in %d tries" % tries)


def inband(n: int, bw: float) -> np.ndarray:
    f = np.fft.fftfreq(n)
    return (np.abs(f) < bw / 2) & (f != 0)


def nmse_bins(a: np.ndarray, b: np.ndarray, sel: np.ndarray) -> float:
    """NMSE of spectrum a against b over the bins sel (dB)."""
    e = np.sum(np.abs(a[sel] - b[sel]) ** 2)
    return 10 * np.log10(max(e, 1e-300) / np.sum(np.abs(b[sel]) ** 2))


def test_set(x: np.ndarray) -> np.ndarray:
    """A strong but safe nonlinear set for --check: compression, memory and a
    lag term, scaled down until the model's gate passes for x."""
    for s in np.linspace(1.0, 0.1, 10):
        c = np.zeros(dpd.NCOEF, complex)
        c[0] = 0.9
        c[dpd.idx_a(0, 1)] = s * (-1.2 + 0.6j)
        c[dpd.idx_a(0, 2)] = s * 0.8
        c[dpd.idx_a(1, 0)] = 0.15 - 0.1j
        c[dpd.idx_a(1, 1)] = s * 0.3j
        c[dpd.idx_b(0, 1)] = s * 0.25
        cq = dpd.quantize(c)
        if dpd.gate(x, cq)[0]:
            return cq
    raise RuntimeError("no test set passes the gate at this drive (lower --peak)")


def run_check(lp: Loop, x: np.ndarray) -> bool:
    a, n = lp.a, x.size
    sel = inband(n, a.bw)
    X = np.fft.fft(x)
    lp.reset()
    y0 = lp.measure(x)
    y0b = lp.measure(x)
    Y0, Y0b = np.fft.fft(y0), np.fft.fft(y0b)
    floor = nmse_bins(Y0b, Y0, sel)
    snr = -floor
    print(f"T0 bypass: loop noise floor {floor:.1f} dB (in-band, two captures); "
          f"loop gain {20 * np.log10(np.sqrt(np.sum(np.abs(Y0[sel]) ** 2) / np.sum(np.abs(X[sel] / 32768) ** 2))):.1f} dB")
    # Every DPD capture is compared with the mean of the bypass captures just
    # before and after it: the loop's gain drifts (a board warms up for
    # minutes after a load: ~0.05 dB/s measured), which a reference from
    # earlier would add to the result; a linear drift cancels in the mean.
    lp.enable(True)
    Y1 = np.fft.fft(lp.measure(x))
    lp.enable(False)
    Y1b = np.fft.fft(lp.measure(x))
    ref1 = (Y0b + Y1b) / 2
    t1 = nmse_bins(Y1, ref1, sel)
    ok1 = t1 < floor + 3.0
    print(f"T1 identity, DPD on: {t1:.1f} dB vs bypass before / after (floor {floor:.1f}): "
          f"{'PASS' if ok1 else 'FAIL'}")
    cq = test_set(x)
    lp.commit(cq)                          # with the mode unchanged: still bypass
    back = lp.read_set()
    ok_rb = np.array_equal(back, cq)
    lp.enable(True)
    lp.clear_stats()
    y2 = lp.measure(x)
    st = lp.stats()
    lp.enable(False)
    Y2b = np.fft.fft(lp.measure(x))
    Y0 = (Y1b + Y2b) / 2                   # the bypass output around the T2 capture
    r = dpd.dpd_fx_periodic(x, cq)
    Z = np.fft.fft((r.i + 1j * r.q))
    H = np.zeros(n, complex)
    H[sel] = Y0[sel] / X[sel]
    Y2 = np.fft.fft(y2)
    pred = H * Z
    eff = nmse_bins(Y2, Y0, sel)            # how much the set changed the output
    match = nmse_bins(Y2, pred, sel)         # measured against loop x model
    g = np.vdot(pred[sel], Y2[sel]) / np.vdot(pred[sel], pred[sel])
    ok2 = match < a.match_db and eff > match + 10.0
    print(f"T2 test set (gain bound {dpd.gain_bound(cq):.2f}): measured change {eff:.1f} dB, "
          f"measured vs loop x model {match:.1f} dB (gain {abs(g):.3f}, {np.degrees(np.angle(g)):+.1f} deg; "
          f"floor {floor:.1f}); read-back {'ok' if ok_rb else 'WRONG'}: {'PASS' if ok2 and ok_rb else 'FAIL'}")
    # the burst as the DPD saw it: zero history before it (the DAC idles at
    # zero), then the 3-sample tail after it -- counted only if the player
    # keeps the beats valid while idle, so either peak / count is the model's
    b = np.tile(x, a.periods)
    runs = []
    for tail in (0, 16):
        rb = dpd.dpd_fx(np.r_[b.real, np.zeros(tail)], np.r_[b.imag, np.zeros(tail)], [cq])
        runs.append((int(max(np.abs(rb.i).max(), np.abs(rb.q).max())),
                     int(rb.sat_out.sum()), int(rb.sat_gain.sum())))
    got = (st["peak_out"], st["sat_out"], st["sat_gain"])
    pin = int(np.abs(np.r_[x.real, x.imag]).max())
    ok3 = got in runs and st["peak_in"] == pin
    print(f"T3 statistics of the burst: peak_in {st['peak_in']} (x {pin}), peak_out {got[0]}, "
          f"sat_out {got[1]}, sat_gain {got[2]}; model {runs[0]} (with the idle tail {runs[1]}): "
          f"{'PASS' if ok3 else 'FAIL'}")
    lp.reset()
    ok = ok1 and ok2 and ok3 and ok_rb
    print(f"{'PASS' if ok else 'FAIL'} tx_dpd ch{a.chan} -> rx ch{a.rx_chan} at {lp.rate / 1e6:g} MS/s, "
          f"{a.freq / 1e6:g} MHz: identity {t1:.1f} dB, model match {match:.1f} dB over a "
          f"{eff:.1f} dB change, loop SNR {snr:.1f} dB")
    return ok


def run_fit(lp: Loop, x: np.ndarray) -> None:
    a = lp.a
    lp.reset()
    lp.enable(True)
    cq, gain = dpd.identity_q(), None
    best = None
    print(f"{'it':>3} {'NMSE dB':>8} {'ACPR lo':>8} {'ACPR hi':>8} {'fit dB':>7} {'peak':>6}  set")
    for it in range(a.fit + 1):
        y = lp.measure(x)
        m = dpd.measure(y, x, 1.0, a.bw)
        worst = max(m["acpr_lo"], m["acpr_hi"])
        tag = "identity" if it == 0 else f"ILA {it}"
        line = f"{it:>3} {m['nmse_db']:8.2f} {m['acpr_lo']:8.2f} {m['acpr_hi']:8.2f}"
        if best is None or worst < best[0]:
            best = (worst, cq, it)
        if it == a.fit:
            print(line + f" {'':>7} {'':>6}  {tag}")
            break
        res = dpd.ila_step(x, cq, y, gain=gain, damping=1.0 if it == 0 else a.damping)
        gain = res.gain if gain is None else gain
        try:
            nq = dpd.quantize(res.c)
        except ValueError as e:
            print(line + f"  stop: {e}")
            break
        ok, peak, so, sg = dpd.gate(x, nq)
        print(line + f" {res.fit_nmse_db:7.1f} {peak:6d}  {tag}")
        if not ok:
            print(f"    gate: the next set peaks at {peak} with sat {so}/{sg}: not committed; stop")
            break
        cq = nq
        lp.commit(cq)
    worst, cq, it = best
    if a.keep:
        lp.commit(cq)
        lp.enable(it > 0)
        print(f"kept: iteration {it} (worst ACPR {worst:.2f} dBc), "
              f"{'enabled' if it > 0 else 'bypass'}; set {','.join(str(int(v)) for v in cq.reshape(-1))}")
    else:
        lp.reset()
        print(f"best: iteration {it} (worst ACPR {worst:.2f} dBc); DPD reset to bypass + identity")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--args", default="type=rfsoc")
    ap.add_argument("--chan", type=int, default=0, help="TX (and DPD) channel")
    ap.add_argument("--rx-chan", type=int, help="RX channel of the loop (default: --chan)")
    ap.add_argument("--rate", type=float, default=62.5e6, help="sample rate (a template factor)")
    ap.add_argument("--freq", type=float, default=1e9, help="carrier, TX and RX")
    ap.add_argument("--rx-gain", type=float)
    ap.add_argument("--bw", type=float, default=0.25, help="occupied bandwidth / rate")
    ap.add_argument("--peak", type=float, default=0.5, help="waveform peak / full scale")
    ap.add_argument("--period", type=int, default=8192, help="waveform period, samples (x16)")
    ap.add_argument("--periods", type=int, default=10, help="periods per burst (>= 3)")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--match-db", type=float, default=-25.0,
                    help="--check pass: measured vs loop x model, dB")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--fit", type=int, metavar="N")
    g.add_argument("--reset", action="store_true")
    ap.add_argument("--damping", type=float, default=0.6)
    ap.add_argument("--keep", action="store_true", help="--fit: leave the best set committed")
    a = ap.parse_args()
    if a.rx_chan is None:
        a.rx_chan = a.chan
    if a.period % 16 or a.periods < 3:
        raise SystemExit("--period must be a multiple of 16, --periods >= 3")
    lp = Loop(a)
    if a.reset:
        lp.reset()
        print(f"tx_dpd ch{a.chan}: bypass + identity")
        return 0
    # the converter rate: the FRONTEND range is the first Nyquist zone 0 .. fs/2
    # (§3; get_rx_freq_range() is widened by the DSP part, +-rate/2)
    fs = 2.0 * lp.usrp.get_fe_rx_freq_range(a.rx_chan).stop()
    img = image_offset(a.freq, fs)
    print(f"ADC image of the carrier at {img / 1e6:+.1f} MHz (fs {fs / 1e6:g} MS/s)")
    if abs(img) < 1.5 * a.bw * lp.rate:
        raise SystemExit(f"the ADC image of {a.freq / 1e6:g} MHz lands at {img / 1e6:+.1f} MHz, inside "
                         f"the ACPR bands: pick another --freq")
    x = waveform(a.period, a.bw, a.peak, a.seed)
    print(f"{lp.rate / 1e6:g} MS/s, carrier {a.freq / 1e6:g} MHz, period {a.period}, bw {a.bw * lp.rate / 1e6:g} MHz, "
          f"peak {a.peak:g} FS, {a.periods} periods per burst", flush=True)
    if a.check:
        return 0 if run_check(lp, x) else 1
    run_fit(lp, x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
