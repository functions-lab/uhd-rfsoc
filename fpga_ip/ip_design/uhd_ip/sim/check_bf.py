#!/usr/bin/env python3
"""Weight generator and checker for tb_tx_beamformer.sv (rtl/tx_beamformer.v).

  check_bf.py gen   --nch N --out weights.hex
      NSETS (8) weight sets of N words, one hex word per line ({imag, real}
      int16, Q1.15): steering sets from rfsoc_lib/dsp/beamformer.py
      (Beamformer(num_channels=N).compute_weights_fixed_point(angle)), random
      sets with corner values, and the all -1-1j overflow corner.

  check_bf.py check bf.log
      Replays the tb log against an exact model of the beamformer IP
      (beamformer_channel.sv):
          P_re = I*wI - Q*wQ,  P_im = I*wQ + Q*wI   (32-bit signed)
          out  = (P[30:15] + P[14]) mod 2^16         (round half up, wraps)
      Every output beat n must equal f_state(input beat n), where the state is
      (enable, weight set). States advance only through the logged events, in
      order (a later state may be reached directly when two events crossed
      together, never an earlier one), and each event must have taken effect
      for every beat accepted DEADLINE beats after its AXI write completed.
      A beat matching neither the current nor a later state -- a torn weight
      set, a duplicated / dropped / reordered beat -- fails.
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, *[".."] * 4))
sys.path.insert(0, REPO)

NSETS = 8
WDEF = 0x00007FFF
DEADLINE = 48          # beats; CDC latency is ~15 aclk cycles at most here
ANGLES = {0: 0.0, 1: 30.0, 2: -45.0, 5: 60.0, 7: -17.5}


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def cmul(x, w):
    """One 32-bit slot x ({Q,I}) times weight w, exactly as beamformer_channel."""
    i, q = s16(x), s16(x >> 16)
    wi, wq = s16(w), s16(w >> 16)
    out = []
    for p in (i * wi - q * wq, i * wq + q * wi):
        p &= 0xFFFFFFFF                      # the 32-bit intermediate
        out.append(((p >> 15) + ((p >> 14) & 1)) & 0xFFFF)
    return out[0] | (out[1] << 16)


def beamform(beat, ws, nch, bw):
    w = bw // nch
    s = w // 32
    ch0 = [(beat >> (32 * k)) & 0xFFFFFFFF for k in range(s)]
    out = 0
    for c in range(nch):
        for k in range(s):
            out |= cmul(ch0[k], ws[c]) << (c * w + 32 * k)
    return out


def steering(nch, angle):
    from rfsoc_lib.dsp.beamformer import Beamformer
    re, im = Beamformer(num_channels=nch).compute_weights_fixed_point(angle)
    return [((int(i) & 0xFFFF) << 16) | (int(r) & 0xFFFF) for r, i in zip(re, im)]


def gen(args):
    rng = random.Random(args.seed)
    corners = [0x8000, 0x7FFF, 0x8001, 0x0000, 0xFFFF, 0x0001]
    sets = []
    for k in range(NSETS):
        if k in ANGLES:
            sets.append(steering(args.nch, ANGLES[k]))
        elif k == 4:
            sets.append([0x80008000] * args.nch)          # -1-1j: overflow corner
        else:
            sets.append([(rng.choice(corners) if rng.random() < .3 else rng.getrandbits(16)) |
                         ((rng.choice(corners) if rng.random() < .3 else rng.getrandbits(16)) << 16)
                         for _ in range(args.nch)])
    with open(args.out, "w") as f:
        for ws in sets:
            for w in ws:
                f.write("%08x\n" % w)
    for k, a in ANGLES.items():
        print("  set %d: angle %+.1f deg  w = %s" % (k, a, " ".join("%08x" % w for w in sets[k])))


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

    # state list: (enable, weights, name, deadline beat, issue beat)
    en, ws = 0, [WDEF] * nch
    states = [(en, tuple(ws), "reset", 0, 0)]
    for (n0, n1, kind, rest) in events:
        if kind == "EN":
            en = int(rest[0])
        elif kind == "LOAD":
            ws = [int(x, 16) for x in rest]
        elif kind == "SRST":
            en, ws = 0, [WDEF] * nch
        elif kind == "ARST":
            continue                          # must NOT change anything
        states.append((en, tuple(ws), "%s@%d" % (kind, n1), n1 + DEADLINE, n0))

    cache = {}

    def expect(si, n):
        key = (states[si][0], states[si][1], n)
        if key not in cache:
            cache[key] = ins[n] if states[si][0] == 0 else beamform(ins[n], states[si][1], nch, bw)
        return cache[key]

    cur = 0
    counts = {"bypass": 0, "beamform": 0, "corner_slots": 0}
    switches = 0
    for n in sorted(outs):
        if n not in ins:
            errors.append("output beat %d has no input" % n)
            break
        # the latest state whose deadline has passed is mandatory
        need = max(i for i in range(len(states)) if states[i][3] <= n)
        found = None
        for si in range(max(cur, need), len(states)):
            if outs[n] == expect(si, n):
                found = si
                break
        if found is not None and found > cur and states[found][4] > n:
            # took effect on a beat accepted before the AXI write even started
            errors.append("beat %d: state %s before its write was issued" % (n, states[found][2]))
        if found is None or found < need:
            if len(errors) < 10:
                exp = expect(max(cur, need), n)
                diff = [k for k in range(bw // 32)
                        if ((exp ^ outs[n]) >> (32 * k)) & 0xFFFFFFFF]
                errors.append("beat %d: matches no allowed state (current %s, required >= %s); "
                              "slots differing from %s: %s" % (
                                  n, states[cur][2], states[need][2], states[max(cur, need)][2], diff[:8]))
            continue
        if found != cur:
            switches += 1
        cur = found
        counts["beamform" if states[cur][0] else "bypass"] += 1
        if (ins[n] & 0xFFFFFFFF) in (0x80008000, 0x7FFF7FFF, 0x80007FFF):
            counts["corner_slots"] += 1
    if cur != len(states) - 1:
        errors.append("ended in state %s, not the last event %s" % (states[cur][2], states[-1][2]))

    tag = "N_CH=%d BEAT_W=%d" % (nch, bw)
    if errors:
        for e in errors:
            print("  ERROR " + e)
        print("BF_CHECK FAIL %s" % tag)
        sys.exit(1)
    print("BF_CHECK PASS %s: %d beats (%d bypass bit-exact, %d beamformed exact), "
          "%d events, %d state switches, %d corner ch0 slot-0 beats" % (
              tag, len(outs), counts["bypass"], counts["beamform"], len(events),
              switches, counts["corner_slots"]))


def selftest():
    # spot values of the IP arithmetic
    assert cmul(0x00004000, 0x00004000) == 0x00002000          # .5 * .5
    assert cmul(0x80008000, 0x80008000) == 0x00000000           # (-1-1j)^2 = 2j -> wraps
    assert cmul(0x00008000, 0x00008000) == 0x00008000           # (-1)(-1) = +1 -> wraps to -1
    assert cmul(0x00007FFF, 0x00007FFF) == 0x00007FFE
    assert cmul(0x00000001, 0x00004000) == 0x00000001           # .5 LSB rounds up
    assert cmul(0x0000FFFF, 0x00004000) == 0x00000000           # -.5 LSB rounds up to 0


if __name__ == "__main__":
    selftest()
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--nch", type=int, required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--seed", type=int, default=1)
    c = sub.add_parser("check")
    c.add_argument("log")
    a = ap.parse_args()
    gen(a) if a.cmd == "gen" else check(a)
