#!/usr/bin/env python3
"""Weight generator and checker for tb_rx_beamformer.sv (src/rx_beamformer.v).

  check_rbf.py gen --nch N --out weights.hex --shifts shifts.hex
      NSETS weight sets of N words ({imag, real} int16, Q1.15, one hex word
      per line) and one SHIFT per set: steering sets from
      rfsoc_lib/dsp/beamformer.py, unity weights, random sets with corner
      values, the all -1-1j saturation corner; shifts log2(N), 0 and 15.

  check_rbf.py check rbf.log
      Replays the tb log against an exact model of the RX beamformer:
          acc_re = sum_c I_c*wI_c - Q_c*wQ_c,  acc_im = sum_c I_c*wQ_c + Q_c*wI_c
          y      = sat16((acc + 2^(14+SHIFT)) >> (15+SHIFT))   (round half up)
      enable 0: every output beat equals its input beat (bit-exact);
      enable 1: channel 0's slots are y, channels 1..N-1 equal the input.
      States (enable, weights, shift) advance only through the logged events,
      in order, each within DEADLINE beats of its AXI write; a beat that
      matches no allowed state (torn set, lost / duplicated / reordered beat)
      fails.
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, *[".."] * 5))
sys.path.insert(0, os.path.join(REPO, "rfsoc"))   # rfsoc_lib (the daemon's library)

NSETS = 9
WDEF = 0x00007FFF
DEADLINE = 48
ANGLES = {0: 0.0, 1: 30.0, 2: -45.0, 5: 60.0, 7: -17.5}


def log2(n):
    return n.bit_length() - 1


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def sat16(v):
    return max(-32768, min(32767, v)) & 0xFFFF


def beamform(beat, ws, shift, nch, bw):
    w = bw // nch
    out = beat & ~((1 << w) - 1)          # channels 1..N-1 unchanged
    for k in range(w // 32):
        are = aim = 0
        for c in range(nch):
            x = (beat >> (c * w + 32 * k)) & 0xFFFFFFFF
            i, q = s16(x), s16(x >> 16)
            wi, wq = s16(ws[c]), s16(ws[c] >> 16)
            are += i * wi - q * wq
            aim += i * wq + q * wi
        rnd = 1 << (14 + shift)
        yre = sat16((are + rnd) >> (15 + shift))
        yim = sat16((aim + rnd) >> (15 + shift))
        out |= (yre | (yim << 16)) << (32 * k)
    return out


def steering(nch, angle):
    from rfsoc_lib.dsp.beamformer import Beamformer
    re, im = Beamformer(num_channels=nch).compute_weights_fixed_point(angle)
    return [((int(i) & 0xFFFF) << 16) | (int(r) & 0xFFFF) for r, i in zip(re, im)]


def gen(args):
    rng = random.Random(args.seed)
    corners = [0x8000, 0x7FFF, 0x8001, 0x0000, 0xFFFF, 0x0001]
    L = log2(args.nch)
    sets, shifts = [], []
    for k in range(NSETS):
        if k in ANGLES:
            sets.append(steering(args.nch, ANGLES[k]))
        elif k == 3:
            sets.append([WDEF] * args.nch)                  # unity
        elif k == 4:
            sets.append([0x80008000] * args.nch)            # -1-1j: saturation corner
        else:
            sets.append([(rng.choice(corners) if rng.random() < .3 else rng.getrandbits(16)) |
                         ((rng.choice(corners) if rng.random() < .3 else rng.getrandbits(16)) << 16)
                         for _ in range(args.nch)])
        shifts.append({4: 0, 6: 15, 8: 0}.get(k, L))
    with open(args.out, "w") as f:
        for ws in sets:
            for w in ws:
                f.write("%08x\n" % w)
    with open(args.shifts, "w") as f:
        for s in shifts:
            f.write("%x\n" % s)
    print("  shifts per set: %s" % shifts)


def check(args):
    nch = bw = None
    ins, outs, events = {}, {}, []
    done = None
    with open(args.log) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "P":
                nch, bw = int(t[1]), int(t[2])
            elif t[0] == "I":
                ins[int(t[1])] = int(t[2], 16)
            elif t[0] == "O":
                outs[int(t[1])] = int(t[2], 16)
            elif t[0] == "E":
                events.append((int(t[1]), int(t[2]), t[3], t[4:]))
            elif t[0] == "D":
                done = (int(t[1]), int(t[2]))
    errors = []
    if done is None:
        errors.append("log has no D line (tb did not finish)")
    elif done[0] != done[1] or len(ins) != done[0] or len(outs) != done[1]:
        errors.append("beat counts: %s in, %s out, logged %d/%d" % (done[0], done[1], len(ins), len(outs)))

    L = log2(nch)
    en, ws, sh = 0, [WDEF] * nch, L
    states = [(en, tuple(ws), sh, "reset", 0, 0)]
    for (n0, n1, kind, rest) in events:
        if kind == "EN":
            en = int(rest[0])
        elif kind == "LOAD":
            sh = int(rest[0], 16)
            ws = [int(x, 16) for x in rest[1:]]
        elif kind == "SRST":
            en, ws, sh = 0, [WDEF] * nch, L
        elif kind == "ARST":
            continue
        states.append((en, tuple(ws), sh, "%s@%d" % (kind, n1), n1 + DEADLINE, n0))

    cache = {}

    def expect(si, n):
        st = states[si]
        key = (st[0], st[1], st[2], n)
        if key not in cache:
            cache[key] = ins[n] if st[0] == 0 else beamform(ins[n], st[1], st[2], nch, bw)
        return cache[key]

    cur = 0
    counts = {"bypass": 0, "beamform": 0, "saturated": 0}
    switches = 0
    w = bw // nch
    for n in sorted(outs):
        if n not in ins:
            errors.append("output beat %d has no input" % n)
            break
        need = max(i for i in range(len(states)) if states[i][4] <= n)
        found = None
        for si in range(max(cur, need), len(states)):
            if outs[n] == expect(si, n):
                found = si
                break
        if found is not None and found > cur and states[found][5] > n:
            errors.append("beat %d: state %s before its write was issued" % (n, states[found][3]))
        if found is None or found < need:
            if len(errors) < 10:
                exp = expect(max(cur, need), n)
                diff = [k for k in range(bw // 32) if ((exp ^ outs[n]) >> (32 * k)) & 0xFFFFFFFF]
                errors.append("beat %d: matches no allowed state (current %s, required >= %s); "
                              "slots differing: %s" % (n, states[cur][3], states[need][3], diff[:8]))
            continue
        if found != cur:
            switches += 1
        cur = found
        if states[cur][0]:
            counts["beamform"] += 1
            for k in range(w // 32):
                y = (outs[n] >> (32 * k)) & 0xFFFFFFFF
                if (y & 0xFFFF) in (0x7FFF, 0x8000) or (y >> 16) in (0x7FFF, 0x8000):
                    counts["saturated"] += 1
        else:
            counts["bypass"] += 1
    if cur != len(states) - 1:
        errors.append("ended in state %s, not the last event %s" % (states[cur][3], states[-1][3]))

    tag = "N_CH=%d BEAT_W=%d" % (nch, bw)
    if errors:
        for e in errors:
            print("  ERROR " + e)
        print("RBF_CHECK FAIL %s" % tag)
        sys.exit(1)
    print("RBF_CHECK PASS %s: %d beats (%d bypass bit-exact, %d beamformed exact, %d full-scale "
          "beam slots), %d events, %d state switches" % (
              tag, len(outs), counts["bypass"], counts["beamform"], counts["saturated"],
              len(events), switches))


def selftest():
    # 2 channels, 32-bit lanes, ch0 slot = beam
    one = 0x00007FFF
    # unity weights, shift 1: (x + x) * 32767 / 2^16 ~= x
    b = (0x00004000 << 32) | 0x00004000                     # both channels 0.5
    assert beamform(b, [one, one], 1, 2, 64) & 0xFFFFFFFF == 0x00004000
    # saturation: (-1-1j) * (-1-1j) = 2j per channel, sum 4j at shift 0 -> +32767j
    b = (0x80008000 << 32) | 0x80008000
    y = beamform(b, [0x80008000] * 2, 0, 2, 64) & 0xFFFFFFFF
    assert y == 0x7FFF0000, hex(y)
    # channel 1 untouched
    assert beamform(b, [one, one], 1, 2, 64) >> 32 == 0x80008000
    # rounding half up of -0.5 LSB -> 0
    b = (0x00000000 << 32) | 0x0000FFFF                     # ch0 = -1 LSB, ch1 = 0
    assert beamform(b, [0x00004000, 0], 0, 2, 64) & 0xFFFFFFFF == 0


if __name__ == "__main__":
    selftest()
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--nch", type=int, required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--shifts", required=True)
    g.add_argument("--seed", type=int, default=1)
    c = sub.add_parser("check")
    c.add_argument("log")
    a = ap.parse_args()
    gen(a) if a.cmd == "gen" else check(a)
