#!/usr/bin/env python3
"""zcu216_bf.py -- steer the ZCU216 TX or RX beamformer (Protocol §11)
from Python with the stock UHD API: multi_usrp.set_user_register() writes, the
property tree (/mboards/0/tx_beamformer/*, /mboards/0/rx_beamformer/*) reads
back.

Needs an N >= 2 build (device arg channels=N); the RX beamformer also needs a
bitstream that carries it (info rbf=1). Run as root through the wrapper (the
module opens the DPDK port at make()):

    zcu216-uhd python3 tools/zcu216_bf.py --args type=zcu216,addr=<board-ip>,channels=4 \\
        --carrier 28e9 --spacing 5.35e-3 --angle 30 --enable
    zcu216-uhd python3 tools/zcu216_bf.py --args ... --weights "32767,0 0,32767 -32768,0 0,-32768" --enable
    zcu216-uhd python3 tools/zcu216_bf.py --args ... --disable          # bit-exact bypass
    zcu216-uhd python3 tools/zcu216_bf.py --rx --args ... --angle 30 --shift 2 --enable

User register map (section 11), TX at base 0, RX at base 64:
  base+0 enable (0/1); base+1 steering angle in millidegrees (int32, two's
  complement) -- computes and loads the weights; base+2 carrier frequency in
  kHz; base+3 element spacing in nanometres; RX only: 68 SHIFT (0..15, the
  beam is (sum_c x_c w[c]) >> (15 + SHIFT), reset log2(N)); base+16+c raw
  weight of channel c (int16 real | int16 imag << 16), staged; base+15 LOAD
  the staged raw weights.
UHD 4.6's multi_usrp has no get_user_register: read back through the tree
(here), or in C++ through get_user_settings_iface(chan)->peek32(addr).

TX enabled: TX channel 0 is fanned out to all N DACs, DAC c getting
ch0 x w[c]; the other channels of the TX stream are ignored.
RX enabled: RX channel 0 carries the beam
    y = sat16((sum_c x_c * w[c] + 2^(14+SHIFT)) >> (15+SHIFT))
and channels 1..N-1 their raw samples.

--check verifies every read-back and exits non-zero on
a mismatch. --capture NSAMPS (with --rx) receives all N channels and checks RX
channel 0 against that formula bit for bit, with the weights and SHIFT read
back from the tree, on real ADC data: x_0 is not observable while the beam is
on, so w[0] must be 0 (e.g. --weights "0,0 32767,0 ..."); the beam is then a
function of the delivered channels 1..N-1 only. (The section-5 test pattern
is of no use here: the FPGA inserts it after the beamformer.)
"""
import argparse
import math
import sys

import numpy as np
import uhd

R_ENABLE, R_ANGLE, R_CARRIER, R_SPACING, R_SHIFT, R_LOAD, R_W0 = 0, 1, 2, 3, 4, 15, 16
RX_BASE = 64


def beam(x, w, shift):
    """x: (N, n) int16 complex as (I, Q) int64 arrays; w: [(re, im)] -> (I, Q) of the beam."""
    xi, xq = x
    wr = np.array([r for r, _ in w], dtype=np.int64)[:, None]
    wi = np.array([i for _, i in w], dtype=np.int64)[:, None]
    acc_re = (xi * wr - xq * wi).sum(axis=0)
    acc_im = (xi * wi + xq * wr).sum(axis=0)
    s = 15 + shift
    return (np.clip((acc_re + (1 << (s - 1))) >> s, -32768, 32767),
            np.clip((acc_im + (1 << (s - 1))) >> s, -32768, 32767))


