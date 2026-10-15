#!/usr/bin/env python3
"""rate_bandwidth.py -- the converters' bandwidth at a rate, with UHD tones
over the air, so a run-time rate change can be seen to change it.

The RF tone stays at --freq (the over-the-air channel is the same at every
point); only the digital offsets move, so the response is the RFDC filters':
  RX  TX sends a CW (DC baseband) at --freq; the RX NCO goes to freq - D, so
      the tone is at +D in RX baseband (aliased to D - rate past rate/2):
      the decimation filter's response at D.
  TX  TX sends a baseband tone at +D with its NCO at freq - D (RF tone still
      at --freq); RX sits at freq - 0.1 rate: the interpolation filter's
      response at D (a TX baseband tone cannot go past rate/2).
D runs over --fracs x rate; levels are relative to the first point. Per point
a timed TX burst and an RX capture inside it.

    zcu216-uhd python3 benchmark/rate_bandwidth.py --args type=zcu216,addr=<ip> --rate 625e6
    python3 benchmark/rate_bandwidth.py --compare <log>...   # the BWRES lines of several rates

PASS per rate (set before the measurement): RX and TX flat within 1 dB up to
0.35 x rate; the -3 dB edge between 0.38 and 0.5 x rate (UHD reports
bandwidth 0.8 x rate); RX at >= 0.6 x rate >= 40 dB down or at the noise
floor. --compare: the measured bandwidth in MHz scales with the rate within 5 %.
"""
import argparse, json, sys, time
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="type=zcu216")
ap.add_argument("--rate", type=float)
ap.add_argument("--chan", type=int, default=0)
ap.add_argument("--freq", type=float, default=950e6)
ap.add_argument("--ampl", type=float, default=0.1, help="TX tone amplitude (0.1 = -20 dBFS)")
ap.add_argument("--fracs", default="0.05,0.1,0.15,0.2,0.25,0.3,0.35,0.38,0.4,0.42,0.44,0.46,0.48,0.5,0.55,0.6,0.65,0.7")
ap.add_argument("--nfft", type=int, default=16384)
ap.add_argument("--compare", nargs="+", metavar="LOG")
a = ap.parse_args()


def edge(fr, db):
    """first D/rate where the response falls below -3 dB (linear interpolation)."""
    for i in range(1, len(fr)):
        if db[i] < -3.0 <= db[i - 1]:
            return fr[i - 1] + (fr[i] - fr[i - 1]) * (-3.0 - db[i - 1]) / (db[i] - db[i - 1])
    return None


if a.compare:
    res = []
    for p in a.compare:
        for line in open(p):
            if line.startswith("BWRES "):
                res.append(json.loads(line[6:]))
    res.sort(key=lambda r: -r["rate"])
    ref = res[0]
    bad = 0
    print(f"{'MS/s':>9} {'RX bw MHz':>10} {'TX bw MHz':>10} {'UHD bw MHz':>11} {'RX bw/rate':>10} {'vs top':>7}")
    for r in res:
        rx = r["rx_bw"] or float("nan")
        tx = r["tx_bw"] or float("nan")
        sc = (rx / ref["rx_bw"]) / (r["rate"] / ref["rate"]) if r["rx_bw"] and ref["rx_bw"] else float("nan")
        ok = abs(sc - 1) <= 0.05 and r["pass"]
        bad += not ok
        print(f"{r['rate'] / 1e6:9.3f} {rx / 1e6:10.2f} {tx / 1e6:10.2f} {r['uhd_bw'] / 1e6:11.2f} "
              f"{rx / r['rate']:10.3f} {sc:7.3f} {'ok' if ok else 'FAIL'}")
    print(f"{'PASS' if not bad else 'FAIL'} bandwidth scales with the rate: {len(res) - bad} of {len(res)} rates")
    sys.exit(1 if bad else 0)

import uhd  # noqa: E402

T = uhd.types
c = a.chan
usrp = uhd.usrp.MultiUSRP(a.args)
usrp.set_rx_rate(a.rate, c)
usrp.set_tx_rate(a.rate, c)
rate = usrp.get_rx_rate(c)
tick = usrp.get_master_clock_rate()
tps = tick / rate
uhd_bw = usrp.get_rx_bandwidth(c)
rx_rng, tx_rng = usrp.get_rx_freq_range(c), usrp.get_tx_freq_range(c)
usrp.set_time_now(T.TimeSpec(0.0))
time.sleep(0.1)
sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = [c]
rx = usrp.get_rx_stream(sa)
sa = uhd.usrp.StreamArgs("fc32", "sc16"); sa.channels = [c]
tx = usrp.get_tx_stream(sa)


def tune(f, is_rx):
    tr = T.TuneRequest(f)
    tr.rf_freq_policy = T.TuneRequestPolicy.manual
    tr.rf_freq = f
    tr.dsp_freq_policy = T.TuneRequestPolicy.manual
    tr.dsp_freq = 0.0
    (usrp.set_rx_freq if is_rx else usrp.set_tx_freq)(tr, c)


SKIP, NBURST = 4096, a.nfft + 8192
win = np.blackman(a.nfft).astype(np.float32)
wgain = win.sum()
chunk = np.zeros((1, rx.get_max_num_samps()), np.complex64)


