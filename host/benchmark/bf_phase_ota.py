#!/usr/bin/env python3
"""bf_phase_ota.py -- channel-to-channel phase offsets of an N-channel build,
measured over the air through stock UHD calls (N = 16: channels=16).

Every measurement is one timed TX burst (a tone) and a timed RX capture of all
N channels inside it; the tone's complex amplitude per RX channel is the
measurement. The RF centre (TX and RX NCO) is --freq (default 950 MHz).

  NT1R (--mode tx): TX phase offsets, beamformer ENABLED, one RX antenna.
    a. each TX c alone (one-hot weight w[c] = 1, the others 0): the tone's
       phase at the RX relative to TX 0 = the TX channel's offset (its whole
       path: NCO, DAC, front end, antenna, air to the RX antenna);
    b. all weights 1 (zero phase, the 'beamformer all set to zero phase'
       state): coherent gain |y_all| / sum_c |y_c| -- 1.0 exactly when every
       TX path arrives in phase (all offsets zero), and y_all must equal
       sum_c y_c (superposition: the beamformer applied every weight);
    c. a beam sweep like rfsoc_lib/beamformer_task.py (Beamformer weights,
       -90..90 deg): received level per steering angle, and where it peaks.
  1TNR (--mode rx): RX phase offsets, beamformer in bypass, the tone on one TX
    channel (--tx, default 0), every RX channel captured: the phase of RX r
    relative to RX 0.
  --reps K repeats everything K times; --retune re-tunes every channel between
  repeats (tests whether the offsets are deterministic across NCO updates,
  Protocol §3d), otherwise the spread is the measurement noise.

    zcu216-uhd python3 benchmark/bf_phase_ota.py --args type=zcu216,addr=<board-ip>,channels=16 --mode tx
    zcu216-uhd python3 benchmark/bf_phase_ota.py --args type=zcu216,addr=<board-ip>,channels=16 --mode rx
"""
import argparse
import math
import sys

import numpy as np
import uhd

REG_ENABLE, REG_ANGLE, REG_LOAD, REG_W0 = 0, 1, 15, 16
BF = "/mboards/0/beamformer"

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True, help="device args incl. addr= and channels=N")
ap.add_argument("--mode", choices=("tx", "rx", "both"), default="both")
ap.add_argument("--freq", type=float, default=950e6, help="RF centre (TX and RX NCO), Hz")
ap.add_argument("--tone", type=float, default=3.1e6, help="baseband tone, Hz")
ap.add_argument("--amp", type=float, default=0.125, help="tone amplitude, fc32 full scale 1 "
                "(-18 dBFS: the TX analog chain compresses near -6 dBFS)")
ap.add_argument("--nsamps", type=int, default=16384, help="RX samples per channel per capture")
ap.add_argument("--rx", type=int, default=None, help="NT1R: the RX channel (default: best heard)")
ap.add_argument("--tx", type=int, default=0, help="1TNR: the TX channel")
ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--retune", action="store_true", help="re-tune every channel between repeats")
ap.add_argument("--sweep", default="-90:90:5", help="NT1R beam sweep start:stop:step, deg ('' = off)")
ap.add_argument("--snr-db", type=float, default=20.0, help="min tone-to-noise for a usable path")
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
tree = usrp.get_tree()
n = usrp.get_tx_num_channels()
rate = usrp.get_rx_rate(0)
chans = list(range(n))


def tune():
    for c in chans:
        usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
        usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)


tune()
sa = uhd.usrp.StreamArgs("fc32", "sc16")
sa.channels = chans
rxs = usrp.get_rx_stream(sa)
txs = usrp.get_tx_stream(sa)
has_bf = tree.exists(BF + "/enable")
print(f"N = {n}, {rate / 1e6:g} MS/s per channel, RF {usrp.get_tx_freq(0) / 1e6:g} MHz TX / "
      f"{usrp.get_rx_freq(0) / 1e6:g} MHz RX, tone {a.tone / 1e6:g} MHz at {20 * math.log10(a.amp):.1f} dBFS, "
      f"beamformer {'yes' if has_bf else 'no'}")
lead = 4096
ntx = lead + a.nsamps + 2048
tt_tx = np.arange(ntx) / rate
tone = (a.amp * np.exp(2j * np.pi * a.tone * tt_tx)).astype(np.complex64)
tt = np.arange(a.nsamps) / rate
sign = [None]


