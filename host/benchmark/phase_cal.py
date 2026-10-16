#!/usr/bin/env python3
"""phase_cal.py -- inter-channel phase calibration with the TX and RX
beamformers, then the residual phase offsets measured WITH the calibration
applied (Protocol §11), over the air, through stock UHD calls.

  calibrate --out cal.json [--method null|peak|matrix]
      Stores the per-channel offsets (calibration weight exp(-j * offset),
      Q1.15, |w| = 1):
        null    (default) the rfsoc_lib ArrayCalibTask procedure, NT1R and
                1TNR: only channel 0 (weight 1) and channel k (weight
                exp(j theta)) on, received POWER only, theta swept 0..360 in
                --coarse steps then +/-30 deg in --fine steps around the null
                (rfsoc_lib.dsp.phase_search); offset_k = -(theta_null + 180),
                theta_null from a cosine fit to every point (--estimator fit,
                default) or the lowest point (argmin, as ArrayCalibTask).
                TX at the reference RX, RX (beam output) from the reference TX.
        peak    the same search around the power peak; offset_k = -theta_peak.
        matrix  complex samples instead of power: the NxN matrix H[r, t]
                (each TX alone, beamformers in bypass), tx[t] = arg(H[r_ref, t]
                / H[r_ref, 0]), rx[r] = arg(H[r, t_ref] / H[0, t_ref]).
  verify --cal cal.json
      Loads the calibration into the beamformers and measures what is left:
        direct   one calibrated path at a time (one-hot weight w_c = cal_c): its
                 phase relative to channel 0 at the reference RX / from the
                 reference TX -- 0 deg for a perfect calibration;
        null     the null search again, on top of the calibration (w0 = cal_0,
                 wk = cal_k * exp(j theta)); 0 deg for a perfect calibration;
                 --estimator picks the cosine fit (default) or the argmin;
        coherent all calibrated weights at once: |y| / sum_c |y_c|
                 (1.0 = every path in phase).
      Also reports the residuals at the other RX / from the other TX: the
      calibration holds for its reference antenna, the over-the-air geometry
      differs for the others.

    zcu216-uhd python3 benchmark/phase_cal.py calibrate --args type=zcu216,addr=<board-ip>,channels=4 --out cal.json
    zcu216-uhd python3 benchmark/phase_cal.py verify    --args type=zcu216,addr=<board-ip>,channels=4 --cal cal.json
"""
import argparse
import json
import math
import sys
import time

import os

import numpy as np
import uhd

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "rfsoc")))
from rfsoc_lib.dsp.phase_search import calib_phase, phase_search  # noqa: E402

TX = dict(en=0, load=15, w0=16)
RX = dict(en=64, load=79, w0=80, shift=68)

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("cmd", choices=("calibrate", "verify"))
ap.add_argument("--args", required=True)
ap.add_argument("--freq", type=float, default=950e6)
ap.add_argument("--tone", type=float, default=3.1e6)
ap.add_argument("--amp", type=float, default=0.125, help="-18 dBFS: the TX analog chain compresses near -6 dBFS")
ap.add_argument("--nsamps", type=int, default=8192)
ap.add_argument("--rx-ref", type=int, default=1, help="reference RX of the TX calibration")
ap.add_argument("--tx-ref", type=int, default=0, help="reference TX of the RX calibration")
ap.add_argument("--method", choices=("null", "peak", "matrix"), default="null",
                help="calibrate: power null search (ArrayCalibTask), power peak search, or complex matrix")
ap.add_argument("--estimator", choices=("fit", "argmin"), default="fit",
                help="search: fit A + B cos(theta - theta0) to every point, or take the single extreme point "
                     "(ArrayCalibTask); the fit survives shallow nulls")
ap.add_argument("--coarse", type=float, default=15.0, help="search: coarse step over 0..360, deg")
ap.add_argument("--fine", type=float, default=1.0, help="search: fine step around the null/peak, deg")
ap.add_argument("--reps", type=int, default=3, help="calibrate --method matrix: matrices averaged")
ap.add_argument("--max-residual-deg", type=float, default=10.0,
                help="verify pass: every residual offset (direct and null search, TX and RX) within this")
ap.add_argument("--min-coherent", type=float, default=0.9,
                help="verify pass: calibrated coherent gain, TX and RX, at least this (1.0 = ideal)")
ap.add_argument("--out", default="phase_cal.json")
ap.add_argument("--cal", default="phase_cal.json")
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
n = usrp.get_rx_num_channels()
rate = usrp.get_rx_rate(0)
chans = list(range(n))
for c in chans:
    usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
    usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)
usrp.set_user_register(TX["en"], 0)
usrp.set_user_register(RX["en"], 0)
sa = uhd.usrp.StreamArgs("fc32", "sc16")
sa.channels = chans
rxs = usrp.get_rx_stream(sa)
txs = usrp.get_tx_stream(sa)
lead = 4096
ntx = lead + a.nsamps + 2048
tone = (a.amp * np.exp(2j * np.pi * a.tone * np.arange(ntx) / rate)).astype(np.complex64)
tt = np.arange(a.nsamps) / rate
sign = [None]


