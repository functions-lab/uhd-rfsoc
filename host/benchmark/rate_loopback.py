#!/usr/bin/env python3
"""rate_loopback.py -- one rate of a template build: set it, then send a timed
TX pulse and find it in a timed RX capture (TX ch -> RX ch over the air).

Setting the rate makes the daemon retune its bitstream in place (Protocol
§8: RFDC factor, MMCM, MTS); the pulse proves the retuned converters
and the time base carry data. Per trial: an RX capture from tick T0 and a
pseudo-random QPSK pulse (sharp autocorrelation) at T0 + OFFSET; the
cross-correlation peak gives its delay (whole TX->RX latency, in samples) and
its height over the median.

    zcu216-uhd python3 benchmark/rate_loopback.py --args type=zcu216,addr=<ip>,channels=N --rate 312.5e6
A request between two rates is met from below (Protocol §8):
--expect names the rate that must be served (default: --rate).

PASS: the expected rate is served and every trial captures in full with the
pulse >= --min-db over the median. Prints 'LATREC {json}' per trial and one
'PASS|FAIL rate ...' line; exit status 0 on PASS.
"""
import argparse, json, sys, time
import numpy as np
import uhd

T = uhd.types
ap = argparse.ArgumentParser()
ap.add_argument("--args", default="type=zcu216")
ap.add_argument("--rate", type=float, required=True, help="rate requested")
ap.add_argument("--expect", type=float, help="rate that must be served (default: --rate)")
ap.add_argument("--chan", type=int, default=0, help="TX and RX channel")
ap.add_argument("--freq", type=float, default=950e6)
ap.add_argument("--trials", type=int, default=2)
ap.add_argument("--pulse", type=int, default=1024, help="pulse length, samples")
ap.add_argument("--cap", type=int, default=1 << 15, help="capture length, samples")
ap.add_argument("--offset", type=int, default=4096, help="TX start inside the capture, samples (x16)")
ap.add_argument("--lead", type=float, default=0.3, help="s from now to T0")
ap.add_argument("--ampl", type=float, default=0.5)
ap.add_argument("--min-db", type=float, default=20.0, help="pass: pulse peak over the median")
ap.add_argument("--otw", help="wire format of both streams (default: the otw= of --args, "
                "else sc16); a rate only sc8 / sc12 carry needs it (Protocol §10)")
a = ap.parse_args()
assert a.offset % 16 == 0
c = a.chan
# the device arg otw= declares the format with the rate request, so the
# daemon picks a build that carries it (Protocol §3, §8)
kv = dict(x.split("=", 1) for x in a.args.split(",") if "=" in x)
otw = a.otw or kv.get("otw", "sc16")
if kv.get("otw") != otw:
    a.args = ",".join([x for x in a.args.split(",") if not x.startswith("otw=")] + [f"otw={otw}"])

usrp = uhd.usrp.MultiUSRP(a.args)
usrp.set_rx_rate(a.rate, c)
usrp.set_tx_rate(a.rate, c)
rate = usrp.get_rx_rate(c)
usrp.set_rx_freq(T.TuneRequest(a.freq), c)
usrp.set_tx_freq(T.TuneRequest(a.freq), c)
tick = usrp.get_master_clock_rate()
tps = tick / rate                      # ticks per sample
usrp.set_time_now(T.TimeSpec(0.0))
time.sleep(0.1)

sa = uhd.usrp.StreamArgs("fc32", otw); sa.channels = [c]
rx = usrp.get_rx_stream(sa)
sa = uhd.usrp.StreamArgs("fc32", otw); sa.channels = [c]
tx = usrp.get_tx_stream(sa)

rng = np.random.default_rng(12345)
pulse = (a.ampl / np.sqrt(2) * ((rng.integers(0, 2, a.pulse) * 2 - 1)
         + 1j * (rng.integers(0, 2, a.pulse) * 2 - 1))).astype(np.complex64)
burst = np.concatenate([pulse, np.zeros(4096, np.complex64)])

recs, bad = [], []
for trial in range(a.trials):
    now = usrp.get_time_now().get_real_secs()
    q = int(round(16 * tps))           # T0 on a 16-sample boundary of the tick counter
    t0 = (int(round((now + a.lead) * tick)) // q) * q
    cmd = T.StreamCMD(T.StreamMode.num_done)
    cmd.num_samps = a.cap
    cmd.stream_now = False
    cmd.time_spec = T.TimeSpec.from_ticks(t0, tick)
    rx.issue_stream_cmd(cmd)

    md = T.TXMetadata()
    md.has_time_spec = True
    md.time_spec = T.TimeSpec.from_ticks(t0 + int(round(a.offset * tps)), tick)
    md.start_of_burst = True
    md.end_of_burst = True
    tx.send(burst, md, 1.0)

    buf = np.zeros(a.cap, np.complex64)
    got, first_ticks = 0, None
    rmd = T.RXMetadata()
    chunk = np.zeros((1, rx.get_max_num_samps()), np.complex64)
    deadline = time.time() + a.lead + 2.0
    while got < a.cap and time.time() < deadline:
        n = rx.recv(chunk, rmd, 0.5)
        if rmd.error_code not in (T.RXMetadataErrorCode.none, T.RXMetadataErrorCode.timeout):
            print(f"RX error {rmd.strerror()}", file=sys.stderr)
            break
        if n and first_ticks is None:
            first_ticks = rmd.time_spec.to_ticks(tick)
        take = min(n, a.cap - got)
        buf[got:got + take] = chunk[0, :take]
        got += take
    if got < a.cap or first_ticks is None:
        bad.append(f"trial {trial}: captured {got} of {a.cap}")
        continue
    nfft = 1 << int(np.ceil(np.log2(len(buf) + len(pulse))))
    xc = np.fft.ifft(np.fft.fft(buf, nfft) * np.conj(np.fft.fft(pulse, nfft)))[:len(buf)]
    m = np.abs(xc)
    k = int(np.argmax(m))
    db = 20 * np.log10(m[k] / (np.median(m) + 1e-12))
    start_off = (first_ticks - t0) / tps          # first sample vs T0, samples
    rec = dict(trial=trial, rate=rate, chan=c, delay=round(k + start_off - a.offset, 3),
               peak_db=round(float(db), 1), phase_deg=round(float(np.degrees(np.angle(xc[k]))), 2))
    recs.append(rec)
    print("LATREC " + json.dumps(rec), flush=True)
    if db < a.min_db:
        bad.append(f"trial {trial}: pulse {db:.1f} dB over the median < {a.min_db:g}")
    time.sleep(0.05)

want = a.expect or a.rate
if abs(rate - want) > 1e-6 * want:
    bad.append(f"rate {rate:.9g} served for {a.rate:.9g} asked, want {want:.9g}")
pk = f"pulse {min(r['peak_db'] for r in recs):.1f} dB" if recs else "no pulse"
dl = f", delay {min(r['delay'] for r in recs):g}..{max(r['delay'] for r in recs):g} samples" if recs else ""
asked = f" (asked {a.rate / 1e6:g})" if a.expect else ""
print(f"{'FAIL' if bad else 'PASS'} rate {rate / 1e6:g} MS/s{asked} ch{c}: {len(recs)}/{a.trials} trials, "
      f"{pk}{dl}, tick {tick / 1e6:g} MHz" + ("; " + "; ".join(bad) if bad else ""))
sys.exit(1 if bad else 0)