def capture(fbb):
    """timed TX tone at baseband fbb Hz, RX capture inside it -> windowed spectrum (dBFS, freqs)."""
    n = np.arange(NBURST)
    burst = (a.ampl * np.exp(2j * np.pi * fbb / rate * n)).astype(np.complex64)
    now = usrp.get_time_now().get_real_secs()
    q = int(round(16 * tps))
    t0 = (int(round((now + 0.1) * tick)) // q) * q
    cmd = T.StreamCMD(T.StreamMode.num_done)
    cmd.num_samps = SKIP + a.nfft
    cmd.stream_now = False
    cmd.time_spec = T.TimeSpec.from_ticks(t0, tick)
    rx.issue_stream_cmd(cmd)
    md = T.TXMetadata()
    md.has_time_spec, md.start_of_burst, md.end_of_burst = True, True, True
    md.time_spec = T.TimeSpec.from_ticks(t0, tick)
    tx.send(burst, md, 1.0)
    buf = np.zeros(SKIP + a.nfft, np.complex64)
    got, rmd = 0, T.RXMetadata()
    deadline = time.time() + 2.0
    while got < len(buf) and time.time() < deadline:
        k = rx.recv(chunk, rmd, 0.5)
        if rmd.error_code not in (T.RXMetadataErrorCode.none, T.RXMetadataErrorCode.timeout):
            raise RuntimeError(f"RX error {rmd.strerror()}")
        take = min(k, len(buf) - got)
        buf[got:got + take] = chunk[0, :take]
        got += take
    if got < len(buf):
        raise RuntimeError(f"captured {got} of {len(buf)}")
    x = buf[SKIP:] * win
    X = np.fft.fftshift(np.fft.fft(x)) / wgain
    f = np.fft.fftshift(np.fft.fftfreq(a.nfft, 1 / rate))
    return 20 * np.log10(np.abs(X) + 1e-12), f


def level(spec, f, ftone):
    """tone level (dBFS) at ftone wrapped into [-rate/2, rate/2), +-3 bins; the noise floor (median)."""
    w = (ftone + rate / 2) % rate - rate / 2
    i = int(np.argmin(np.abs(f - w)))
    return float(spec[max(0, i - 3):i + 4].max()), float(np.median(spec)), float(f[int(np.argmax(spec))])


fracs = [float(x) for x in a.fracs.split(",")]
out = {"rate": rate, "uhd_bw": uhd_bw, "rx": [], "tx": []}
# RX: CW at freq, RX NCO at freq - D
tune(a.freq, False)
for fr in fracs:
    d = fr * rate
    if not rx_rng.start() <= a.freq - d <= rx_rng.stop():
        continue
    tune(a.freq - d, True)
    spec, f = capture(0.0)
    lv, floor, pk = level(spec, f, d)
    out["rx"].append((fr, lv, floor, pk))
# TX: baseband tone at +D, TX NCO at freq - D; RX at freq - 0.1 rate (tone at +0.1 rate)
tune(a.freq - 0.1 * rate, True)
for fr in fracs:
    if fr > 0.5:
        break
    d = fr * rate
    if not tx_rng.start() <= a.freq - d <= tx_rng.stop():
        continue
    tune(a.freq - d, False)
    spec, f = capture(d)
    lv, floor, pk = level(spec, f, 0.1 * rate)
    out["tx"].append((fr, lv, floor, pk))
tune(a.freq, False); tune(a.freq, True)

bad = []
res = {"rate": rate, "uhd_bw": uhd_bw}
for side in ("rx", "tx"):
    pts = out[side]
    ref = pts[0][1]
    fr = [p[0] for p in pts]
    db = [p[1] - ref for p in pts]
    for p, r in zip(pts, db):
        print(f"BWPT {side} D/rate {p[0]:.3f} D {p[0] * rate / 1e6:9.3f} MHz  {r:7.2f} dB  "
              f"(tone {p[1]:.1f} dBFS, floor {p[2]:.1f}, strongest bin {p[3] / 1e6:.3f} MHz)")
    flat = [r for f_, r in zip(fr, db) if f_ <= 0.35]
    if max(flat) - min(flat) > 2.0 or min(flat) < -1.0 or max(flat) > 1.0:
        bad.append(f"{side} passband {min(flat):.2f}..{max(flat):.2f} dB (want within 1 dB to 0.35 x rate)")
    e = edge(fr, db)
    if e is None or not 0.38 <= e <= 0.5:
        bad.append(f"{side} -3 dB edge {e} x rate (want 0.38..0.5)")
    res[side + "_edge"] = e
    res[side + "_bw"] = 2 * e * rate if e else None
    if side == "rx":
        floor_rel = np.median([p[2] for p in pts]) - ref
        for f_, r, p in zip(fr, db, pts):
            if f_ >= 0.6 and r > -40 and (p[1] - p[2]) > 6:
                bad.append(f"rx {f_:.2f} x rate only {r:.1f} dB down (floor {floor_rel:.1f})")
        stop = [r for f_, r in zip(fr, db) if f_ >= 0.6]
        res["rx_stop_db"] = round(max(stop), 1) if stop else None
        res["floor_db"] = round(float(floor_rel), 1)
res["pass"] = not bad
print("BWRES " + json.dumps(res))
fmt = lambda v: f"{v / 1e6:.2f}" if v else "none"
print(f"{'FAIL' if bad else 'PASS'} rate {rate / 1e6:g} MS/s: RX bandwidth {fmt(res['rx_bw'])} MHz, "
      f"TX {fmt(res['tx_bw'])} MHz (UHD says {uhd_bw / 1e6:g}); RX stopband {res.get('rx_stop_db')} dB"
      + ("; " + "; ".join(bad) if bad else ""))
sys.exit(1 if bad else 0)
