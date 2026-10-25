#!/usr/bin/env python3
"""otw_tx_ota.py -- TX OTW converter check over the air (Protocol §10).

There is no digital TX -> RX loopback, so each TX wire format is compared
through the RF link: TX channel --tx sends a known two-tone burst (timed), every
RX channel of tile 0 captures it inside the burst (RX wire --rx-otw, sc16 by
default; sc8 on the sc8-only builds; cpu fc32), and
per capture the complex amplitude of each tone (least-squares fit at the
measured tone frequencies) and the SNR (tone power / fit residual power) are
taken on the RX channel that hears TX best.

Formats are measured round-robin (--reps rounds, each round every TX
(otw, cpu) pair once), so slow drift hits all formats alike. Reported per pair:
mean amplitude (dBFS), amplitude and phase relative to the sc16/fc32 reference
(mean and spread over rounds), SNR. Expected (section 10): sc16, sc12 and fc32
identical within noise; sc8 the same amplitude/phase within its quantisation,
lower SNR (an int8 tone of amplitude 16 LSB: ~32 dB full-band SQNR).

    zcu216-uhd python3 benchmark/otw_tx_ota.py --args type=zcu216,addr=<ip>,channels=4 --rate 625e6
"""
import argparse
import math
import sys

import numpy as np
import uhd

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True)
ap.add_argument("--rate", type=float, default=0.0, help="per-channel rate (0 = the build's)")
ap.add_argument("--freq", type=float, default=950e6, help="RF centre (TX and RX NCO)")
ap.add_argument("--tones", default="3.1e6,-11.7e6", help="baseband tones, Hz")
ap.add_argument("--amp", type=float, default=0.0625,
                help="amplitude per tone (fc32 FS 1); two tones at 0.0625 peak at -18 dBFS")
ap.add_argument("--tx", type=int, default=0, help="TX channel")
ap.add_argument("--rx", default="", help="RX channels considered (default: 0..min(N,4)-1)")
ap.add_argument("--nsamps", type=int, default=65536, help="RX samples per capture")
ap.add_argument("--reps", type=int, default=8)
ap.add_argument("--formats", default="", help="TX otw list (default: every format the build offers)")
ap.add_argument("--max-damp-db", type=float, default=0.5,
                help="pass: |amplitude - reference| for sc16/sc12/fc32 (dB)")
ap.add_argument("--max-dphase-deg", type=float, default=5.0,
                help="pass: |phase - reference| for sc16/sc12/fc32 (deg)")
ap.add_argument("--sc8-damp-db", type=float, default=1.0, help="the same for sc8 (int8 quantisation)")
ap.add_argument("--sc8-dphase-deg", type=float, default=10.0, help="the same for sc8")
ap.add_argument("--min-tnr-db", type=float, default=20.0,
                help="the reference tone must stand this far above the noise bin, else CANNOT TEST")
ap.add_argument("--cpus", default="fc32,sc16")
ap.add_argument("--rx-otw", default="sc16",
                help="RX wire format of the captures (sc8 at an sc8-only rate)")
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
if a.rate:
    usrp.set_rx_rate(a.rate)
    usrp.set_tx_rate(a.rate)
n = usrp.get_tx_num_channels()
rate = usrp.get_rx_rate(0)
chans = list(range(n))
rxch = [int(x) for x in a.rx.split(",")] if a.rx else list(range(min(n, 4)))
for c in chans:
    usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
    usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)
tones = [float(x) for x in a.tones.split(",")]
print(f"N = {n}, {rate / 1e6:g} MS/s per channel, RF {usrp.get_tx_freq(0) / 1e6:g} MHz, TX ch {a.tx}, "
      f"tones {[t / 1e6 for t in tones]} MHz at {20 * math.log10(a.amp):.1f} dBFS each "
      f"(peak {20 * math.log10(a.amp * len(tones)):.1f} dBFS), RX considered {rxch}", flush=True)
for s in ("lo_locked",):
    try:
        print(f"  rx {s}: {usrp.get_rx_sensor(s, 0).value}; tx {s}: "
              f"{usrp.get_tx_sensor(s, 0).value}")
    except Exception as e:  # noqa: BLE001
        print(f"  sensor {s}: {e}")