def capture(tx_chan):
    """tone on TX tx_chan (others zero); complex tone amplitude and noise per RX"""
    tx = np.zeros((n, ntx), dtype=np.complex64)
    tx[tx_chan] = tone
    t0 = usrp.get_time_now().get_real_secs() + 0.12
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = a.nsamps
    cmd.stream_now = False
    cmd.time_spec = uhd.types.TimeSpec(t0 + lead / rate)
    rxs.issue_stream_cmd(cmd)
    md = uhd.types.TXMetadata()
    md.start_of_burst, md.end_of_burst, md.has_time_spec = True, True, True
    md.time_spec = uhd.types.TimeSpec(t0)
    if txs.send(tx, md, 1.0) != ntx:
        raise RuntimeError("TX burst not accepted")
    rx = np.zeros((n, a.nsamps), dtype=np.complex64)
    rmd = uhd.types.RXMetadata()
    got = 0
    while got < a.nsamps:
        k = rxs.recv(rx[:, got:], rmd, 2.0)
        if rmd.error_code != uhd.types.RXMetadataErrorCode.none:
            raise RuntimeError(f"recv: {rmd.strerror()}")
        got += k
    if sign[0] is None:
        p = np.abs(rx @ np.exp(-2j * np.pi * a.tone * tt)).sum()
        m = np.abs(rx @ np.exp(+2j * np.pi * a.tone * tt)).sum()
        sign[0] = 1 if p >= m else -1
    f = sign[0] * a.tone
    y = rx @ np.exp(-2j * np.pi * f * tt) / a.nsamps
    nz = np.abs(rx @ np.exp(-2j * np.pi * (f + 1.37e6) * tt) / a.nsamps)
    return y, nz


def load_raw(w):
    for c in chans:
        re, im = int(round(w[c].real)), int(round(w[c].imag))
        usrp.set_user_register(REG_W0 + c, (re & 0xFFFF) | ((im & 0xFFFF) << 16))
    usrp.set_user_register(REG_LOAD, 1)


def db(x):
    return 20 * math.log10(max(float(x), 1e-15))


def deg(z):
    return math.degrees(np.angle(z))


def wrap(d):
    return (d + 180.0) % 360.0 - 180.0


def table(title, ph_reps, lvl, ok):
    """ph_reps: reps x N phases (deg, relative); prints mean, spread, level"""
    ph = np.array(ph_reps)
    mean = np.degrees(np.angle(np.exp(1j * np.radians(ph)).mean(axis=0)))
    spread = np.array([np.max(np.abs(wrap(ph[:, c] - mean[c]))) for c in range(ph.shape[1])])
    print(title)
    print("   ch      " + " ".join(f"{c:6d}" for c in range(ph.shape[1])))
    print("   level   " + " ".join(f"{x:6.1f}" for x in lvl) + "   dBFS")
    print("   phase   " + " ".join(f"{x:+6.1f}" if ok[c] else "     -" for c, x in enumerate(mean))
          + "   deg (mean over reps)")
    print("   spread  " + " ".join(f"{x:6.1f}" if ok[c] else "     -" for c, x in enumerate(spread))
          + "   deg (max |rep - mean|)")
    return mean, spread


summary = []