def capture(t_ch):
    tx = np.zeros((n, ntx), dtype=np.complex64)
    tx[t_ch] = tone
    t0 = usrp.get_time_now().get_real_secs() + 0.15
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


def deg(z):
    return math.degrees(np.angle(z))


def search(bf, k, base, out, shift=None, method="MIN"):
    """phase_search of channel k against channel 0 on beamformer bf, on top of
    the unit weights base (ones, or a calibration); out() -> the complex
    output sample whose power is searched. Returns (angles, powers_dB, c):
    weight exp(j c) on k brings it in phase with channel 0."""
    def meas(th):
        w = np.zeros(n, dtype=complex)
        w[0] = 32767 * base[0]
        w[k] = 32767 * base[k] * np.exp(1j * math.radians(th))
        load(bf, np.round(w), shift)
        return 10 * math.log10(abs(out()) ** 2 + 1e-30)
    angles, powers = phase_search(meas, coarse_step=a.coarse, fine_step=a.fine, method=method)
    return angles, powers, calib_phase(angles, powers, method, fit=a.estimator == "fit")


def null_depth(powers):
    return max(powers) - min(powers)


def fmt(v):
    return " ".join(f"{x:+7.1f}" for x in v)


if a.cmd == "calibrate" and a.method != "matrix":
    mm = "MIN" if a.method == "null" else "MAX"
    ones = np.ones(n, dtype=complex)
    curves = {}
    usrp.set_user_register(TX["en"], 1)
    tx, depth_tx = [0.0], []
    for k in chans[1:]:
        ang, pw, c = search(TX, k, ones, lambda: capture(0)[a.rx_ref], method=mm)
        tx.append(float(wrap(-c)))
        depth_tx.append(null_depth(pw))
        curves[f"tx{k}"] = dict(angles=ang, powers_db=pw)
    usrp.set_user_register(TX["en"], 0)
    usrp.set_user_register(RX["en"], 1)
    rx, depth_rx = [0.0], []
    for k in chans[1:]:
        ang, pw, c = search(RX, k, ones, lambda: capture(a.tx_ref)[0], shift=0, method=mm)
        rx.append(float(wrap(-c)))
        depth_rx.append(null_depth(pw))
        curves[f"rx{k}"] = dict(angles=ang, powers_db=pw)
    usrp.set_user_register(RX["en"], 0)
    cal = dict(created=time.strftime("%Y-%m-%dT%H:%M:%S"), method=a.method, freq=a.freq, rate=rate, n=n,
               rx_ref=a.rx_ref, tx_ref=a.tx_ref, tx_offset_deg=tx, rx_offset_deg=rx,
               estimator=a.estimator, coarse_deg=a.coarse, fine_deg=a.fine, curves=curves)
    json.dump(cal, open(a.out, "w"), indent=1)
    what = "null" if mm == "MIN" else "peak"
    print(f"calibration, {what} search ({a.coarse:g} deg coarse, {a.fine:g} deg fine, {a.estimator}), "
          f"RF {a.freq / 1e6:g} MHz, N = {n}")
    print(f"  TX offsets at RX{a.rx_ref} (vs TX0), deg:   {fmt(tx)}   "
          f"(null depth {', '.join(f'{d:.0f}' for d in depth_tx)} dB)")
    print(f"  RX offsets from TX{a.tx_ref} (vs RX0), deg: {fmt(rx)}   "
          f"(null depth {', '.join(f'{d:.0f}' for d in depth_rx)} dB)")
    print(f"  saved {a.out}")
    sys.exit(0)

if a.cmd == "calibrate":
    Hs = []
    for _ in range(a.reps):
        H = np.array([capture(t) for t in chans]).T          # H[r, t]
        Hs.append(H * np.exp(-1j * np.angle(H[0, 0])))
    H = np.mean(Hs, axis=0)
    rep = max(float(np.max(np.abs(wrap(np.degrees(np.angle(h / H)))))) for h in Hs)
    tx = [float(wrap(deg(H[a.rx_ref, t] / H[a.rx_ref, 0]))) for t in chans]
    rx = [float(wrap(deg(H[r, a.tx_ref] / H[0, a.tx_ref]))) for r in chans]
    cal = dict(created=time.strftime("%Y-%m-%dT%H:%M:%S"), method="matrix", freq=a.freq, rate=rate, n=n,
               rx_ref=a.rx_ref, tx_ref=a.tx_ref, tx_offset_deg=tx, rx_offset_deg=rx,
               H_re=H.real.tolist(), H_im=H.imag.tolist(), repeat_spread_deg=rep)
    json.dump(cal, open(a.out, "w"), indent=1)
    print(f"calibration ({a.reps} matrices, repeat spread {rep:.2f} deg), RF {a.freq / 1e6:g} MHz, N = {n}")
    print(f"  TX offsets at RX{a.rx_ref} (vs TX0), deg:   {fmt(tx)}")
    print(f"  RX offsets from TX{a.tx_ref} (vs RX0), deg: {fmt(rx)}")
    print(f"  saved {a.out}")
    sys.exit(0)