rsa = uhd.usrp.StreamArgs("fc32", a.rx_otw)
rsa.channels = chans
rxs = usrp.get_rx_stream(rsa)

pairs = []
fmts = [f for f in (a.formats.split(",") if a.formats else ["sc16", "sc12", "sc8", "fc32"])]
cpus = a.cpus.split(",")


def tx_stream(key):
    """the device has ONE TX stream: a new streamer replaces the previous one,
    so every burst gets its own (the old one is dropped first)"""
    sa = uhd.usrp.StreamArgs(key[1], key[0])
    sa.channels = chans
    return usrp.get_tx_stream(sa)


for f in fmts:
    for c in cpus:
        try:
            st = tx_stream((f, c))
            del st
            pairs.append((f, c))
        except Exception as e:  # noqa: BLE001
            print(f"  TX otw={f} cpu={c}: REFUSED: {str(e).splitlines()[0][:200]}", flush=True)
if not pairs:
    sys.exit("no TX format accepted")

lead = 8192
# The TX burst must fit in the FPGA's TX credit (2 MiB) with room to spare,
# so it is wholly buffered before it plays: a burst larger than the buffer
# has to stream in real time and underflows near the link rate. Keep it to
# 1 MiB of the widest format used (fc32: 8 bytes per sample and channel).
wire_bytes = max(8 if o == "fc32" else {"sc16": 4, "sc12": 3, "sc8": 2}[o] for o, _ in pairs)
cap = (1 << 20) // (n * wire_bytes) // 16 * 16
if lead + a.nsamps + 8192 > cap:
    a.nsamps = max(4096, cap - lead - 8192)
    print(f"capture shortened to {a.nsamps} samples/channel: the TX burst fits the FPGA buffer", flush=True)
ntx = lead + a.nsamps + 8192
k = np.arange(ntx)
sig = sum(a.amp * np.exp(2j * np.pi * t / rate * k) for t in tones).astype(np.complex64)
tx_fc32 = np.zeros((n, ntx), dtype=np.complex64)
tx_fc32[a.tx] = sig
iq16 = np.zeros((n, ntx, 2), dtype=np.int16)
iq16[a.tx, :, 0] = np.round(sig.real * 32767).astype(np.int16)
iq16[a.tx, :, 1] = np.round(sig.imag * 32767).astype(np.int16)
tx_sc16 = iq16.view(np.uint32).reshape(n, ntx)
rx = np.zeros((n, a.nsamps), dtype=np.complex64)


def capture(key):
    s = tx_stream(key)
    t0 = usrp.get_time_now().get_real_secs() + 0.1
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = a.nsamps
    cmd.stream_now = False
    cmd.time_spec = uhd.types.TimeSpec(t0 + lead / rate)
    rxs.issue_stream_cmd(cmd)
    md = uhd.types.TXMetadata()
    md.start_of_burst, md.end_of_burst, md.has_time_spec = True, True, True
    md.time_spec = uhd.types.TimeSpec(t0)
    buf = tx_fc32 if key[1] == "fc32" else tx_sc16
    if s.send(buf, md, 1.0) != ntx:
        raise RuntimeError("TX burst not accepted")
    rmd = uhd.types.RXMetadata()
    got = 0
    while got < a.nsamps:
        kk = rxs.recv(rx[:, got:], rmd, 2.0)
        if rmd.error_code != uhd.types.RXMetadataErrorCode.none:
            raise RuntimeError(f"recv: {rmd.strerror()}")
        got += kk
    # TX async: underflow/late would invalidate the burst
    amd = uhd.types.TXAsyncMetadata()
    evs = []
    while s.recv_async_msg(amd, 0.05):
        evs.append(str(amd.event_code).split(".")[-1])
    del s
    return rx.copy(), evs


