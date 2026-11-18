#!/usr/bin/env python3
"""design_hb.py -- the half-band of every rate stage (rx_rate / tx_rate).

One ÷2 (RX) / ×2 (TX) stage below the RFDC's F = 40 (design:
docs/superpowers/specs/2026-11-17-low-rate-fir-design.md). Every stage is
"final quality", so one filter serves them all:

  passband  0 .. 0.4 x the output rate (0.2 of the input rate), ripple <= 0.05 dB
  stopband  0.6 x the output rate (0.3 of the input rate) .. , >= 80 dB
  half-band (every other tap 0, centre 1/2), N = 3 + 4n taps, 18-bit coefficients

The shortest N meeting the spec AFTER quantisation is chosen (the stopband
needs a margin over 80 dB: the 18-bit rounding fills the deepest nulls), with
the odd polyphase branch ((N+1)/2 taps, the FIR each stage runs) a multiple
of 32 taps: FIR Compiler pads a symmetric filter's half-length to a multiple
of its oversampling rate with leading zeros (C_COEF_FILE_LINES; measured:
13 -> 14 at 2 cycles per sample, -> 16 at 4), which delays its output by
that many samples against the hub's centre tap. A half-length of 16 is a
multiple of every rate the chains use that time-shares (2, 4, 8, 16), and
one multiplier covers it at 32 and 64.

    python3 design_hb.py          # design, print, write rate_hb.coe
    python3 design_hb.py --check  # exit 1 unless rate_hb.coe is this design and meets the spec

rate_hb.coe: one signed integer per line, the taps in order. The integers
are the coefficients x 2^17 (RX: centre 65536 = 0.5, DC gain 1); TX uses the
SAME integers read with 16 fractional bits (DC gain 2, the ×2 stage's
interpolation gain), so one file serves both directions.
"""
import argparse
import os
import sys

import numpy as np
from scipy.signal import freqz, remez

HERE = os.path.dirname(os.path.abspath(__file__))
COE = os.path.join(HERE, "rate_hb.coe")
FP, FS = 0.2, 0.3            # band edges, fraction of the input rate
RIPPLE_DB, ATTEN_DB = 0.05, 80.0
COEF_BITS, FRAC = 18, 17
MARGIN_DB = 3.0              # design margin over ATTEN_DB


def halfband(n_taps: int) -> np.ndarray:
    """Equiripple half-band of n_taps = 4J - 1 (Vaidyanathan / Nguyen:
    a type-II one-band design g of length 2J, h[2i] = g[i] / 2, centre 1/2)."""
    if (n_taps - 3) % 4:
        raise ValueError(f"{n_taps} taps: a half-band has 3 + 4n")
    j = (n_taps + 1) // 4
    g = remez(2 * j, [0, 2 * FP], [1], fs=1)
    h = np.zeros(n_taps)
    h[0::2] = g / 2
    h[n_taps // 2] = 0.5
    return h


def quantise(h: np.ndarray) -> np.ndarray:
    q = np.round(h * 2 ** FRAC).astype(np.int64)
    lim = 2 ** (COEF_BITS - 1)
    if q.max() >= lim or q.min() < -lim:
        raise ValueError("coefficient out of 18-bit range")
    return q


def measure(q: np.ndarray):
    """(passband ripple dB, stopband attenuation dB, DC gain) of integer taps."""
    w, hz = freqz(q / 2 ** FRAC, worN=1 << 15, fs=1)
    a = np.abs(hz)
    pb, sb = a[w <= FP], a[w >= FS]
    return (20 * np.log10(pb.max() / pb.min()), -20 * np.log10(sb.max()),
            q.sum() / 2 ** FRAC)


def is_halfband(q: np.ndarray) -> bool:
    c = len(q) // 2
    # zero at every even offset from the centre but the centre itself
    odd = [q[i] for i in range(len(q)) if (i - c) % 2 == 0 and i != c]
    return (len(q) - 3) % 4 == 0 and q[c] == 2 ** (FRAC - 1) and not any(odd) \
        and np.array_equal(q, q[::-1])


def meets(q: np.ndarray, margin: float = 0.0) -> bool:
    rip, att, _ = measure(q)
    return is_halfband(q) and rip <= RIPPLE_DB and att >= ATTEN_DB + margin


def design() -> np.ndarray:
    for n in range(23, 200, 4):
        if ((n + 1) // 2) % 32:
            continue
        q = quantise(halfband(n))
        if meets(q, MARGIN_DB):
            return q
    raise RuntimeError("no half-band up to 199 taps meets the spec")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check:
        if not os.path.exists(COE):
            print(f"FAIL: {COE} missing")
            return 1
        q = np.array([int(x) for x in open(COE).read().split()], dtype=np.int64)
        ok = meets(q) and np.array_equal(q, design())
        rip, att, dc = measure(q)
        print(f"{'PASS' if ok else 'FAIL'}: {len(q)} taps, ripple {rip:.4f} dB, "
              f"stopband {att:.1f} dB, DC gain {dc:.6f}")
        return 0 if ok else 1
    q = design()
    rip, att, dc = measure(q)
    with open(COE, "w") as f:
        f.write("\n".join(str(int(x)) for x in q) + "\n")
    print(f"PASS: {len(q)} taps ({np.count_nonzero(q)} non-zero), ripple {rip:.4f} dB, "
          f"stopband {att:.1f} dB, DC gain {dc:.6f} -> {COE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
