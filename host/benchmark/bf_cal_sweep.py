#!/usr/bin/env python3
"""bf_cal_sweep.py -- channel phase offsets measured WITH THE BEAMFORMERS, the
rfsoc_lib/beamformer_task.py way: a tone goes out, the beamformer weights are
stepped, and only the received POWER is used.

Per channel k (k = 1..N-1), weights w0 = 1, wk = exp(j theta), all others 0,
theta swept over 0..360 deg (--step). The two paths add as
    P(theta) = |H0 + Hk exp(j theta)|^2 = A + B cos(theta + phi_k - phi_0),
so the power peaks at theta = -(phi_k - phi_0): offset_k = -theta_peak, with
theta_peak = arg(sum_i P(theta_i) exp(j theta_i)) (the first Fourier
coefficient; exact for this two-path sum, robust to noise).

  NT1R (--mode tx): the TX BEAMFORMER applies the weights (TX channel 0 fanned
      out to every DAC); one capture measures the power at every RX antenna,
      i.e. the N-transmit, 1-receive result for each RX at once.
  1TNR (--mode rx): the RX BEAMFORMER applies the weights to the N ADC
      channels; the power of the beam (RX channel 0) is used; repeated with
      the tone from each TX (--tx all) for the 1-transmit, N-receive result.
Each offset is cross-checked against the direct coherent measurement of the
same channel ratio (bypass captures). Then, like beamformer_task.sweep_beam,
the beam is swept over steering angles (Beamformer weights, -90..90 deg)
without and with the measured calibration (w_c * exp(-j offset_c)): the
calibrated array adds in phase at the steering angle 0 (all weights equal).

    zcu216-uhd python3 benchmark/bf_cal_sweep.py --args type=zcu216,addr=<board-ip>,channels=4 --mode both
"""
import argparse
import math
import sys

import numpy as np
import uhd

TX = dict(en=0, load=15, w0=16, tree="/mboards/0/tx_beamformer")
RX = dict(en=64, load=79, w0=80, shift=68, tree="/mboards/0/rx_beamformer")

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True)
ap.add_argument("--mode", choices=("tx", "rx", "both"), default="both")
ap.add_argument("--freq", type=float, default=950e6)
ap.add_argument("--tone", type=float, default=3.1e6)
ap.add_argument("--amp", type=float, default=0.125)
ap.add_argument("--step", type=float, default=15.0, help="phase sweep step, deg")
ap.add_argument("--tx", default="all", help="1TNR: transmitting channel(s): 'all' or a list '0,2'")
ap.add_argument("--sweep", default="-90:90:5", help="steering sweep start:stop:step, deg ('' = off)")
ap.add_argument("--nsamps", type=int, default=8192)
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
tree = usrp.get_tree()
n = usrp.get_rx_num_channels()
rate = usrp.get_rx_rate(0)
chans = list(range(n))
for c in chans:
    usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
    usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)
for bf in (TX, RX):
    if not tree.exists(bf["tree"] + "/enable"):
        sys.exit(f"this build has no {bf['tree']} (an N >= 2 bitstream with both beamformers)")
usrp.set_user_register(TX["en"], 0)
usrp.set_user_register(RX["en"], 0)
sa = uhd.usrp.StreamArgs("fc32", "sc16")
sa.channels = chans
rxs = usrp.get_rx_stream(sa)
txs = usrp.get_tx_stream(sa)
L = int(math.log2(n))
lead = 4096
ntx = lead + a.nsamps + 2048
tone = (a.amp * np.exp(2j * np.pi * a.tone * np.arange(ntx) / rate)).astype(np.complex64)
tt = np.arange(a.nsamps) / rate
sign = [None]


