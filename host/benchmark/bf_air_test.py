#!/usr/bin/env python3
"""bf_air_test.py -- the TX beamformer (PROTOCOL.md section 11) verified over
the air, through stock UHD calls, on an N-channel build whose DACs and ADCs
have antennas (an over-the-air link: every RX antenna hears every TX antenna).

Each measurement is one timed TX burst -- a tone on TX channel 0, zeros on the
others; the beamformer fans channel 0 out to DAC c times w[c] -- and a timed
RX capture of all N channels inside it. The tone's complex amplitude on RX
channel r is y[r] = sum_c H[r, c] * w[c] / 32767 with H the TX -> RX channel
(antennas, propagation, converters), so:

  1. H, column by column: one-hot raw weights (w[c] = 32767, others 0),
     measured twice -- the difference is the repeatability floor.
  2. bypass (enable 0) must give H[:, 0] (DAC 0 gets channel 0 unchanged),
     with H[:, 0] measured right before and after it.
  3. every steering angle, and a raw-weight pattern of different magnitudes
     and phases: H is measured again right before and right after the case
     (the air drifts), the prediction is mean(H) @ w, and the error is
     normalised by the incoherent sum sum_c |H[r,c] w[c]| (a cancelling
     combination does not inflate it). Pass: error below a few times that
     case's own drift (|H_after - H_before|), i.e. the FPGA applied every
     weight, amplitude and phase, to the right DAC. Each DAC's effective
     weight is also estimated, w_hat = lstsq(H, y), and printed against w.
     w is read back from the tree (/mboards/0/beamformer/weights_str).
  The printed |prediction| per RX antenna also shows the steering itself.
TX channels whose column of H is in the noise (no antenna, or unheard) and RX
channels that hear nothing are reported and left out of the comparison.

    zcu216-uhd python3 benchmark/bf_air_test.py --args type=zcu216,addr=<board-ip>,channels=8
"""
import argparse
import math
import sys

import numpy as np
import uhd

REG_ENABLE, REG_ANGLE, REG_CARRIER, REG_SPACING, REG_LOAD, REG_W0 = 0, 1, 2, 3, 15, 16
BF = "/mboards/0/beamformer"

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True, help="device args incl. addr= and channels=N (N >= 2)")
ap.add_argument("--freq", type=float, default=600e6, help="TX and RX centre (NCO), Hz (<= fs/2)")
ap.add_argument("--tone", type=float, default=7.3e6, help="baseband tone, Hz")
# -18 dBFS: at -6 dBFS the zcu216-0 TX analog chain compresses (measured
# 2026-10-01: weight 0.5 came back as 0.66 / +3 deg, 0.125 as 0.18 / +6 deg on
# every DAC -- AM/AM + AM/PM -- while at -18 and -30 dBFS every weight is
# linear to ~3 % / 1 deg), which breaks the superposition the test relies on
ap.add_argument("--amp", type=float, default=0.125, help="tone amplitude (fc32 full scale 1)")
ap.add_argument("--nsamps", type=int, default=32768, help="RX samples per channel per capture")
ap.add_argument("--angles", default="0,15,30,-45,60", help="steering angles to test, degrees")
ap.add_argument("--carrier", type=float, default=None, help="ULA carrier, Hz (default: daemon's)")
ap.add_argument("--spacing", type=float, default=None, help="ULA spacing, m (default: daemon's)")
ap.add_argument("--snr-db", type=float, default=25.0, help="min tone-to-noise for a usable path")
ap.add_argument("--margin", type=float, default=4.0, help="pass: error < margin x repeatability floor")
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
tree = usrp.get_tree()
n = usrp.get_tx_num_channels()
if n < 2 or not tree.exists(BF + "/enable"):
    sys.exit("needs an N >= 2 build with the TX beamformer (device arg channels=N)")
rate = usrp.get_rx_rate(0)
chans = list(range(n))
for c in chans:
    usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), c)
    usrp.set_tx_freq(uhd.types.TuneRequest(a.freq), c)
sa = uhd.usrp.StreamArgs("fc32", "sc16")
sa.channels = chans
rxs = usrp.get_rx_stream(sa)
txs = usrp.get_tx_stream(sa)
if a.carrier:
    usrp.set_user_register(REG_CARRIER, int(round(a.carrier / 1e3)))
if a.spacing:
    usrp.set_user_register(REG_SPACING, int(round(a.spacing * 1e9)))
