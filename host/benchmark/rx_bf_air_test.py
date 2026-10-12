#!/usr/bin/env python3
"""rx_bf_air_test.py -- the RX beamformer (PROTOCOL.md section 11) over the
air, through stock UHD calls, on an N-channel build whose ADCs have antennas.

A tone from one TX channel (--tx, TX beamformer in bypass) reaches every RX
antenna; one timed capture per step, every RX channel, sc16 on the wire:
  1. RX beamformer in bypass: the tone's complex amplitude a_c per RX channel
     (the per-element path, incl. the channel phase offsets);
  2. RX beamformer on, unity weights (zero phase, SHIFT log2 N): RX channel 0
     is the beam; it must equal sum_c a_c * w_c / 2^SHIFT (w_c = 32767/32768),
     and its size relative to sum_c |a_c| / 2^SHIFT is the coherent gain of
     the uncalibrated array (1.0 only when every path arrives in phase);
  3. RX beamformer on, phase-calibrated weights w_c = conj(a_c) / |a_c| from
     step 1: the paths now add in phase, coherent gain ~1.0;
  4. an angle sweep with the Beamformer weights (like rfsoc_lib/
     beamformer_task.py), beam level per angle.
Channels 1..N-1 keep delivering raw samples while the beamformer runs; they
are checked against step 1 as well.

    zcu216-uhd python3 benchmark/rx_bf_air_test.py --args type=zcu216,addr=<board-ip>,channels=4
"""
import argparse
import math
import sys

import numpy as np
import uhd

R_EN, R_ANGLE, R_SHIFT, R_LOAD, R_W0 = 64, 65, 68, 79, 80
RBF = "/mboards/0/rx_beamformer"

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True)
ap.add_argument("--freq", type=float, default=950e6)
ap.add_argument("--tone", type=float, default=3.1e6)
ap.add_argument("--amp", type=float, default=0.125)
ap.add_argument("--tx", type=int, default=0)
ap.add_argument("--nsamps", type=int, default=16384)
ap.add_argument("--sweep", default="-90:90:10")
ap.add_argument("--tol-db", type=float, default=-25.0, help="max prediction error (dB)")
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
tree = usrp.get_tree()
n = usrp.get_rx_num_channels()
if not tree.exists(RBF + "/enable"):
    sys.exit("this build has no RX beamformer (an N >= 2 bitstream with rx_beamformer)")
rate = usrp.get_rx_rate(0)
chans = list(range(n))
for c in chans:
    usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
    usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)
sa = uhd.usrp.StreamArgs("fc32", "sc16")
sa.channels = chans
rxs = usrp.get_rx_stream(sa)
txs = usrp.get_tx_stream(sa)
if tree.exists("/mboards/0/tx_beamformer/enable"):
    tree.access_bool("/mboards/0/tx_beamformer/enable").set(False)
L = int(math.log2(n))
lead = 4096
ntx = lead + a.nsamps + 2048
tx = np.zeros((n, ntx), dtype=np.complex64)
tx[a.tx] = (a.amp * np.exp(2j * np.pi * a.tone * np.arange(ntx) / rate)).astype(np.complex64)
tt = np.arange(a.nsamps) / rate
sign = [None]


def capture():
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
    return rx @ np.exp(-2j * np.pi * sign[0] * a.tone * tt) / a.nsamps


def load(w, shift):
    for c in chans:
        re, im = int(round(w[c].real)), int(round(w[c].imag))
        usrp.set_user_register(R_W0 + c, (re & 0xFFFF) | ((im & 0xFFFF) << 16))
    usrp.set_user_register(R_SHIFT, shift)
    usrp.set_user_register(R_LOAD, 1)


def db(x):
    return 20 * math.log10(max(float(x), 1e-15))


fails = 0


def check(ok, what):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + what)
    fails += not ok


print(f"N = {n}, {rate / 1e6:g} MS/s, RF {a.freq / 1e6:g} MHz, tone from TX {a.tx} at "
      f"{20 * math.log10(a.amp):.1f} dBFS")
usrp.set_user_register(R_EN, 0)
araw = capture()
print("1. bypass: per-RX tone " + "  ".join(f"RX{c} {db(abs(araw[c])):6.1f} dBFS/{math.degrees(np.angle(araw[c] / araw[0])):+6.1f} deg"
                                     for c in chans))
inc = sum(abs(araw)) / 2 ** L                       # the in-phase (coherent) beam level

for label, w in (("unity weights (zero phase)", np.full(n, 32767 + 0j)),
                 ("phase-calibrated weights", np.round(32767 * np.conj(araw) / np.abs(araw)))):
    load(w, L)
    usrp.set_user_register(R_EN, 1)
    y = capture()
    pred = np.sum(araw * w / 32768.0) / 2 ** L
    err = abs(y[0] - pred) / abs(pred)
    raw_err = max(abs(y[c] - araw[c]) / abs(araw[c]) for c in chans[1:])
    print(f"2/3. {label}: beam {db(abs(y[0])):6.1f} dBFS, predicted {db(abs(pred)):6.1f} dBFS, "
          f"coherent gain {abs(y[0]) / inc:.3f}")
    check(db(err) < a.tol_db, f"{label}: beam = sum a_c w_c / 2^{L} within {db(err):.1f} dB")
    check(db(raw_err) < a.tol_db, f"{label}: channels 1..{n - 1} still raw (max deviation {db(raw_err):.1f} dB)")
    if label.startswith("phase"):
        check(abs(y[0]) / inc > 0.9, f"calibrated beam adds in phase (coherent gain {abs(y[0]) / inc:.3f})")
    usrp.set_user_register(R_EN, 0)

if a.sweep:
    lo, hi, st = (float(x) for x in a.sweep.split(":"))
    usrp.set_user_register(R_SHIFT, L)
    usrp.set_user_register(R_EN, 1)
    lv = []
    angles = np.arange(lo, hi + st / 2, st)
    for ang in angles:
        usrp.set_user_register(R_ANGLE, int(round(ang * 1000)) & 0xFFFFFFFF)
        lv.append(db(abs(capture()[0])))
    usrp.set_user_register(R_EN, 0)
    print("4. RX beam sweep (Beamformer weights): " + "  ".join(f"{x:+.0f}:{v:.1f}" for x, v in zip(angles, lv)))
    print(f"   peak at {angles[int(np.argmax(lv))]:+g} deg")
print("RESULT:", "PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