# ---------------------------------------------------------------- NT1R
if a.mode in ("tx", "both"):
    if not has_bf:
        sys.exit("NT1R needs the TX beamformer (an N >= 2 build)")
    usrp.set_user_register(REG_ENABLE, 1)
    reps_y, noise = [], np.zeros(n)
    allw = []
    for rep in range(a.reps):
        if rep and a.retune:
            tune()
        Y = np.zeros((n, n), dtype=complex)            # Y[rx, tx]
        for c in chans:
            e = np.zeros(n, dtype=complex)
            e[c] = 32767
            load_raw(e)
            Y[:, c], nz = capture(0)                   # the beamformer fans TX ch0 out
            noise = np.maximum(noise, nz)
        load_raw(np.full(n, 32767 + 0j))               # all weights 1: zero phase
        yall, _ = capture(0)
        reps_y.append(Y)
        allw.append(yall)
    Y = np.mean(reps_y, axis=0)
    snr = np.array([[db(abs(Y[r, c]) / max(noise[r], 1e-15)) for c in chans] for r in chans])
    # the RX that hears the most TX channels, then the most signal
    heard = [(int(np.sum(snr[r] >= a.snr_db)), float(np.sum(np.abs(Y[r])))) for r in chans]
    r0 = a.rx if a.rx is not None else max(chans, key=lambda r: heard[r])
    ok = [snr[r0, c] >= a.snr_db for c in chans]
    print(f"\nNT1R: {n} TX -> RX {r0} (the RX that hears the most TX; TX heard per RX: "
          + " ".join(str(h[0]) for h in heard) + f"; RX {r0} noise floor {db(noise[r0]):.1f} dBFS)")
    ref = 0 if ok[0] else int(np.argmax(ok))
    ph = [[wrap(deg(Yr[r0, c]) - deg(Yr[r0, ref])) for c in chans] for Yr in reps_y]
    mean, spread = table(f"   TX phase at RX {r0} relative to TX {ref} (one-hot weights):",
                         ph, [db(abs(Y[r0, c])) for c in chans], ok)
    use = [c for c in chans if ok[c]]
    print(f"   usable TX ({a.snr_db:g} dB above noise): {use}")
    for rep, (Yr, ya) in enumerate(zip(reps_y, allw)):
        coh = abs(ya[r0]) / sum(abs(Yr[r0, c]) for c in chans)
        sup = abs(ya[r0] - Yr[r0].sum()) / abs(Yr[r0].sum())
        print(f"   rep {rep}: all weights 1 (zero phase): |y| {db(abs(ya[r0])):6.1f} dBFS, coherent gain "
              f"{coh:.3f} (1.0 = every TX path in phase), superposition error {db(sup):6.1f} dB")
    nz_ph = [abs(mean[c]) for c in use if c != ref]
    summary.append(f"TX offsets (relative to TX {ref}, {len(use)} usable TX): max |offset| "
                   f"{max(nz_ph) if nz_ph else 0:.1f} deg, rms {math.sqrt(np.mean(np.square(nz_ph))) if nz_ph else 0:.1f} deg, "
                   f"repeat spread max {max(spread[c] for c in use):.1f} deg")
    if a.sweep:
        lo, hi, st = (float(x) for x in a.sweep.split(":"))
        angles = np.arange(lo, hi + st / 2, st)
        lv = []
        for ang in angles:
            usrp.set_user_register(REG_ANGLE, int(round(ang * 1000)) & 0xFFFFFFFF)
            y, _ = capture(0)
            lv.append(db(abs(y[r0])))
        pk = angles[int(np.argmax(lv))]
        carrier = tree.access_double(BF + "/carrier_freq").get()
        spacing = tree.access_double(BF + "/element_spacing").get()
        print(f"   beam sweep (Beamformer weights, carrier {carrier / 1e9:g} GHz, spacing {spacing * 1e3:g} mm), "
              f"level at RX {r0}:")
        for i in range(0, len(angles), 9):
            print("     " + "  ".join(f"{angles[j]:+5.0f}:{lv[j]:6.1f}" for j in range(i, min(i + 9, len(angles)))))
        print(f"   peak at {pk:+g} deg ({max(lv):.1f} dBFS)")
        summary.append(f"beam sweep peak at {pk:+g} deg")
    usrp.set_user_register(REG_ENABLE, 0)

# ---------------------------------------------------------------- 1TNR
if a.mode in ("rx", "both"):
    if has_bf:
        usrp.set_user_register(REG_ENABLE, 0)          # bypass: TX ch a.tx -> its DAC only
    ys, noise = [], np.zeros(n)
    for rep in range(a.reps):
        if rep and a.retune:
            tune()
        y, nz = capture(a.tx)
        ys.append(y)
        noise = np.maximum(noise, nz)
    y = np.mean(ys, axis=0)
    ok = [db(abs(y[r]) / max(noise[r], 1e-15)) >= a.snr_db for r in chans]
    ref = 0 if ok[0] else int(np.argmax(ok))
    print(f"\n1T{n}R: TX {a.tx} -> every RX (beamformer bypass)")
    ph = [[wrap(deg(yr[r]) - deg(yr[ref])) for r in chans] for yr in ys]
    mean, spread = table(f"   RX phase relative to RX {ref}:", ph, [db(abs(y[r])) for r in chans], ok)
    use = [r for r in chans if ok[r]]
    print(f"   usable RX ({a.snr_db:g} dB above noise): {use}")
    nz_ph = [abs(mean[r]) for r in use if r != ref]
    summary.append(f"RX offsets (relative to RX {ref}, {len(use)} usable RX): max |offset| "
                   f"{max(nz_ph) if nz_ph else 0:.1f} deg, rms {math.sqrt(np.mean(np.square(nz_ph))) if nz_ph else 0:.1f} deg, "
                   f"repeat spread max {max(spread[r] for r in use):.1f} deg")

print("\nSUMMARY" + (" (re-tuned between repeats)" if a.retune else "") + ":")
for s in summary:
    print("  " + s)