def analyse(y, fr):
    """y: one channel; fr: tone freqs (Hz, as received). -> amplitudes, snr_db, rms residual"""
    t = np.arange(y.size) / rate
    E = np.stack([np.exp(2j * np.pi * f * t) for f in fr], axis=1)
    A, *_ = np.linalg.lstsq(E, y.astype(np.complex128), rcond=None)
    res = y - E @ A
    pn = np.mean(np.abs(res) ** 2)
    # noise floor: median periodogram bin within +-40 MHz, away from DC and the tones
    N = y.size
    w = np.hanning(N)
    P = np.abs(np.fft.fft(y * w)) ** 2 / np.sum(w ** 2)      # per-bin power, a tone = |A|^2 * N
    fax = np.fft.fftfreq(N, 1 / rate)
    m = np.abs(fax) < min(40e6, 0.4 * rate)
    m &= np.abs(fax) > 0.5e6
    for f in fr:
        m &= np.abs(fax - f) > 0.5e6
    nb = np.median(P[m]) / np.log(2) / N                      # mean noise power per bin (median -> mean of chi2_2)
    tnr = 10 * np.log10(np.min(np.abs(A)) ** 2 / nb)           # weaker tone vs one bin of noise
    return A, (10 * np.log10(np.sum(np.abs(A) ** 2) / pn), tnr, 10 * np.log10(nb)), pn


def spurs(y, fr, k=6):
    """the k strongest residual components after removing the tones"""
    t = np.arange(y.size) / rate
    E = np.stack([np.exp(2j * np.pi * f * t) for f in fr], axis=1)
    A, *_ = np.linalg.lstsq(E, y.astype(np.complex128), rcond=None)
    r = y - E @ A
    R = np.abs(np.fft.fft(r * np.hanning(r.size))) / np.sum(np.hanning(r.size))
    fax = np.fft.fftfreq(r.size, 1 / rate)
    idx = []
    for j in np.argsort(R)[::-1]:
        if all(abs(fax[j] - fax[i]) > 200e3 for i in idx):
            idx.append(j)
        if len(idx) == k:
            break
    return [(fax[j] / 1e6, 20 * np.log10(R[j] + 1e-15)) for j in idx]


def find_freqs(y):
    """measured frequency of each nominal tone (sign as received, refined by zero-padded FFT)"""
    N = y.size
    Y = np.abs(np.fft.fft(y * np.hanning(N), 8 * N))
    fax = np.fft.fftfreq(8 * N, 1 / rate)
    out, sgn = [], None
    for f in tones:
        best = None
        for s in (1, -1):
            j = int(np.argmin(np.abs(fax - s * f)))
            lo, hi = max(0, j - 400), min(Y.size, j + 400)
            jj = lo + int(np.argmax(Y[lo:hi]))
            if best is None or Y[jj] > best[0]:
                best = (Y[jj], s, jj)
        sgn = best[1] if sgn is None else sgn
        j = int(np.argmin(np.abs(fax - sgn * f)))
        lo, hi = max(0, j - 400), min(Y.size, j + 400)
        jj = lo + int(np.argmax(Y[lo:hi]))
        a0, a1, a2 = Y[jj - 1], Y[jj], Y[(jj + 1) % Y.size]
        d = 0.5 * (a0 - a2) / (a0 - 2 * a1 + a2) if (a0 - 2 * a1 + a2) != 0 else 0.0
        out.append(fax[jj] + d * rate / (8 * N))
    return out, sgn


# first capture: pick the RX channel and the received tone frequencies
y0, ev = capture(pairs[0])
lv = []
for r in rxch:
    fr, _ = find_freqs(y0[r])
    A, snr, _ = analyse(y0[r], fr)
    lv.append((snr[1], r))
snr0, r0 = max(lv)
fr, sgn = find_freqs(y0[r0])
print("  RX channel tone-to-noise-bin on the first burst: " + ", ".join(f"rx{r} {s:.1f} dB" for s, r in sorted(lv, key=lambda x: x[1])))
print(f"  using RX {r0}; tones received at {[round(f / 1e3, 3) for f in fr]} kHz "
      f"(nominal {[t / 1e3 for t in tones]} kHz, spectrum sign {sgn:+d})", flush=True)

A1, q1, _ = analyse(y0[r0], fr)
print(f"  first burst: tone levels {[round(20 * np.log10(abs(x)), 2) for x in A1]} dBFS, noise floor "
      f"{q1[2]:.1f} dBFS/bin ({rate / y0.shape[1] / 1e3:.1f} kHz bins), residual after the tones "
      f"{10 * np.log10(_):.1f} dBFS total")
