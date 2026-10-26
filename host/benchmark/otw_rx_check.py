#!/usr/bin/env python3
"""otw_rx_check.py -- bit-exact check of the FPGA RX OTW converter (Protocol
§5, §9, §10) on every channel of an N-channel build, through stock UHD.

Streams the section-5 test pattern (device arg pattern=1) as timed num_done
bursts into a preallocated buffer, writes one file per channel and burst in the
layout check_pattern_file.py reads and runs that checker on all channels of a
burst together (counter, Q = ~I, the otw rounding, the start tick against the
burst's time_spec, channel order/alignment).

  cpu sc16 : files hold the int16 the host made (wire v * 256 / * 16 / exact)
  cpu fc32 : files hold the floats (v / 128, / 2048, / 32768)
  cpu sc8  : (otw sc8 only, a copy) the int8 pairs, written as int16 v * 256

--bursts K splits --nsamps into K timed bursts (each checked against its own
start tick): at ~10 GB/s of wire data a single 10M-sample burst into a large
buffer can exceed what the host memory system absorbs (NIC rx_discards_phy).

    uhd-rfsoc python3 benchmark/otw_rx_check.py --args type=rfsoc,addr=<ip>,channels=4 \\
        --rate 625e6 --otw sc12 --cpu sc16 --nsamps 10000000
"""
import argparse
import os
import subprocess
import sys
import time

import numpy as np
import uhd

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", required=True, help="device args (channels=N, otw=sc8 for sc8-only builds)")
ap.add_argument("--rate", type=float, default=0.0, help="per-channel rate (0 = leave the build's)")
ap.add_argument("--otw", default="sc16")
ap.add_argument("--cpu", default="sc16", choices=("sc16", "fc32", "sc8"))
ap.add_argument("--nsamps", type=int, default=10_000_000, help="samples per channel, all bursts")
ap.add_argument("--bursts", type=int, default=1, help="split --nsamps into this many timed bursts (0 = ~4 MiB each)")
ap.add_argument("--hot", action="store_true",
                help="recv each burst into one small reused (cache-resident) buffer and copy it out "
                     "after the burst: the host memory bus then carries no capture writes while streaming")
ap.add_argument("--lead", type=float, default=0.1, help="s from issuing a burst to its start time")
ap.add_argument("--warmup", type=int, default=0, help="unchecked bursts streamed first")
ap.add_argument("--out", default="/dev/shm/otw_rx", help="directory for the per-channel files")
ap.add_argument("--keep", action="store_true", help="keep the capture files")
ap.add_argument("-v", "--verbose", action="store_true", help="log every recv() call")
a = ap.parse_args()

args = a.args if "pattern=" in a.args else a.args + ",pattern=1"
usrp = uhd.usrp.MultiUSRP(args)
if a.rate:
    usrp.set_rx_rate(a.rate)
