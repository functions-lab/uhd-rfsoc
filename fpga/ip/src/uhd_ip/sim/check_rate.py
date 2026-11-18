#!/usr/bin/env python3
"""check_rate.py -- bit-exact model of the low-rate chains (rx_rate / tx_rate)
and the checks of their xsim runs (tb_rx_rate.sv / tb_tx_rate.sv).

The arithmetic (fpga/ip/src/uhd_ip/rate/LANES.md): every stage is the
half-band h of rate/rate_hb.coe (N = 4J - 1 taps, J = 16: 63; centre
65536 = 2^16, the integers x 2^17) in polyphase form:

  RX ÷2:  y[m] = sat16((sum_j g[j] xe[m-j] + 65536 xo[m-J] + 2^16) >> 17)
          xe[i] = x[2i], xo[i] = x[2i+1], g = h[0::2] (2J taps)
  TX ×2:  y[2m]   = sat16((sum_j g[j] x[m-j] + 2^15) >> 16)
          y[2m+1] = x[m-(J-1)]

(>> is arithmetic: round half up), per lane (I and Q of each channel), all
lanes alike. State starts at zero (the chain is reset before every depth).

    check_rate.py rx <dump> --nch N --depth k     # compare a tb dump
    check_rate.py selftest                        # the model vs the spec
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
COE = os.path.join(HERE, "..", "rate", "rate_hb.coe")


def coefs():
    h = np.array([int(x) for x in open(COE).read().split()], dtype=np.int64)
    assert (len(h) + 1) % 4 == 0 and h[len(h) // 2] == 65536
    return h[0::2]                      # the 2J odd-branch taps (even indices)


G = coefs()
J = len(G) // 2
RX_CENTRE_DELAY = J                     # xo[m - J]
TX_CENTRE_DELAY = J - 1                 # x[m - (J - 1)]


def sat16(v):
    return np.clip(v, -32768, 32767)


def fir(x, g=G):
    """Full-precision single-rate FIR, zero initial state (FIR Compiler's)."""
    x = np.asarray(x, dtype=np.int64)
    return np.convolve(x, g)[:len(x)]


def delay(x, d):
    x = np.asarray(x, dtype=np.int64)
    return np.concatenate([np.zeros(d, dtype=np.int64), x])[:len(x)]


def rx_stage(x):
    """One ÷2 stage of one lane: len(x) even -> len(x)/2 samples."""
    x = np.asarray(x, dtype=np.int64)
    n = len(x) // 2
    xe, xo = x[0:2 * n:2], x[1:2 * n:2]
    acc = fir(xe) + 65536 * delay(xo, RX_CENTRE_DELAY)
    return sat16((acc + (1 << 16)) >> 17)


def tx_stage(x):
    """One ×2 stage of one lane: len(x) -> 2 len(x) samples."""
    x = np.asarray(x, dtype=np.int64)
    y = np.empty(2 * len(x), dtype=np.int64)
    y[0::2] = sat16((fir(x) + (1 << 15)) >> 16)
    y[1::2] = delay(x, TX_CENTRE_DELAY)
    return y


def rx(x, k):
    for _ in range(k):
        x = rx_stage(x)
    return np.asarray(x, dtype=np.int64)


def tx(x, k):
    for _ in range(k):
        x = tx_stage(x)
    return np.asarray(x, dtype=np.int64)


# ---- spec checks of the model itself -------------------------------------
def tone(n, f, amp):
    t = np.arange(n)
    return np.round(amp * np.cos(2 * np.pi * f * t)).astype(np.int64)


def amp_at(y, f):
    """Amplitude of the tone at f (cycles/sample) in the settled half of y."""
    y = np.asarray(y, dtype=np.float64)
    t = np.arange(len(y))[len(y) // 2:]
    y = y[len(y) // 2:]
    return 2 * abs(np.mean(y * np.exp(-2j * np.pi * f * t)))


def level_db(y, f):
    return 20 * np.log10(amp_at(y, f) + 1e-9)


def selftest():
    errs = 0
    amp = 16000
    n = 1 << 14
    ref = 20 * np.log10(amp)
    # RX: passband (0.4 x out = 0.2 x in) flat, alias (0.6 x out = 0.3 .. 0.5 x in) >= 80 dB
    for f, lim, kind in ((0.01, 0.05, "pass"), (0.19, 0.05, "pass"),
                         (0.31, -80, "alias"), (0.45, -80, "alias")):
        y = rx_stage(tone(n, f, amp))
        fo = 2 * f if f < 0.25 else 1 - 2 * f       # where it lands at the output rate
        d = level_db(y, fo) - ref
        ok = abs(d) <= lim if kind == "pass" else d <= lim
        print(f"rx f_in {f:.2f}: {d:+.3f} dB ({kind}) {'ok' if ok else 'FAIL'}")
        errs += not ok
    # TX: passband flat (0.4 x in rate), image (1 - f) >= 80 dB down
    for f in (0.02, 0.38):
        y = tx_stage(tone(n, f, amp))
        sig, img = amp_at(y, f / 2), amp_at(y, (1 - f) / 2)
        g = 20 * np.log10(sig / amp)
        r = 20 * np.log10(img / sig + 1e-12)
        ok = abs(g) <= 0.05 and r <= -80
        print(f"tx f_in {f:.2f}: gain {g:+.3f} dB, image {r:.1f} dB {'ok' if ok else 'FAIL'}")
        errs += not ok
    # full scale saturates, never wraps
    for stage in (rx_stage, tx_stage):
        sq = np.where(np.arange(4096) % 64 < 32, 32767, -32768)
        y = stage(sq)
        ok = y.max() <= 32767 and y.min() >= -32768 and y.max() > 30000
        print(f"{stage.__name__} full-scale square: [{y.min()}, {y.max()}] {'ok' if ok else 'FAIL'}")
        errs += not ok
    # DC unity
    y = rx(np.full(1 << 12, 10000), 3)
    ok = abs(int(y[-1]) - 10000) <= 10          # 0.1 %: the half-band's DC gain is 1.00006
    y2 = tx(np.full(1 << 8, 10000), 3)
    ok2 = abs(int(y2[-1]) - 10000) <= 10
    print(f"DC: rx^3 {y[-1]}, tx^3 {y2[-1]} {'ok' if ok and ok2 else 'FAIL'}")
    errs += not (ok and ok2)
    print("PASS" if not errs else f"FAIL: {errs}")
    return 0 if not errs else 1


# ---- tb dumps ----------------------------------------------------------------
def read_dump(path):
    """Lines 'I <lane> <v>' (inputs, in order per lane) and 'O <lane> <v>'
    (outputs, in order per lane), '# ...' metadata, 'A <cycle> <lane...>' ignored."""
    ins, outs, meta = {}, {}, {}
    for ln in open(path):
        p = ln.split()
        if not p:
            continue
        if p[0] == "#" and len(p) >= 3:
            meta[p[1]] = p[2]
        elif p[0] == "I":
            ins.setdefault(int(p[1]), []).append(int(p[2]))
        elif p[0] == "O":
            outs.setdefault(int(p[1]), []).append(int(p[2]))
    return ins, outs, meta


def check_dump(direction, path):
    ins, outs, meta = read_dump(path)
    k = int(meta["depth"])
    model = rx if direction == "rx" else tx
    errs = 0
    lens = set()
    for lane in sorted(ins):
        want = model(ins[lane], k)
        got = np.array(outs.get(lane, []), dtype=np.int64)
        n = min(len(want), len(got))
        lens.add(len(got))
        if n < 64:
            print(f"lane {lane}: only {len(got)} outputs")
            errs += 1
            continue
        bad = np.nonzero(want[:n] != got[:n])[0]
        if len(bad):
            i = bad[0]
            print(f"lane {lane}: {len(bad)} mismatches, first at {i}: got {got[i]} want {want[i]}")
            errs += 1
    if len(lens) > 1:
        print(f"lanes produced different output counts {sorted(lens)}")
        errs += 1
    tag = f"{direction} depth {k} " + " ".join(f"{a}={b}" for a, b in sorted(meta.items()) if a != "depth")
    print(("PASS " if not errs else "FAIL ") + tag)
    return 0 if not errs else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("what", choices=("rx", "tx", "selftest"))
    ap.add_argument("dump", nargs="?")
    a = ap.parse_args()
    if a.what == "selftest":
        return selftest()
    return check_dump(a.what, a.dump)


if __name__ == "__main__":
    sys.exit(main())