def capture(usrp, n, nsamps):
    """nsamps of every channel, one num_done burst -> (I, Q) int64 arrays (N, nsamps)."""
    sa = uhd.usrp.StreamArgs('fc32', 'sc16')
    sa.channels = list(range(n))
    st = usrp.get_rx_stream(sa)
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = nsamps
    cmd.stream_now = True
    st.issue_stream_cmd(cmd)
    md = uhd.types.RXMetadata()
    buf = np.zeros((n, st.get_max_num_samps()), dtype=np.complex64)
    got, total, timeout = [], 0, 3.0
    while total < nsamps:
        k = st.recv(buf, md, timeout)
        timeout = 0.5
        if md.error_code != uhd.types.RXMetadataErrorCode.none:
            sys.exit('recv error after %d samples: %s' % (total, md.strerror()))
        if k == 0:
            break
        got.append(buf[:, :k].copy())
        total += k
    y = np.concatenate(got, axis=1)[:, :nsamps] if got else np.zeros((n, 0), np.complex64)
    # UHD sc16 -> fc32 is x / 32767: exact back to int16
    return (np.round(y.real * 32767).astype(np.int64), np.round(y.imag * 32767).astype(np.int64))


def s16(v):
    return ((np.asarray(v, dtype=np.int64) + 32768) & 0xFFFF) - 32768


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--args', required=True, help='device args, with channels=N (N >= 2)')
    ap.add_argument('--rx', action='store_true', help='the RX beamformer (default: TX)')
    ap.add_argument('--carrier', type=float, help='carrier frequency, Hz (ULA geometry)')
    ap.add_argument('--spacing', type=float, help='element spacing, m (ULA geometry)')
    ap.add_argument('--angle', type=float, help='steering angle, degrees')
    ap.add_argument('--weights', help='raw Q1.15 weights "re,im re,im ..." (one pair per channel)')
    ap.add_argument('--shift', type=int, help='RX: extra right shift 0..15 (reset log2(N))')
    g = ap.add_mutually_exclusive_group()
    g.add_argument('--enable', action='store_true', help='beamform (TX: ch0 x w[c] -> DAC c; RX: beam on ch0)')
    g.add_argument('--disable', action='store_true', help='bit-exact bypass')
    ap.add_argument('--check', action='store_true', help='verify the read-back (tests)')
    ap.add_argument('--capture', type=int, metavar='NSAMPS',
                    help='RX: receive NSAMPS of every channel and check channel 0 against the beam formula')
    a = ap.parse_args()
    if a.shift is not None and not a.rx:
        sys.exit('--shift is an RX beamformer setting (--rx)')
    if a.capture and not a.rx:
        sys.exit('--capture checks the RX beamformer (--rx)')

    usrp = uhd.usrp.MultiUSRP(a.args)
    tree = usrp.get_tree()
    n = usrp.get_tx_num_channels()
    base = RX_BASE if a.rx else 0
    what = 'RX' if a.rx else 'TX'
    bf = '/mboards/0/rx_beamformer' if a.rx else '/mboards/0/tx_beamformer'
    if not a.rx and not tree.exists(bf + '/enable'):
        bf = '/mboards/0/beamformer'                       # a module from before the RX beamformer
    if not tree.exists(bf + '/enable'):
        print('this %d-channel build has no %s beamformer (section 11: N >= 2%s; device arg channels=N)' % (
            n, what, ', and a bitstream that carries it (info rbf=1)' if a.rx else ''))
        try:
            usrp.set_user_register(base + R_ENABLE, 1)
        except Exception as e:  # the module says why
            print('set_user_register:', e)
        return 2

    def reg(r, v):
        usrp.set_user_register(base + r, v & 0xFFFFFFFF)

    if a.carrier is not None:
        reg(R_CARRIER, int(round(a.carrier / 1e3)))
    if a.spacing is not None:
        reg(R_SPACING, int(round(a.spacing * 1e9)))
    if a.angle is not None:
        reg(R_ANGLE, int(round(a.angle * 1000)))
    if a.weights:
        w = [tuple(int(x) for x in p.split(',')) for p in a.weights.split()]
        if len(w) != n:
            sys.exit('need %d weights (one re,im pair per channel), got %d' % (n, len(w)))
        for c, (re, im) in enumerate(w):
            reg(R_W0 + c, (re & 0xFFFF) | ((im & 0xFFFF) << 16))
        reg(R_LOAD, 1)
    if a.shift is not None:
        reg(R_SHIFT, a.shift)
    if a.enable or a.disable:
        reg(R_ENABLE, 1 if a.enable else 0)

    enable = tree.access_bool(bf + '/enable').get()
    angle = tree.access_double(bf + '/angle_deg').get()
    carrier = tree.access_double(bf + '/carrier_freq').get()
    spacing = tree.access_double(bf + '/element_spacing').get()
    wq = [int(x) for x in tree.access_str(bf + '/weights_str').get().split(',')]
    weights = list(zip(wq[0::2], wq[1::2]))
    shift = tree.access_int(bf + '/shift').get() if a.rx else None
    print('%s beamformer (N = %d): %s, angle %s, carrier %.6g Hz, spacing %.6g m%s' % (
        what, n, 'ENABLED' if enable else 'bypass', 'none (raw weights)' if math.isnan(angle) else '%g deg' % angle,
        carrier, spacing, ', shift %d' % shift if a.rx else ''))
    print('weights (Q1.15):', ' '.join('%d,%d' % w for w in weights))
    fails = 0

    def want(ok, msg):
        nonlocal fails
        print('%s  %s' % ('ok  ' if ok else 'FAIL', msg))
        fails += not ok

    if a.check:
        if a.enable or a.disable:
            want(enable == bool(a.enable), 'enable reads %s' % enable)
        if a.carrier is not None:
            want(abs(carrier - round(a.carrier / 1e3) * 1e3) < 1, 'carrier_freq reads %.9g' % carrier)
        if a.spacing is not None:
            want(abs(spacing - round(a.spacing * 1e9) * 1e-9) < 1e-15, 'element_spacing reads %.9g' % spacing)
        if a.weights:
            want(math.isnan(angle), 'raw weights: angle reads none')
            want(weights == [tuple(int(x) for x in p.split(',')) for p in a.weights.split()],
                 'weights read back as written')
        elif a.angle is not None:
            want(abs(angle - round(a.angle * 1000) / 1000.0) < 1e-9, 'angle_deg reads %g' % angle)
        if a.rx:
            want(shift == (a.shift if a.shift is not None else shift) and 0 <= shift <= 15,
                 'shift reads %d' % shift)

    if a.capture:
        xi, xq = capture(usrp, n, a.capture)
        m = xi.shape[1]
        want(m == a.capture, 'captured %d of %d samples x %d channels' % (m, a.capture, n))
        if m and enable:
            if weights[0] != (0, 0):
                print('x_0 is not observable while the beam is on, so the check needs w[0] = 0 (got %d,%d)'
                      % weights[0])
                return 1
            x = (xi.copy(), xq.copy())
            x[0][0, :], x[1][0, :] = 0, 0
            yi, yq = beam(x, weights, shift)
            bad = np.flatnonzero((yi != xi[0]) | (yq != xq[0]))
            want(bad.size == 0, 'channel 0 == sat16((sum_c x_c w[c] + 2^(14+%d)) >> (15+%d)) for all %d '
                 'samples%s' % (shift, shift, m, '' if bad.size == 0 else
                                ' -- %d differ, first at %d: got %d,%d want %d,%d' % (
                                    bad.size, bad[0], xi[0, bad[0]], xq[0, bad[0]], yi[bad[0]], yq[bad[0]])))
            sat = int(np.count_nonzero((np.abs(yi) >= 32767) | (np.abs(yq) >= 32767)))
            print('      (%d of %d beam samples at the int16 limits)' % (sat, m))
    if a.check or a.capture:
        print('RESULT:', 'PASS' if fails == 0 else 'FAIL')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
