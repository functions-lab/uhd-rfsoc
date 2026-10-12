#!/usr/bin/env python3
"""phase_matrix_ota.py -- TX and RX channel phase offsets of an N-channel
build from the full NxN over-the-air matrix (all NTNR = every NT1R and 1TNR
setup at once), through stock UHD calls.

For each TX t (both beamformers in bypass, the tone on TX stream channel t
only), one timed burst and a timed capture of every RX channel: H[r, t] =
the tone's complex amplitude at RX r. Then
  NT1R (one RX r):  TX offsets  arg(H[r, t] / H[r, 0])   for every r
  1TNR (one TX t):  RX offsets  arg(H[r, t] / H[0, t])   for every t
  model:            arg H[r, t] = rx[r] + tx[t] + g[r, t]
    rx, tx are per-channel (hardware) terms, g the over-the-air geometry.
    A least-squares fit of rx + tx to the phases (rx[0] = tx[0] = 0); the
    residual g shows how much of the measured offsets is geometry: if the
    offsets were purely the hardware chains, every RX would see the same TX
    offsets (and vice versa) and g would be ~0.
--reps K repeats the matrix (spread = noise), --retune re-tunes every channel
between repeats (NCO determinism, PROTOCOL.md section 3d). --save FILE writes
the matrices (numpy .npz) so runs before and after a bitstream reload can be
compared with --compare FILE.

    zcu216-uhd python3 benchmark/phase_matrix_ota.py --args type=zcu216,addr=<board-ip>,channels=4 --reps 3
"""
import argparse
import math
import sys

import numpy as np
import uhd

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True)
ap.add_argument("--freq", type=float, default=950e6)
ap.add_argument("--tone", type=float, default=3.1e6)
ap.add_argument("--amp", type=float, default=0.125)
ap.add_argument("--nsamps", type=int, default=16384)
ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--retune", action="store_true")
ap.add_argument("--save", default=None)
ap.add_argument("--compare", default=None)
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
tree = usrp.get_tree()
n = usrp.get_rx_num_channels()
rate = usrp.get_rx_rate(0)
chans = list(range(n))


def tune():
    for c in chans:
        usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
        usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)


tune()
for bf in ("tx_beamformer", "rx_beamformer"):
    if tree.exists(f"/mboards/0/{bf}/enable"):
        tree.access_bool(f"/mboards/0/{bf}/enable").set(False)
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
    t0 = usrp.get_time_now().get_real_secs() + 0.12
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
    f = sign[0] * a.tone
    return (rx @ np.exp(-2j * np.pi * f * tt) / a.nsamps,
            np.abs(rx @ np.exp(-2j * np.pi * (f + 1.37e6) * tt) / a.nsamps))


def wrap(d):
    return (d + 180.0) % 360.0 - 180.0


def deg(z):
    return np.degrees(np.angle(z))


def cmean_deg(ph, axis=0):
    return np.degrees(np.angle(np.exp(1j * np.radians(ph)).mean(axis=axis)))


Hs, noise = [], np.zeros(n)
for rep in range(a.reps):
    if rep and a.retune:
        tune()
    H = np.zeros((n, n), dtype=complex)
    for t in chans:
        H[:, t], nz = capture(t)
        noise = np.maximum(noise, nz)
    Hs.append(H)
Hs = np.array(Hs)
# phase reference: each repeat aligned on its own H[0,0] (the common capture
# phase cancels in every ratio below anyway)
H = np.mean(Hs * np.exp(-1j * np.angle(Hs[:, :1, :1])), axis=0)


def db(x):
    return 20 * math.log10(max(float(x), 1e-15))


print(f"N = {n}, {rate / 1e6:g} MS/s, RF {a.freq / 1e6:g} MHz, {a.reps} repeat(s)"
      f"{' re-tuned between repeats' if a.retune else ''}; beamformers in bypass")
print("|H| dBFS (rows RX, columns TX), noise floor per RX:")
for r in chans:
    print(f"   RX{r} " + " ".join(f"{db(abs(H[r, t])):7.1f}" for t in chans) + f"   noise {db(noise[r]):6.1f}")
