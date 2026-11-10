#!/usr/bin/env python3
"""Coefficient generator and checker for tb_tx_dpd.sv (src/tx_dpd.v).

  check_dpd.py gen --out coefs.hex
      NSETS (8) coefficient sets, 40 hex words each (Q6.21, word 2i real and
      2i+1 imaginary of coefficient i): set 0 drives the output and the gains
      into saturation at full scale, the others are DPD-like sets (identity
      plus odd-order and lag terms), one with every rail near +-31.

  check_dpd.py check dpd.log
      Replays the tb log against rfsoc_lib/dsp/dpd.py dpd_fx(), the model
      the daemon and the host share:
        * m_axis at cycle t is s_axis at cycle t - 32 (valid and data) through
          the model, for every channel and every cycle;
        * each event (COMMIT, CTRL, the resets) changes a channel's state
          (coefficient set, bypass) at ONE beat between the start of its AXI
          write and the moment STATUS said it was applied: every sample of a
          beat sees either the old or the new state, the set and the bypass
          of a COMMIT change on the same beat, and the beat is searched;
        * the statistics read while idle equal the model's over the samples
          since the previous CLR_STATS (saturated rails, gains, peaks).
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, *[".."] * 5))
sys.path.insert(0, os.path.join(REPO, "rfsoc"))   # rfsoc_lib (the daemon's library)
from rfsoc_lib.dsp import dpd  # noqa: E402

NSETS = 8
LAT = 32               # aclk cycles s_axis -> m_axis
WARM = 4               # beats of history before a searched window


def gen(out):
    rng = np.random.default_rng(49)
    sets = []
    # 0: saturating -- gain 1.6 and a strong 3rd/5th order at full scale
    c = np.zeros(dpd.NCOEF, complex)
    c[0] = 1.6 + 0.2j
    c[dpd.idx_a(0, 1)] = 3.0 - 2.0j
    c[dpd.idx_a(0, 2)] = -6.0 + 1.0j
    c[dpd.idx_a(1, 3)] = 9.0
    c[dpd.idx_b(0, 2)] = -4.0j
    sets.append(c)
    for k in range(1, NSETS):
        c = np.zeros(dpd.NCOEF, complex)
        c[0] = 1.0 + 0.05 * (rng.normal() + 1j * rng.normal())
        sc = 0.3 if k < NSETS - 1 else 30.0
        for i in range(1, dpd.NCOEF):
            c[i] = sc * (rng.uniform(-1, 1) + 1j * rng.uniform(-1, 1)) / (1 + (i % 4))
        if k == NSETS - 1:                       # near the rails of the Q6.21 range
            c = np.clip(c.real, -30.99, 30.99) + 1j * np.clip(c.imag, -30.99, 30.99)
        sets.append(c)
    with open(out, "w") as f:
        for c in sets:
            for w in dpd.to_words(dpd.quantize(c)):
                f.write(f"{w:08x}\n")
    print(f"wrote {len(sets)} sets to {out}")


def parse(path):
    ins, outs, events, stats, clrs = {}, {}, [], [], []
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "P":
                nch, bw = int(t[1]), int(t[2])
            elif t[0] in ("I", "O"):
                if t[2] not in ("0", "1"):           # X / Z before the reset settled
                    continue
                (ins if t[0] == "I" else outs)[int(t[1])] = (
                    int(t[2]), int(t[3], 16) if not any(ch in t[3].lower() for ch in "xz") else None)
            elif t[0] == "E":
                events.append((int(t[1]), int(t[2]), int(t[3]), t[4], t[5:]))
            elif t[0] == "S":
                stats.append((int(t[1]), int(t[2]), int(t[3]), int(t[4]), int(t[5], 16)))
            elif t[0] == "C":
                clrs.append(int(t[1]))
    return nch, bw, ins, outs, events, stats, clrs


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def unpack(beat, nch, ssr):
    """beat -> (nch, ssr) I and Q arrays."""
    i = np.zeros((nch, ssr), np.int64)
    q = np.zeros((nch, ssr), np.int64)
    for c in range(nch):
        for k in range(ssr):
            w = (beat >> (32 * (c * ssr + k))) & 0xFFFFFFFF
            i[c, k], q[c, k] = s16(w), s16(w >> 16)
    return i, q


def check(path):
    nch, bw, ins, outs, events, stats, clrs = parse(path)
    ssr = bw // nch // 32
    cyc0, cyc1 = min(ins), max(ins)
    ncy = cyc1 - cyc0 + 1
    valid = np.zeros(ncy, bool)
    xi = np.zeros((nch, ncy, ssr), np.int64)
    xq = np.zeros((nch, ncy, ssr), np.int64)
    for t, (v, d) in ins.items():
        valid[t - cyc0] = bool(v)
        if v:
            if d is None:
                print(f"FAIL: X on a valid input beat at cycle {t}")
                return False
            i, q = unpack(d, nch, ssr)
            xi[:, t - cyc0], xq[:, t - cyc0] = i, q

    # per channel: the list of distinct states and, per beat, the state index
    ident = dpd.identity_q()
    sets = {c: [ident] for c in range(nch)}       # coefficient sets in order
    sidx = np.zeros((nch, ncy), np.int64)          # set per beat
    byp = np.ones((nch, ncy), bool)                 # bypass per beat (reset: bypass)

    def model(c, lo, hi):
        """Model output of channel c for beats [lo, hi) (start WARM beats earlier)."""
        a = max(0, lo - WARM)
        n = hi - a
        r = dpd.dpd_fx(xi[c, a:hi].reshape(-1), xq[c, a:hi].reshape(-1), sets[c],
                       set_idx=np.repeat(sidx[c, a:hi], ssr), bypass=np.repeat(byp[c, a:hi], ssr),
                       valid=np.repeat(valid[a:hi], ssr))
        return r.i.reshape(n, ssr)[lo - a:], r.q.reshape(n, ssr)[lo - a:], r

    yo = {}
    for t, (v, d) in outs.items():
        yo[t] = (v, d)

    def observed(c, lo, hi):
        oi = np.zeros((hi - lo, ssr), np.int64)
        oq = np.zeros((hi - lo, ssr), np.int64)
        for b in range(lo, hi):
            v, d = yo.get(b + cyc0 + LAT, (0, 0))
            if v and d is not None:
                i, q = unpack(d, nch, ssr)
                oi[b - lo], oq[b - lo] = i[c], q[c]
        return oi, oq

    def apply(c, b, new_set, new_byp):
        """From beat b on, channel c runs new_set (None: unchanged) and new_byp."""
        if new_set is not None:
            sets[c].append(new_set)
            sidx[c, b:] = len(sets[c]) - 1
        if new_byp is not None:
            byp[c, b:] = new_byp

    ok = True
    for (c0, c1, c2, kind, args) in events:
        lo = max(c0 - cyc0, 0)
        hi = min(c2 - cyc0 + 2, ncy)
        if kind == "COMMIT":
            todo = [(int(args[0]), dpd.from_words([int(w, 16) for w in args[2:42]]), bool(int(args[1])))]
        elif kind == "CTRL":
            todo = [(int(args[0]), None, bool(int(args[1])))]
        elif kind in ("SRST", "ARST"):
            todo = [(c, ident, True) for c in range(nch)]
            if kind == "ARST":
                lo = hi = c0 - cyc0
        else:
            continue
        for (c, cs, bp) in todo:
            if lo == hi:
                apply(c, lo, cs, bp)
                continue
            # search the beat
            end = min(hi + WARM, ncy)
            oi, oq = observed(c, lo, end)
            saved = (len(sets[c]), sidx[c].copy(), byp[c].copy())
            found = None
            for b in range(lo, hi + 1):
                sets[c] = sets[c][:saved[0]]
                sidx[c], byp[c] = saved[1].copy(), saved[2].copy()
                apply(c, b, cs, bp)
                mi, mq, _ = model(c, lo, end)
                if np.array_equal(mi, oi) and np.array_equal(mq, oq):
                    found = b
                    break
            if found is None:
                print(f"FAIL: {kind} ch{c} (write done at cycle {c1}, applied by {c2}): "
                      f"no switch beat reproduces the output")
                ok = False
                sets[c] = sets[c][:saved[0]]
                sidx[c], byp[c] = saved[1], saved[2]
                apply(c, hi, cs, bp)

    # full replay, every channel, every cycle
    bad = 0
    for c in range(nch):
        mi, mq, _ = model(c, 0, ncy)
        oi, oq = observed(c, 0, ncy)
        for b in range(ncy):
            v, d = yo.get(b + cyc0 + LAT, (None, None))
            if v is None:
                continue
            if bool(v) != valid[b]:
                if bad < 10:
                    print(f"FAIL: m_axis_tvalid at cycle {b + cyc0 + LAT} is {v}, s_axis_tvalid at "
                          f"{b + cyc0} was {int(valid[b])}")
                bad += 1
            elif v and (not np.array_equal(mi[b], oi[b]) or not np.array_equal(mq[b], oq[b])):
                if bad < 10:
                    print(f"FAIL: ch{c} beat at cycle {b + cyc0}: got I {oi[b].tolist()} Q {oq[b].tolist()}, "
                          f"model I {mi[b].tolist()} Q {mq[b].tolist()}")
                bad += 1
            elif not v and d is not None and d != 0:
                if bad < 10:
                    print(f"FAIL: invalid output beat at cycle {b + cyc0 + LAT} is not zero")
                bad += 1
    if bad:
        ok = False

    # statistics
    for (t, c, so, sg, pk) in stats:
        prev = [x for x in clrs if x < t]
        if not prev:
            continue
        a, b = prev[-1] - cyc0, t - cyc0
        _, _, r = model(c, a, b)
        n0 = (a - max(0, a - WARM)) * ssr
        m_so = int(r.sat_out[n0:].sum())
        m_sg = int(r.sat_gain[n0:].sum())
        vi = valid[a:b]
        pin = int(max(np.abs(xi[c, a:b][vi]).max(initial=0), np.abs(xq[c, a:b][vi]).max(initial=0)))
        pout = int(max(np.abs(r.i[n0:]).max(initial=0), np.abs(r.q[n0:]).max(initial=0)))
        want = (m_so, m_sg, (pout << 16) | pin)
        if (so, sg, pk) != want:
            print(f"FAIL: stats ch{c} at cycle {t}: sat_out {so} sat_gain {sg} peak {pk:08x}, "
                  f"model {want[0]} {want[1]} {want[2]:08x}")
            ok = False
        elif m_so + m_sg:
            print(f"  stats ch{c}: sat_out {so} sat_gain {sg} peak in {pin} out {pout} (model agrees)")

    ncommit = sum(1 for e in events if e[3] == "COMMIT")
    print(f"{'PASS' if ok else 'FAIL'}: N_CH={nch} BEAT_W={bw} SSR={ssr}: {ncy} cycles, "
          f"{ncommit} COMMITs, {len(events)} events, {len(stats)} statistics reads, {bad} bad beats")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    g = sp.add_parser("gen")
    g.add_argument("--out", required=True)
    k = sp.add_parser("check")
    k.add_argument("log")
    a = ap.parse_args()
    if a.cmd == "gen":
        gen(a.out)
    else:
        sys.exit(0 if check(a.log) else 1)


if __name__ == "__main__":
    main()