# ---------------------------------------------------------------- verify
cal = json.load(open(a.cal))
if cal["n"] != n:
    sys.exit(f"{a.cal} is for N = {cal['n']}, this build has N = {n}")
r0, t0 = cal["rx_ref"], cal["tx_ref"]
ctx = np.exp(-1j * np.radians(cal["tx_offset_deg"]))      # unit calibration weights
crx = np.exp(-1j * np.radians(cal["rx_offset_deg"]))
print(f"verify with {a.cal} ({cal.get('method', 'matrix')}, created {cal['created']}): RF {a.freq / 1e6:g} MHz, N = {n}, "
      f"TX cal at RX{r0}, RX cal from TX{t0}")
worst = {}

# TX: calibrated one-hot paths, null search on top of the calibration, full beam
usrp.set_user_register(TX["en"], 1)
Y = np.zeros((n, n), dtype=complex)                        # Y[r, t] calibrated path t at RX r
for t in chans:
    w = np.zeros(n, dtype=complex)
    w[t] = 32767 * ctx[t]
    load(TX, np.round(w))
    Y[:, t] = capture(0)
direct = [float(wrap(deg(Y[r0, t] / Y[r0, 0]))) for t in chans]
sweep = [0.0]
for k in chans[1:]:
    sweep.append(float(wrap(-search(TX, k, ctx, lambda: capture(0)[r0])[2])))
load(TX, np.round(32767 * ctx))
yall = capture(0)
coh_tx = abs(yall[r0]) / np.sum(np.abs(Y[r0]))
load(TX, np.full(n, 32767 + 0j))
yraw = capture(0)
raw_tx = abs(yraw[r0]) / np.sum(np.abs(Y[r0]))
usrp.set_user_register(TX["en"], 0)
print(f"\n{n}T1R, TX beamformer with the calibration, at RX{r0}:")
print(f"  residual TX offsets, direct (deg):       {fmt(direct)}")
print(f"  residual TX offsets, null search (deg):  {fmt(sweep)}")
print(f"  coherent gain: calibrated {coh_tx:.3f}, uncalibrated (all weights 1) {raw_tx:.3f}")
for r in chans:
    if r != r0:
        print(f"  (other RX{r}: residual {fmt([wrap(deg(Y[r, t] / Y[r, 0])) for t in chans])} -- geometry)")
worst["tx_direct"] = max(abs(x) for x in direct)
worst["tx_null"] = max(abs(x) for x in sweep)

# RX: calibrated one-hot elements, null search, full beam (beam = RX channel 0)
usrp.set_user_register(RX["en"], 1)
Z = np.zeros((n, n), dtype=complex)                        # Z[t, r] calibrated element r, tone from TX t
for t in chans:
    for r in chans:
        w = np.zeros(n, dtype=complex)
        w[r] = 32767 * crx[r]
        load(RX, np.round(w), shift=0)
        Z[t, r] = capture(t)[0]
direct_rx = [float(wrap(deg(Z[t0, r] / Z[t0, 0]))) for r in chans]
sweep_rx = [0.0]
for k in chans[1:]:
    sweep_rx.append(float(wrap(-search(RX, k, crx, lambda: capture(t0)[0], shift=0)[2])))
L = int(math.log2(n))
load(RX, np.round(32767 * crx), shift=L)
coh_rx = abs(capture(t0)[0]) / (np.sum(np.abs(Z[t0])) / 2 ** L)
load(RX, np.full(n, 32767 + 0j), shift=L)
raw_rx = abs(capture(t0)[0]) / (np.sum(np.abs(Z[t0])) / 2 ** L)
usrp.set_user_register(RX["en"], 0)
print(f"\n1T{n}R, RX beamformer with the calibration, tone from TX{t0}:")
print(f"  residual RX offsets, direct (deg):       {fmt(direct_rx)}")
print(f"  residual RX offsets, null search (deg):  {fmt(sweep_rx)}")
print(f"  coherent gain: calibrated {coh_rx:.3f}, uncalibrated (all weights 1) {raw_rx:.3f}")
for t in chans:
    if t != t0:
        print(f"  (other TX{t}: residual {fmt([wrap(deg(Z[t, r] / Z[t, 0])) for r in chans])} -- geometry)")
worst["rx_direct"] = max(abs(x) for x in direct_rx)
worst["rx_null"] = max(abs(x) for x in sweep_rx)
print("\nSUMMARY max |residual| (deg): " + ", ".join(f"{k} {v:.1f}" for k, v in worst.items())
      + f"; coherent gain TX {coh_tx:.3f} RX {coh_rx:.3f}")
bad = [f"{k} {v:.1f} deg > {a.max_residual_deg}" for k, v in worst.items() if v > a.max_residual_deg]
bad += [f"coherent gain {k} {v:.3f} < {a.min_coherent}" for k, v in (("TX", coh_tx), ("RX", coh_rx))
        if v < a.min_coherent]
print("RESULT " + ("PASS" if not bad else "FAIL: " + "; ".join(bad)))
sys.exit(1 if bad else 0)