def capture(t_ch):
    """tone on TX stream channel t_ch; complex tone amplitude per RX channel"""
    tx = np.zeros((n, ntx), dtype=np.complex64)
    tx[t_ch] = tone
    t0 = usrp.get_time_now().get_real_secs() + 0.1
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = a.nsamps
    cmd.stream_now = False
    cmd.time_spec = uhd.types.TimeSpec(t0 + lead / rate)
    rxs.issue_stream_cmd(cmd)
    md = uhd.types.TXMetadata()
    md.start_of_burst, md.end_of_burst, md.has_time_spec = True, True, True
    md.time_spec = uhd.types.TimeSpec(t0)
    txs.send(tx, md, 1.0)
    rx = np.zeros((n, a.nsamps), dtype=np.complex64)
    rmd = uhd.types.RXMetadata()
    got = 0
    while got < a.nsamps:
        k = rxs.recv(rx[:, got:], rmd, 2.0)
        if rmd.error_code != uhd.types.RXMetadataErrorCode.none:
            raise RuntimeError(rmd.strerror())
        got += k
    if sign[0] is None:
        p = np.abs(rx @ np.exp(-2j * np.pi * a.tone * tt)).sum()
        m = np.abs(rx @ np.exp(+2j * np.pi * a.tone * tt)).sum()
        sign[0] = 1 if p >= m else -1
    return rx @ np.exp(-2j * np.pi * sign[0] * a.tone * tt) / a.nsamps


def load(bf, w, shift=None):
    for c in chans:
        re, im = int(round(w[c].real)), int(round(w[c].imag))
        usrp.set_user_register(bf["w0"] + c, (re & 0xFFFF) | ((im & 0xFFFF) << 16))
    if shift is not None:
        usrp.set_user_register(bf["shift"], shift)
    usrp.set_user_register(bf["load"], 1)


def wrap(d):
    return (np.asarray(d) + 180.0) % 360.0 - 180.0


def peak_phase(thetas, powers):
    """theta at the maximum of A + B cos(theta - theta0)"""
    return math.degrees(np.angle(np.sum(np.asarray(powers) * np.exp(1j * np.radians(thetas)))))


def steering(angle):
    car = tree.access_double("/mboards/0/tx_beamformer/carrier_freq").get()
    d = tree.access_double("/mboards/0/tx_beamformer/element_spacing").get()
    dphi = -2 * math.pi * d * math.sin(math.radians(angle)) / (299792458.0 / car)
    return np.exp(1j * dphi * np.arange(n))


def db(x):
    return 10 * math.log10(max(float(x), 1e-30))


thetas = np.arange(0.0, 360.0, a.step)
print(f"N = {n}, {rate / 1e6:g} MS/s, RF {a.freq / 1e6:g} MHz, tone {a.tone / 1e6:g} MHz at "
      f"{20 * math.log10(a.amp):.1f} dBFS; phase sweep 0..360 deg in {a.step:g} deg steps (power only)")

# direct (coherent) reference: the full matrix, both beamformers in bypass
Hd = np.array([capture(t) for t in chans]).T         # Hd[r, t]


def sweep_report(name, label_of, off_bf, off_direct):
    print(f"   {name}: offset (deg)  " + "  ".join(f"{label_of(k)} {off_bf[k]:+7.1f}" for k in chans))
    err = [abs(wrap(off_bf[k] - off_direct[k])) for k in chans[1:]]
    print(f"      direct (coherent)   " + "  ".join(f"{label_of(k)} {off_direct[k]:+7.1f}" for k in chans)
          + f"   |beamformer - direct| max {max(err):.2f} deg")
    return max(err)