n = usrp.get_rx_num_channels()
rate = usrp.get_rx_rate(0)
tree = usrp.get_tree()
tick_rate = tree.access_double("/mboards/0/tick_rate").get()
tps = int(round(tick_rate / rate))
isz = {"sc16": 4, "fc32": 8, "sc8": 2}[a.cpu]
if a.bursts <= 0:  # auto: ~4 MiB of CPU samples per burst (all channels)
    a.bursts = max(1, -(-a.nsamps * n * isz // (4 << 20)))
m = -(-a.nsamps // a.bursts)
print(f"build: N={n}, {rate / 1e6:g} MS/s per channel, tick_rate {tick_rate / 1e6:g} MHz "
      f"(tps {tps}), otw {a.otw}, cpu {a.cpu}, {a.bursts} burst(s) x {m} samples/channel", flush=True)

sa = uhd.usrp.StreamArgs(a.cpu, a.otw)
sa.channels = list(range(n))
rxs = usrp.get_rx_stream(sa)

# one (n, m) block per burst; pyuhd uses shape[1] as the sample count and
# strides[0] between channels, so the dtype only has to be the CPU item size.
# Each burst gets its own C-contiguous block: a column slice buf[:, a:b] of
# one wide array is not received correctly (only the first recv lands; the
# rest of the checked region stayed zero at N = 16 with --bursts > 1).
dt = {"sc16": np.uint32, "fc32": np.complex64, "sc8": np.uint16}[a.cpu]
buf = np.zeros((a.bursts, n, m), dtype=dt)
hot = np.ones((n, m), dtype=dt) if a.hot else None


def capture(label, seg):
    """one timed num_done burst into seg -> (ok, first time_spec)"""
    ns = seg.shape[1]
    dst = hot[:, :ns] if hot is not None else seg
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = ns
    cmd.stream_now = False
    cmd.time_spec = uhd.types.TimeSpec(usrp.get_time_now().get_real_secs() + a.lead)
    md = uhd.types.RXMetadata()
    got, first_ts, errors = 0, None, []
    t_start = time.time()
    rxs.issue_stream_cmd(cmd)
    while got < ns:
        tc = time.time()
        k = rxs.recv(dst[:, got:], md, 3.0)
        if a.verbose:
            print(f"  recv {(tc - t_start) * 1e3:8.2f} ms +{(time.time() - tc) * 1e3:7.2f} ms: {k} samples, "
                  f"{md.error_code}, eob {md.end_of_burst}", flush=True)
        if md.error_code != uhd.types.RXMetadataErrorCode.none:
            errors.append(f"{md.strerror()} after {got} samples")
            if md.error_code == uhd.types.RXMetadataErrorCode.timeout or len(errors) > 5:
                break
            continue
        if first_ts is None and k:
            first_ts = md.time_spec
        got += k
        if md.end_of_burst:
            break
    if got < ns or errors:  # drain a broken burst so the next one starts clean
        scratch = np.zeros((n, 1 << 16), dtype=dt)
        while True:
            rxs.recv(scratch, md, 0.5)
            if md.error_code == uhd.types.RXMetadataErrorCode.timeout or md.end_of_burst:
                break
    if hot is not None:
        seg[:, :got] = hot[:, :got]
    if a.verbose or not (got == ns and not errors):
        print(f"{label}: received {got}/{ns} samples/channel in {time.time() - t_start:.2f} s; errors: "
              f"{errors or 'none'}", flush=True)
    return got == ns and not errors, first_ts


for w in range(a.warmup):
    capture(f"warm-up {w + 1}/{a.warmup} (not checked)", buf[0])
t0s = []
for b in range(a.bursts):
    ok, ts = capture(f"burst {b + 1}/{a.bursts}", buf[b])
    if not ok:
        print("RESULT FAIL (capture) N=%d rate=%g otw=%s cpu=%s" % (n, rate, a.otw, a.cpu))
        sys.exit(2)
    t0s.append(ts.to_ticks(tick_rate))
print(f"captured {a.bursts} burst(s) x {m} samples/channel, no errors", flush=True)

here = os.path.dirname(os.path.abspath(__file__))
os.makedirs(a.out, exist_ok=True)
worst = 0
for b, t0 in enumerate(t0s):
    files = []
    for c in range(n):
        f = os.path.join(a.out, "b%02d_ch%02d.dat" % (b, c))
        x = buf[b, c]
        if a.cpu == "sc8":
            (x.view(np.int8).astype(np.int16) * 256).tofile(f)
        else:
            x.tofile(f)
        files.append(f)
    cmdline = [sys.executable, os.path.join(here, "..", "host", "tools", "check_pattern_file.py"), *files,
               "--type", "float" if a.cpu == "fc32" else "short", "--otw", a.otw,
               "--nsamps", str(m), "--tps", str(tps), "--chans", ",".join(map(str, range(n))),
               "--t0", str(t0)]
    r = subprocess.run(cmdline, capture_output=True, text=True)
    lines = (r.stdout + r.stderr).strip().splitlines()
    fails = [l for l in lines if "FAIL" in l]
    if fails:
        print("\n".join(fails[:20]))
    if r.returncode or a.verbose or b in (0, len(t0s) - 1):
        print(f"burst {b + 1} t0 {t0}: " + (lines[-1].strip() if lines else "(no checker output)"))
    worst = max(worst, r.returncode)
    if not a.keep:
        for f in files:
            os.unlink(f)
print("RESULT %s N=%d rate=%g otw=%s cpu=%s nsamps=%d (%d bursts) checker_rc=%d" % (
    "PASS" if worst == 0 else "FAIL", n, rate, a.otw, a.cpu, m * a.bursts, a.bursts, worst))
sys.exit(worst)