print(f"N = {n}, {rate / 1e6:g} MS/s per channel, centre {usrp.get_tx_freq(0) / 1e6:g} MHz "
      f"(range {usrp.get_tx_freq_range(0).start() / 1e6:g}..{usrp.get_tx_freq_range(0).stop() / 1e6:g} MHz), "
      f"tone {a.tone / 1e6:g} MHz at {20 * math.log10(a.amp):.1f} dBFS")

lead = 8192                       # TX samples before the RX window opens
ntx = lead + a.nsamps + 4096
tx = np.zeros((n, ntx), dtype=np.complex64)
tx[0] = (a.amp * np.exp(2j * np.pi * a.tone * np.arange(ntx) / rate)).astype(np.complex64)
tt = np.arange(a.nsamps) / rate
sign = [None]


def capture():
    """one timed burst -> (tone amplitude, noise amplitude) per RX channel"""
    t0 = usrp.get_time_now().get_real_secs() + 0.15
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
    if sign[0] is None:   # the tone's sign after up- and down-conversion
        p = np.abs(rx @ np.exp(-2j * np.pi * a.tone * tt)).sum()
        m = np.abs(rx @ np.exp(+2j * np.pi * a.tone * tt)).sum()
        sign[0] = 1 if p >= m else -1
    f = sign[0] * a.tone
    y = rx @ np.exp(-2j * np.pi * f * tt) / a.nsamps
    noise = np.abs(rx @ np.exp(-2j * np.pi * (f + 1.37e6) * tt) / a.nsamps)  # an empty bin
    return y, noise


def load_raw(w):
    for c in chans:
        re, im = int(round(w[c].real)), int(round(w[c].imag))
        usrp.set_user_register(REG_W0 + c, (re & 0xFFFF) | ((im & 0xFFFF) << 16))
    usrp.set_user_register(REG_LOAD, 1)


def loaded():
    v = [int(x) for x in tree.access_str(BF + "/weights_str").get().split(",")]
    return (np.array(v[0::2]) + 1j * np.array(v[1::2])) / 32767.0


def db(x):
    return 20 * math.log10(max(float(x), 1e-15))


def rel_err(y, p, rows):
    return np.linalg.norm(y[rows] - p[rows]) / np.linalg.norm(p[rows])


# 1. H, twice
usrp.set_user_register(REG_ENABLE, 1)
Hs, noise = [], np.zeros(n)
for rep in range(2):
    H = np.zeros((n, n), dtype=complex)
    for c in chans:
        e = np.zeros(n, dtype=complex)
        e[c] = 32767
        load_raw(e)
        H[:, c], nz = capture()
        noise = np.maximum(noise, nz)
    Hs.append(H)
H = (Hs[0] + Hs[1]) / 2
snr = np.array([[db(abs(H[r, c]) / noise[r]) for c in chans] for r in chans])
print("1. |H| dBFS (rows RX, columns TX; one-hot weights):")
for r in chans:
    print(f"   RX{r} " + " ".join(f"{db(abs(H[r, c])):6.1f}" for c in chans) + f"   noise {db(noise[r]):6.1f}")
tx_ok = [c for c in chans if snr[:, c].max() >= a.snr_db]
rx_ok = [r for r in chans if snr[r, tx_ok].min(initial=99) >= a.snr_db] if tx_ok else []
print(f"   usable: TX {tx_ok} (heard {a.snr_db:g} dB above noise), RX {rx_ok} (hear every usable TX)")
tx_dead = [c for c in chans if c not in tx_ok]
floor = rel_err(Hs[1][np.ix_(rx_ok, tx_ok)].ravel(), Hs[0][np.ix_(rx_ok, tx_ok)].ravel(),
                slice(None)) if rx_ok else float("nan")
print(f"   repeatability floor (two H measurements): {db(floor):.1f} dB")

fails = 0


def check(ok, what):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + what)
    fails += not ok


if not rx_ok or len(tx_ok) < 2:
    print("RESULT: CANNOT TEST -- fewer than 2 usable TX paths or no usable RX antenna")
    sys.exit(2)
lim = max(a.margin * floor, 10 ** (-30 / 20))


def measure_h(w_now):
    """H columns of the usable TX, then the weights w_now back in place"""
    Hn = np.zeros((n, n), dtype=complex)
    for c in tx_ok:
        e = np.zeros(n, dtype=complex)
        e[c] = 32767
        load_raw(e)
        Hn[:, c], _ = capture()
    load_raw(np.round(w_now * 32767))
    return Hn


