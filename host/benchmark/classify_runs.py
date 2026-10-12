#!/usr/bin/env python3
"""classify_runs.py -- sort full-rate benchmark_rate runs by WHEN they lost data.

  python3 benchmark/classify_runs.py [log root ...]     (default /tmp/zcu216_oracle)

Reads every per-run log `bench_strict.sh` wrote under the roots (oracle.sh keeps
one directory per run: <OUT>/bench/<bitstream>_r<N>/*.log) and prints, per
(build, direction, wire format), how many runs were:

  clean       no error threshold exceeded
  cold start  every RX gap within the first COLD_S seconds of device time and
              fewer than SMALL_UNDR TX underruns: a one-off start-up loss after
              which the stream ran clean to the end. It does not count against
              sustaining the rate (rule set 2026-10-10).
  TX undr     no RX loss, fewer than SMALL_UNDR TX underruns: the log does not
              time them, so they are listed apart (counted as failures).
  SUSTAIN     anything else: a loss after the first COLD_S s, or one that never
              recovered (millions of underruns / ring-full events after a
              start-up gap).

Then one line per SUSTAIN / TX-undr run with the first RX gap time and the
losses, for attribution with the module's "DPDK RX closed" line.
"""
import collections
import glob
import os
import re
import sys

COLD_S = 1.0          # s of device time: a gap before this is a start-up loss
SMALL_UNDR = 1000     # TX underruns below this are "small"

roots = sys.argv[1:] or ["/tmp/zcu216_oracle"]
logs = []
for r in roots:
    logs += glob.glob(os.path.join(r, "**", "*.log"), recursive=True)

rows = []
for f in sorted(set(logs)):
    try:
        t = open(f, errors="replace").read()
    except OSError:
        continue
    if "Benchmark complete" not in t or "Testing" not in t:
        continue
    m = re.search(r"\((zcu216_v49_\w+)\): \d+ RX", t)
    build = m.group(1) if m else "?"
    m = re.search(r"tick rate (\d+) MHz", t)
    if not m:
        continue
    tick = float(m.group(1)) * 1e6
    rx, tx = "Testing receive rate" in t, "Testing transmit rate" in t
    d = "rxtx" if rx and tx else ("rx" if rx else "tx")
    m = re.search(r"_(sc\d+|fc32)_(sc\d+|fc32)\.log$", f)
    otw = m.group(2) if m else "?"
    fail = "The following error thresholds were exceeded" in t
    gaps = [int(x) / tick for x in re.findall(r"RX: gap: expected TSF (\d+)", t)]
    num = lambda k: int((re.search(k + r":\s+(\d+)", t) or [0, 0])[1])
    drop, und, ovr = num("Num dropped samples"), num("Num underruns detected"), num("Num overruns detected")
    rf = int((re.search(r"(\d+) ring-full polls", t) or [0, 0])[1])
    if not fail:
        cls = "clean"
    elif gaps and max(gaps) < COLD_S and und < SMALL_UNDR:
        cls = "cold start"
    elif not gaps and ovr == 0 and und < SMALL_UNDR:
        cls = "TX undr"
    else:
        cls = "SUSTAIN"
    rows.append((build, d, otw, cls, gaps[0] if gaps else None, drop, und, rf, f))

tab = collections.OrderedDict()
for b, d, o, c, *_ in sorted(rows):
    tab.setdefault((b, d, o), collections.Counter())[c] += 1
print("%-34s %-5s %-5s %5s %6s %10s %8s %8s %16s" % (
    "build", "dir", "otw", "runs", "clean", "cold start", "TX undr", "SUSTAIN", "rate sustained"))
for k, c in tab.items():
    n = sum(c.values())
    lo, hi = c["clean"] + c["cold start"], c["clean"] + c["cold start"] + c["TX undr"]
    span = f"{lo}" if lo == hi else f"{lo}-{hi}"
    print("%-34s %-5s %-5s %5d %6d %10d %8d %8d %16s" % (
        *k, n, c["clean"], c["cold start"], c["TX undr"], c["SUSTAIN"], f"{span} of {n}"))
print()
for b, d, o, c, g0, drop, und, rf, f in sorted(rows):
    if c in ("SUSTAIN", "TX undr"):
        g = f"{g0:.3f} s" if g0 is not None else "-"
        print(f"{c:8s} {b} {d} {o}: first RX gap {g}, dropped {drop}, underruns {und}, "
              f"ring-full polls {rf}  [{f}]")