print("  strongest residual components (MHz, dBFS): " + ", ".join(f"{f:+.2f}:{l:.1f}" for f, l in spurs(y0[r0], fr)),
      flush=True)
res = {p: [] for p in pairs}
events = {p: [] for p in pairs}
for rep in range(a.reps):
    for p in pairs:
        y, ev = capture(p)
        fr_m, _ = find_freqs(y[r0])
        A, snr, pn = analyse(y[r0], fr)
        res[p].append((A, snr, pn, fr_m))
        events[p] += ev

ref = ("sc16", "fc32") if ("sc16", "fc32") in res else pairs[0]
Aref = np.mean([x[0] for x in res[ref]], axis=0)
print(f"\nper TX (otw, cpu), {a.reps} rounds, RX {r0}; amplitude/phase relative to {ref[0]}/{ref[1]} "
      f"mean (tone 0 / tone 1); spread = max |round - mean|")
hdr = (f"  {'otw':5s} {'cpu':5s} | {'level dBFS':>13s} | {'d_amp dB':>15s} | {'d_phase deg':>15s} | "
       f"{'amp spread dB':>13s} | {'phase spread deg':>16s} | {'tone/noise-bin dB':>17s} | {'floor dBFS/bin':>14s} | "
       f"{'SINAD dB':>8s} | tx async")
print(hdr)
fails = []
for p in pairs:
    As = np.array([x[0] for x in res[p]])           # reps x tones
    q = np.array([x[1] for x in res[p]])                # reps x (sinad, tnr, floor)
    Am = As.mean(axis=0)
    lvl = 20 * np.log10(np.abs(Am))
    damp = 20 * np.log10(np.abs(Am) / np.abs(Aref))
    dph = np.degrees(np.angle(Am / Aref))
    asp = np.max(np.abs(20 * np.log10(np.abs(As) / np.abs(Am))), axis=0)
    psp = np.max(np.abs(np.degrees(np.angle(As / Am))), axis=0)
    ev = sorted(set(events[p]) - {"burst_ack"}) or ["ok"]
    print(f"  {p[0]:5s} {p[1]:5s} | {lvl[0]:6.2f} {lvl[1]:6.2f} | {damp[0]:+7.3f} {damp[1]:+7.3f} | "
          f"{dph[0]:+7.2f} {dph[1]:+7.2f} | {asp[0]:6.3f} {asp[1]:6.3f} | {psp[0]:7.2f} {psp[1]:7.2f}  | "
          f"{q[:, 1].mean():6.2f} ({q[:, 1].min():.1f}..{q[:, 1].max():.1f}) | {q[:, 2].mean():14.2f} | "
          f"{q[:, 0].mean():8.2f} | {','.join(ev)}")
    lim_a, lim_p = (a.sc8_damp_db, a.sc8_dphase_deg) if p[0] == "sc8" else (a.max_damp_db, a.max_dphase_deg)
    if np.max(np.abs(damp)) > lim_a or np.max(np.abs(dph)) > lim_p:
        fails.append(f"{p[0]}/{p[1]}: amplitude {np.max(np.abs(damp)):.3f} dB (limit {lim_a}), "
                     f"phase {np.max(np.abs(dph)):.2f} deg (limit {lim_p})")
    if ev != ["ok"]:
        fails.append(f"{p[0]}/{p[1]}: TX async events {','.join(ev)}")
tnr_ref = float(np.mean([x[1][1] for x in res[ref]]))
if tnr_ref < a.min_tnr_db:
    print(f"RESULT CANNOT TEST: reference tone {tnr_ref:.1f} dB above the noise bin (< {a.min_tnr_db}) on RX {r0}")
    sys.exit(2)
for f in fails:
    print("  FAIL  " + f)
print(f"RESULT {'PASS' if not fails else 'FAIL'} ({len(pairs)} TX format pairs vs {ref[0]}/{ref[1]}, "
      f"reference tone {tnr_ref:.1f} dB above the noise bin)")
sys.exit(1 if fails else 0)
