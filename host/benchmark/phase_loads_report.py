#!/usr/bin/env python3
"""phase_loads_report.py -- are the inter-channel phase offsets the same on
every bitstream load? Reads the matrices phase_matrix_ota.py --save wrote,
one file per load, and per condition prints, for every NT1R (TX offsets at
each RX) and 1TNR (RX offsets from each TX) pair:
  mean    circular mean over the loads, deg
  sd      circular standard deviation over the loads, deg
  max     largest deviation of one load from the mean, deg
plus the within-load repeat spread (the measurement floor) and the level
spread over the loads.

    python3 benchmark/phase_loads_report.py nomts:/tmp/phase10_nomts_*.npz mts:/tmp/phase10_mts_*.npz
"""
import glob
import math
import sys

import numpy as np


def wrap(d):
    return (np.asarray(d) + 180.0) % 360.0 - 180.0


def cstats(deg):
    """circular mean, sd and max deviation (deg) of a set of angles"""
    z = np.exp(1j * np.radians(deg))
    m = np.angle(z.mean())
    R = min(abs(z.mean()), 1.0)
    sd = math.degrees(math.sqrt(-2.0 * math.log(R))) if R > 0 else float("inf")
    return math.degrees(m), abs(sd), float(np.max(np.abs(wrap(np.degrees(np.angle(z)) - math.degrees(m)))))


for arg in sys.argv[1:]:
    name, pat = arg.split(":", 1)
    files = sorted(glob.glob(pat), key=lambda f: int(''.join(c for c in f.rsplit('_', 1)[-1] if c.isdigit()) or 0))
    if not files:
        print(f"{name}: no files for {pat}")
        continue
    Hs = [np.load(f)["H"] for f in files]
    reps = [np.load(f)["Hs"] for f in files]
    n = Hs[0].shape[0]
    print(f"\n===== {name}: {len(files)} bitstream loads, {n}x{n}")
    floor = max(float(np.max(np.abs(wrap(np.degrees(np.angle(r / r[:, :1, :1] / (r[0] / r[0][:1, :1]))))))) for r in reps)
    lv = np.array([20 * np.log10(np.abs(H)) for H in Hs])
    print(f"   within-load repeat spread (floor): max {floor:.2f} deg; level spread over loads: "
          f"max {float(np.max(lv.max(0) - lv.min(0))):.2f} dB")
    worst = 0.0
    print(f"   {n}T1R -- TX offsets vs TX0 (deg): mean / sd / max deviation over the loads")
    for r in range(n):
        cells = []
        for t in range(1, n):
            m, sd, mx = cstats([math.degrees(np.angle(H[r, t] / H[r, 0])) for H in Hs])
            worst = max(worst, mx)
            cells.append(f"TX{t} {m:+7.1f} / {sd:4.1f} / {mx:4.1f}")
        print(f"     at RX{r}: " + "   ".join(cells))
    print(f"   1T{n}R -- RX offsets vs RX0 (deg): mean / sd / max deviation over the loads")
    for t in range(n):
        cells = []
        for r in range(1, n):
            m, sd, mx = cstats([math.degrees(np.angle(H[r, t] / H[0, t])) for H in Hs])
            worst = max(worst, mx)
            cells.append(f"RX{r} {m:+7.1f} / {sd:4.1f} / {mx:4.1f}")
        print(f"     from TX{t}: " + "   ".join(cells))
    # per-load view of one representative pair each way
    print("   per load (RX1: TX1..3 vs TX0 | TX0: RX1..3 vs RX0), deg:")
    for i, H in enumerate(Hs):
        a = [wrap(math.degrees(np.angle(H[1, t] / H[1, 0]))) for t in range(1, n)]
        b = [wrap(math.degrees(np.angle(H[r, 0] / H[0, 0]))) for r in range(1, n)]
        print(f"     load {i + 1:2d}: " + " ".join(f"{x:+7.1f}" for x in a) + "  | " + " ".join(f"{x:+7.1f}" for x in b))
    print(f"   SUMMARY {name}: worst load-to-load deviation of any channel offset {worst:.1f} deg "
          f"(floor {floor:.2f} deg)")