snr_min = min(db(abs(H[r, t]) / noise[r]) for r in chans for t in chans)
print(f"   lowest SNR over all paths: {snr_min:.1f} dB")

# NT1R: per RX, TX offsets; 1TNR: per TX, RX offsets; spread over repeats
txo = np.array([[wrap(deg(Hr[r, t] / Hr[r, 0])) for t in chans] for Hr in Hs for r in chans]).reshape(a.reps, n, n)
rxo = np.array([[wrap(deg(Hr[r, t] / Hr[0, t])) for r in chans] for Hr in Hs for t in chans]).reshape(a.reps, n, n)
print(f"\n{n}T1R -- TX phase offsets relative to TX0 (deg), one row per receiving RX "
      "(mean over repeats; max repeat spread):")
for r in chans:
    m = cmean_deg(txo[:, r, :])
    s = np.max(np.abs(wrap(txo[:, r, :] - m)), axis=0)
    print(f"   at RX{r}: " + " ".join(f"{x:+7.1f}" for x in m) + "   spread " + " ".join(f"{x:4.1f}" for x in s))
print(f"1T{n}R -- RX phase offsets relative to RX0 (deg), one row per transmitting TX:")
for t in chans:
    m = cmean_deg(rxo[:, t, :])
    s = np.max(np.abs(wrap(rxo[:, t, :] - m)), axis=0)
    print(f"   from TX{t}: " + " ".join(f"{x:+7.1f}" for x in m) + "   spread " + " ".join(f"{x:4.1f}" for x in s))

# separable fit arg H = rx[r] + tx[t] (+ common), on unit phasors (wrap-safe):
# alternate rx = arg sum_t H e^{-j tx}, tx = arg sum_r H e^{-j rx}
U = H / np.abs(H)
rxp, txp = np.zeros(n), np.zeros(n)
for _ in range(200):
    txp = np.angle(np.sum(U * np.exp(-1j * rxp)[:, None], axis=0))
    rxp = np.angle(np.sum(U * np.exp(-1j * txp)[None, :], axis=1))
txp, rxp = txp - txp[0], rxp - rxp[0]
G = np.degrees(np.angle(U * np.exp(-1j * (rxp[:, None] + txp[None, :]))))
G = wrap(G - cmean_deg(G.ravel()))
print("\nseparable model arg H[r,t] = rx[r] + tx[t] + g[r,t]  (least squares on phasors):")
print("   tx[t] (TX offsets) " + " ".join(f"{x:+7.1f}" for x in np.degrees(txp)))
print("   rx[r] (RX offsets) " + " ".join(f"{x:+7.1f}" for x in np.degrees(rxp)))
print("   residual g[r,t] (geometry / non-separable part), deg:")
for r in chans:
    print(f"     RX{r} " + " ".join(f"{G[r, t]:+7.1f}" for t in chans))
print(f"   residual rms {math.sqrt(np.mean(G ** 2)):.1f} deg, max {np.max(np.abs(G)):.1f} deg")
spread_rep = np.max(np.abs(wrap(np.degrees(np.angle(Hs * np.exp(-1j * np.angle(Hs[:, :1, :1])) / H)))))
print(f"   repeat-to-repeat spread of any H[r,t] phase: {spread_rep:.2f} deg")

if a.save:
    np.savez(a.save, H=H, Hs=Hs, freq=a.freq, rate=rate)
    print(f"saved {a.save}")
if a.compare:
    o = np.load(a.compare)
    Ho = o["H"]
    d = wrap(np.degrees(np.angle(H / Ho)))
    d = wrap(d - d[0, 0])
    print(f"\nagainst {a.compare}: phase change of every H[r,t] (deg, relative to H[0,0]):")
    for r in chans:
        print(f"     RX{r} " + " ".join(f"{d[r, t]:+7.1f}" for t in chans))
    print(f"   max |change| {np.max(np.abs(d)):.1f} deg; level change max "
          f"{np.max(np.abs(20 * np.log10(np.abs(H) / np.abs(Ho)))):.2f} dB")