worst = 0.0
cal_tx = {}
if a.mode in ("tx", "both"):
    print(f"\n{n}T1R with the TX beamformer (w0 = 1, wk = exp(j theta); power at every RX):")
    usrp.set_user_register(TX["en"], 1)
    P = np.zeros((n, n, len(thetas)))                # P[k, r, i]
    for k in chans[1:]:
        for i, th in enumerate(thetas):
            w = np.zeros(n, dtype=complex)
            w[0] = 32767
            w[k] = 32767 * np.exp(1j * math.radians(th))
            load(TX, w)
            P[k, :, i] = np.abs(capture(0)) ** 2
    usrp.set_user_register(TX["en"], 0)
    for r in chans:
        off = [0.0] + [wrap(-peak_phase(thetas, P[k, r])) for k in chans[1:]]
        direct = [0.0] + [wrap(math.degrees(np.angle(Hd[r, k] / Hd[r, 0]))) for k in chans[1:]]
        depth = [db(P[k, r].max() / max(P[k, r].min(), 1e-30)) for k in chans[1:]]
        worst = max(worst, sweep_report(f"at RX{r}", lambda k: f"TX{k}", off, direct))
        print(f"      sweep depth (max/min power) " + "  ".join(f"TX{k} {d:5.1f} dB" for k, d in zip(chans[1:], depth)))
        cal_tx[r] = np.array(off)

cal_rx = {}
if a.mode in ("rx", "both"):
    txl = chans if a.tx == "all" else [int(x) for x in a.tx.split(",")]
    print(f"\n1T{n}R with the RX beamformer (w0 = 1, wk = exp(j theta); power of the beam, RX channel 0):")
    usrp.set_user_register(RX["en"], 1)
    for t in txl:
        P = np.zeros((n, len(thetas)))
        for k in chans[1:]:
            for i, th in enumerate(thetas):
                w = np.zeros(n, dtype=complex)
                w[0] = 32767
                w[k] = 32767 * np.exp(1j * math.radians(th))
                load(RX, w, shift=0)
                P[k, i] = abs(capture(t)[0]) ** 2
        off = [0.0] + [wrap(-peak_phase(thetas, P[k])) for k in chans[1:]]
        direct = [0.0] + [wrap(math.degrees(np.angle(Hd[k, t] / Hd[0, t]))) for k in chans[1:]]
        worst = max(worst, sweep_report(f"from TX{t}", lambda k: f"RX{k}", off, direct))
        cal_rx[t] = np.array(off)
    usrp.set_user_register(RX["en"], 0)

if a.sweep:
    lo, hi, st = (float(x) for x in a.sweep.split(":"))
    angles = np.arange(lo, hi + st / 2, st)
    if cal_tx:
        r = max(cal_tx, key=lambda rr: np.sum(np.abs(Hd[rr])))
        print(f"\nTX steering sweep (beamformer_task style), power at RX{r}, without / with the calibration "
              f"exp(-j offset) measured at RX{r}:")
        usrp.set_user_register(TX["en"], 1)
        for lab, cal in (("raw       ", np.zeros(n)), ("calibrated", cal_tx[r])):
            lv = []
            for ang in angles:
                load(TX, np.round(32767 * steering(ang) * np.exp(-1j * np.radians(cal))))
                lv.append(db(abs(capture(0)[r]) ** 2))
            print(f"   {lab}: peak {max(lv):6.1f} dB at {angles[int(np.argmax(lv))]:+g} deg; "
                  f"at 0 deg {lv[int(np.argmin(np.abs(angles)))]:6.1f} dB")
        usrp.set_user_register(TX["en"], 0)
    if cal_rx:
        t = max(cal_rx, key=lambda tt_: np.sum(np.abs(Hd[:, tt_])))
        print(f"RX steering sweep, beam power with the tone from TX{t}, without / with the calibration:")
        usrp.set_user_register(RX["en"], 1)
        for lab, cal in (("raw       ", np.zeros(n)), ("calibrated", cal_rx[t])):
            lv = []
            for ang in angles:
                load(RX, np.round(32767 * steering(ang) * np.exp(-1j * np.radians(cal))), shift=L)
                lv.append(db(abs(capture(t)[0]) ** 2))
            print(f"   {lab}: peak {max(lv):6.1f} dB at {angles[int(np.argmax(lv))]:+g} deg; "
                  f"at 0 deg {lv[int(np.argmin(np.abs(angles)))]:6.1f} dB")
        usrp.set_user_register(RX["en"], 0)

print(f"\nRESULT: beamformer power-sweep offsets agree with the direct measurement within {worst:.2f} deg")
