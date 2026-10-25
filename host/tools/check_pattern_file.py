#!/usr/bin/env python3
"""check_pattern_file.py -- verify a capture of the Protocol §5/§9 test pattern.

The pattern is keyed to the timestamp: the sample at tick t is I = int16(t & 0xFFFF),
Q = ~I. A contiguous capture therefore has I[k] = (I[0] + k*tps) & 0xFFFF and Q = ~I,
bit for bit. Works on rx_samples_to_file output:

    check_pattern_file.py /tmp/x.dat --type short --nsamps 1000000
    check_pattern_file.py /tmp/x.dat --type float          # fc32, compared after *32767

--t0 TICKS additionally requires the first sample to be the one at tick t0 (e.g. for a
timed stream command). --tps is ticks per sample (tick_rate / rate, default 1).
(--allow-zero-tail tolerates zero padding at the end of a capture.)

Multi-channel (section 9): one tick per slot and channel c of the sample at tick t
carries I = t + c. So each channel on its own is a counter with step tps = N, and
channels captured together differ by exactly their channel numbers:

    # rx_samples_to_file --channels 0,1,2,3 writes x.00.dat .. x.03.dat
    check_pattern_file.py x.00.dat x.01.dat x.02.dat x.03.dat --tps 4 --chans 0,1,2,3
    # a TX dump holds all N channels interleaved; split it, check the listed
    # channels as above and require the others to be all zero
    check_pattern_file.py txdump.dat --interleaved 4 --chans 1,3 --tps 4

--t0 then means the tick of sample 0, which channel c must show as I = t0 + c.

OTW formats (Protocol §10): --otw sc8|sc12|fc32 compares against the
pattern passed through the FPGA's conversion (server/vrt.py: sc8 = round-half-up
(x/256) saturated, sc12 = round-half-up(x/16) saturated, fc32 = x/32768) and the
host's scaling to the CPU format: --type short holds v*256 (sc8), v*16 (sc12) or
x (fc32); --type float/double holds v/128, v/2048 or x/32768. A dump of DAC
int16 samples (after the FPGA's wire -> int16) is checked the same way with
--type short. A quantised counter does not name its tick in every sample, so
the start tick is found by search; where a few start ticks fit equally (one
quantisation step spans several samples) all of them are carried into the
--t0 and channel-alignment checks.
Exit code 0 = bit-exact.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'rfsoc', 'server'))
import vrt  # noqa: E402

CPU_MULT = {'sc16': 1, 'sc8': 256, 'sc12': 16, 'fc32': 1}           # short = v * mult
CPU_SCALE = {'sc16': 32767.0, 'sc8': 128.0, 'sc12': 2048.0, 'fc32': 32768.0}  # float = v / scale


def load(path, typ, otw='sc16'):
    """-> (n, 2) array of the values on the wire: uint16 counter words for
    sc16/fc32 (exact formats), the signed sc8/sc12 integers otherwise."""
    dt = {'short': '<i2', 'float': '<f4', 'double': '<f8'}[typ]
    raw = np.fromfile(path, dtype=dt)
    if raw.size % 2:
        sys.exit('odd number of values in %s' % path)
    if typ == 'short':
        x = raw.astype(np.int64)
        m = CPU_MULT[otw]
        bad = np.flatnonzero(x % m)
        if bad.size:
            print('  FAIL: %s: %d values are not multiples of %d (otw %s); first at %d: %d' % (
                path, bad.size, m, otw, bad[0], x[bad[0]]))
            sys.exit(1)
        v = x // m
    else:
        f = raw.astype(np.float64) * CPU_SCALE[otw]
        v = np.round(f).astype(np.int64)
        if otw != 'sc16':  # every other format reaches the CPU exactly
            bad = np.flatnonzero(np.abs(f - v) > 1e-6)
            if bad.size:
                print('  FAIL: %s: %d values are not v/%g (otw %s); first at %d: %r' % (
                    path, bad.size, CPU_SCALE[otw], otw, bad[0], raw[bad[0]]))
                sys.exit(1)
    if otw in ('sc16', 'fc32'):
        return v.astype(np.int16).view(np.uint16).reshape(-1, 2)
    return v.reshape(-1, 2)


def expected(t, otw):
    """Wire values (I, Q) of the section-5 pattern at ticks t (int64 array)."""
    i = (t & 0xFFFF).astype(np.uint16)
    q = (~i).astype(np.uint16)
    return (vrt.quantize(i.view(np.int16), otw), vrt.quantize(q.view(np.int16), otw))


def check_quantized(iq, tps, label, otw):
    """sc8/sc12: the start ticks t0 & 0xFFFF for which the whole series is the
    quantised counter. Returns (ok, sorted candidate list)."""
    n = iq.shape[0]
    allt = np.arange(65536, dtype=np.int64)
    ei, eq = expected(allt, otw)
    cands = allt[(ei == iq[0, 0]) & (eq == iq[0, 1])]
    k = np.arange(min(n, 4096), dtype=np.int64)
    good = []
    for c in cands:
        ei, eq = expected(c + k * tps, otw)
        if np.array_equal(ei, iq[:k.size, 0]) and np.array_equal(eq, iq[:k.size, 1]):
            good.append(int(c))
    full = []
    kk = np.arange(n, dtype=np.int64)
    for c in good:
        ei, eq = expected(c + kk * tps, otw)
        if np.array_equal(ei, iq[:, 0]) and np.array_equal(eq, iq[:, 1]):
            full.append(c)
    if full:
        return True, full
    # report where the candidate that fits longest breaks
    if not cands.size:
        print('  FAIL: %s: first sample (%d, %d) is no %s value of the pattern' % (
            label, iq[0, 0], iq[0, 1], otw))
        return False, []
    km = kk[:65536]

    def first_bad(c):
        ei, eq = expected(c + km * tps, otw)
        b = np.flatnonzero((ei != iq[:km.size, 0]) | (eq != iq[:km.size, 1]))
        return b[0] if b.size else km.size
    c = int(max(cands, key=first_bad))
    ei, eq = expected(c + kk * tps, otw)
    bad = np.flatnonzero((ei != iq[:, 0]) | (eq != iq[:, 1]))
    j = bad[0]
    print('  FAIL: %s: %d samples break the %s counter; first at %d: (%d, %d) expected (%d, %d)' % (
        label, bad.size, otw, j, iq[j, 0], iq[j, 1], ei[j], eq[j]))
    return False, []


def trim(iq, a, label):
    """Apply --allow-zero-tail / --zero-head to rows (all-zero row = padding).
    Returns (iq, tail, ok)."""
    tail = 0
    zero = ~iq.reshape(iq.shape[0], -1).any(axis=1)
    if a.allow_zero_tail:
        nz = np.flatnonzero(~zero)
        last = nz[-1] + 1 if nz.size else 0
        tail = iq.shape[0] - last
        if tail <= a.allow_zero_tail:
            iq = iq[:last]
            zero = zero[:last]
        else:
            tail = 0
    if a.zero_head is not None:
        nz = np.flatnonzero(~zero)
        head = int(nz[0]) if nz.size else iq.shape[0]
        if head != a.zero_head:
            print('  FAIL: %s: %d leading zero samples, expected %d' % (label, head, a.zero_head))
            return iq, tail, False
        iq = iq[head:]
    return iq, tail, True


def check_counter(iq, tps, label):
    """I steps by tps, Q = ~I. Returns (ok, I[0])."""
    n = iq.shape[0]
    i0 = int(iq[0, 0])
    k = np.arange(n, dtype=np.int64)
    exp_i = ((i0 + k * tps) & 0xFFFF).astype(np.uint16)
    bad_i = np.flatnonzero(iq[:, 0] != exp_i)
    bad_q = np.flatnonzero(iq[:, 1] != (~iq[:, 0] & 0xFFFF))
    ok = True
    if bad_i.size:
        j = bad_i[0]
        print('  FAIL: %s: %d samples break the I counter; first at %d: I=%d expected %d' % (
            label, bad_i.size, j, iq[j, 0], exp_i[j]))
        ok = False
    if bad_q.size:
        j = bad_q[0]
        print('  FAIL: %s: %d samples have Q != ~I; first at %d: I=%04x Q=%04x' % (
            label, bad_q.size, j, iq[j, 0], iq[j, 1]))
        ok = False
    return ok, i0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='+', help='one file per channel (or one --interleaved dump)')
    ap.add_argument('--type', choices=('short', 'float', 'double'), default='short')
    ap.add_argument('--otw', choices=('sc16', 'sc8', 'sc12', 'fc32'), default='sc16',
                    help='OTW format the samples crossed (section 10)')
    ap.add_argument('--nsamps', type=int, default=0, help='expected sample count per channel (0 = any)')
    ap.add_argument('--t0', type=int, default=None, help='expected timestamp of sample 0')
    ap.add_argument('--tps', type=int, default=1, help='ticks per (per-channel) sample; N for an N-channel build')
    ap.add_argument('--chans', default='', help='device channel of each file (default 0,1,..); '
                    'with --interleaved: the channels that carry the pattern')
    ap.add_argument('--interleaved', type=int, default=0, metavar='N',
                    help='the single file holds N channels slot-interleaved (a TX dump)')
    ap.add_argument('--allow-zero-tail', type=int, default=0, help='accept up to N trailing zero samples')
    ap.add_argument('--zero-head', type=int, default=None,
                    help='require exactly N leading zero samples (timed TX lead-in) and skip them')
    a = ap.parse_args()

    ok = True
    if a.interleaved:
        if len(a.files) != 1:
            sys.exit('--interleaved takes exactly one file')
        n = a.interleaved
        raw = load(a.files[0], a.type, a.otw)
        if raw.shape[0] % n:
            print('  FAIL: %d slots is not a multiple of N=%d' % (raw.shape[0], n))
            sys.exit(1)
        rows = raw.reshape(-1, n, 2)  # [sample, channel, IQ]
        rows, tail, ok = trim(rows, a, a.files[0])
        chans = [int(c) for c in a.chans.split(',')] if a.chans else list(range(n))
        zero_chans = [c for c in range(n) if c not in chans]
        print('%s: %d samples x %d channels (%s)%s; pattern on %s%s' % (
            a.files[0], rows.shape[0], n, a.type, ', %d zero-pad samples ignored' % tail if tail else '',
            chans, ', zeros on %s' % zero_chans if zero_chans else ''))
        for c in zero_chans:
            nzc = int(np.count_nonzero(rows[:, c, :]))
            if nzc:
                print('  FAIL: channel %d should be all zero, has %d non-zero words' % (c, nzc))
                ok = False
        series = [(c, 'ch%d' % c, np.ascontiguousarray(rows[:, c, :])) for c in chans]
    else:
        chans = [int(c) for c in a.chans.split(',')] if a.chans else list(range(len(a.files)))
        if len(chans) != len(a.files):
            sys.exit('--chans needs one channel per file')
        series = []
        for c, f in zip(chans, a.files):
            iq, tail, t_ok = trim(load(f, a.type, a.otw), a, f)
            ok = ok and t_ok
            print('%s: %d samples (%s)%s%s' % (f, iq.shape[0], a.type,
                                               ', channel %d' % c if len(a.files) > 1 or a.chans else '',
                                               ', %d zero-pad samples ignored' % tail if tail else ''))
            series.append((c, f, iq))

    if a.otw in ('sc8', 'sc12'):
        sys.exit(main_quantized(a, series, ok))
    ref = None  # (channel, I[0]) of the first series
    lens = set()
    for c, label, iq in series:
        n = iq.shape[0]
        lens.add(n)
        if a.nsamps and n != a.nsamps:
            print('  FAIL: %s: %d samples, expected %d' % (label, n, a.nsamps))
            ok = False
        if n == 0:
            print('  FAIL: %s: no samples' % label)
            ok = False
            continue
        c_ok, i0 = check_counter(iq, a.tps, label)
        ok = ok and c_ok
        if a.t0 is not None and i0 != ((a.t0 + c) & 0xFFFF):
            print('  FAIL: %s: first sample I=%d, expected (t0 + %d) & 0xFFFF = %d' % (
                label, i0, c, (a.t0 + c) & 0xFFFF))
            ok = False
        if ref is None:
            ref = (c, i0)
        elif (i0 - ref[1]) & 0xFFFF != (c - ref[0]) & 0xFFFF:
            # all channels of a sample share its tick: I differs by the channel offset
            print('  FAIL: %s: I[0]=%d but channel %d has I[0]=%d: offset %d, expected %d '
                  '(channel order / alignment)' % (label, i0, ref[0], ref[1],
                                                   (i0 - ref[1]) & 0xFFFF, (c - ref[0]) & 0xFFFF))
            ok = False
    if len(series) > 1 and len(lens) > 1:
        print('  FAIL: channels have different lengths %s' % sorted(lens))
        ok = False
    if ref is None:
        sys.exit(1)
    print('  first sample t & 0xFFFF = %d%s; %s' % (
        (ref[1] - ref[0]) & 0xFFFF, ' (%d channels aligned)' % len(series) if len(series) > 1 else '',
        'BIT-EXACT' if ok else 'MISMATCH'))
    sys.exit(0 if ok else 1)


def main_quantized(a, series, ok):
    """sc8/sc12: every series a quantised counter; --t0 and the channel
    offsets checked against the sets of start ticks that fit."""
    ref = None  # (channel, candidate set) of the first series
    lens = set()
    for c, label, iq in series:
        n = iq.shape[0]
        lens.add(n)
        if a.nsamps and n != a.nsamps:
            print('  FAIL: %s: %d samples, expected %d' % (label, n, a.nsamps))
            ok = False
        if n == 0:
            print('  FAIL: %s: no samples' % label)
            ok = False
            continue
        c_ok, cands = check_quantized(iq, a.tps, label, a.otw)
        ok = ok and c_ok
        if not c_ok:
            continue
        if a.t0 is not None and ((a.t0 + c) & 0xFFFF) not in cands:
            print('  FAIL: %s: first sample does not fit t0 + %d (fits %s)' % (label, c, cands[:8]))
            ok = False
        base = {(x - c) & 0xFFFF for x in cands}
        if ref is None:
            ref = (c, base)
        elif not (base & ref[1]):
            print('  FAIL: %s: channel %d start ticks %s do not line up with channel %d (%s) '
                  '(channel order / alignment)' % (label, c, sorted(base)[:8], ref[0], sorted(ref[1])[:8]))
            ok = False
        else:
            ref = (ref[0], base & ref[1])
    if len(series) > 1 and len(lens) > 1:
        print('  FAIL: channels have different lengths %s' % sorted(lens))
        ok = False
    if ref is None:
        return 1
    print('  first sample t & 0xFFFF in %s (otw %s)%s; %s' % (
        sorted(ref[1])[:8], a.otw, ' (%d channels aligned)' % len(series) if len(series) > 1 else '',
        'BIT-EXACT' if ok else 'MISMATCH'))
    return 0 if ok else 1


if __name__ == '__main__':
    main()