def incoherent(Hm, w):
    return np.sqrt(sum(sum(abs(Hm[r, c] * w[c]) for c in tx_ok) ** 2 for r in rx_ok))


def compare(label, w, restore):
    """restore() puts the case's weights back after the H measurements"""
    Hb = measure_h(w)
    restore()
    y, _ = capture()
    Ha = measure_h(w)
    restore()
    Hm = (Hb + Ha) / 2
    p = Hm @ w
    scale = incoherent(Hm, w)
    err = np.linalg.norm(y[rx_ok] - p[rx_ok]) / scale
    drift = np.linalg.norm((Ha - Hb)[np.ix_(rx_ok, tx_ok)] @ w[tx_ok]) / scale
    lim_c = max(a.margin * drift, a.margin * floor, 10 ** (-30 / 20))
    sub = Hm[np.ix_(rx_ok, tx_ok)]
    w_hat = np.linalg.lstsq(sub, y[rx_ok], rcond=None)[0]
    print(f"   {label}: |prediction| per RX (dBFS) " + " ".join(f"{db(abs(p[r])):6.1f}" for r in rx_ok)
          + f"; error {db(err):.1f} dB, drift {db(drift):.1f} dB")
    print(f"      w     TX{tx_ok}: " + "  ".join(f"{abs(w[c]):.3f}/{math.degrees(np.angle(w[c])):+6.1f}"
                                          for c in tx_ok))
    print(f"      w_hat (cond {np.linalg.cond(sub):.1f}): " + "  ".join(
        f"{abs(x):.3f}/{math.degrees(np.angle(x)):+6.1f}" for x in w_hat))
    check(err < lim_c, f"{label}: measured = H @ w within {db(lim_c):.1f} dB ({db(err):.1f} dB)")


# 2. bypass, bracketed like every case below: H[:, 0] (beamformer, one-hot)
# right before and after the bypass capture
def h0():
    e = np.zeros(n, dtype=complex)
    e[0] = 32767
    load_raw(e)
    usrp.set_user_register(REG_ENABLE, 1)
    return capture()[0]


hb = h0()
usrp.set_user_register(REG_ENABLE, 0)
y, _ = capture()
ha = h0()
h0m = (hb + ha) / 2
e0 = rel_err(y, h0m, rx_ok)
d0 = rel_err(ha, hb, rx_ok)
lim0 = max(a.margin * d0, a.margin * floor, 10 ** (-30 / 20))
print(f"2. bypass (TX ch0 straight to DAC 0): drift {db(d0):.1f} dB")
check(e0 < lim0, f"bypass = H[:, 0] within {db(lim0):.1f} dB ({db(e0):.1f} dB)")

# 3. steering
usrp.set_user_register(REG_ENABLE, 1)
print(f"3. steering (carrier {tree.access_double(BF + '/carrier_freq').get() / 1e9:g} GHz, spacing "
      f"{tree.access_double(BF + '/element_spacing').get() * 1e3:g} mm):")
for ang in [float(x) for x in a.angles.split(",")]:
    usrp.set_user_register(REG_ANGLE, int(round(ang * 1000)) & 0xFFFFFFFF)
    w = loaded()
    ang_rb = tree.access_double(BF + "/angle_deg").get()
    check(abs(ang_rb - ang) < 1e-6, f"angle reads back {ang_rb:g}")
    compare(f"angle {ang:+5.1f} deg", w,
            lambda: usrp.set_user_register(REG_ANGLE, int(round(ang * 1000)) & 0xFFFFFFFF))

# 4. raw weights: magnitudes 1, 1/2, 1/4, 1/8 and phases in 90-degree steps
w = np.array([0.5 ** (c % 4) * np.exp(1j * math.pi / 2 * c) for c in chans])
load_raw(np.round(w * 32767))
print("4. raw weights through set_user_register 16+c / 15:")
check(np.allclose(loaded(), np.round(w * 32767) / 32767), "weights_str reads back what was written")
wq = np.round(w * 32767)
compare("raw pattern", loaded(), lambda: load_raw(wq))

usrp.set_user_register(REG_ENABLE, 0)
if tx_dead:
    print(f"note: TX {tx_dead} not heard on any RX antenna -- their weights were not verified over the air")
print("RESULT:", "PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
