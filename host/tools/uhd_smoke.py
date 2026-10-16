#!/usr/bin/env python3
"""uhd_smoke.py -- Python-API smoke test of the zcu216 UHD module.

Needs the section-5 test pattern (device arg pattern=1) for the RX checks. Runs
as root (DPDK) against the board (../benchmark/uhd_examples_hw.sh does):

    tools/zcu216-uhd python3 tools/uhd_smoke.py --args type=zcu216,addr=<board-ip>,pattern=1

  1. MultiUSRP.recv_num_samps()               -> bit-exact counter, contiguous
  2. timed num_done at a time that is NOT on a 4-sample beat, with a count that
     is NOT a multiple of 16                  -> exactly N samples, time_spec ==
     requested time, first sample == pattern(t0), EOB on the last one
  3. MultiUSRP.send_waveform()                -> all samples accepted, burst ACK
With a multi-channel build (device arg channels=N, Protocol §9) every step
runs on all N channels at once, and channel c must read I = t + c for the sample
at tick t: timing, channel order and alignment in one check.
Exit code 0 = all pass.
"""
import argparse
import sys
import time

import numpy as np
import uhd


def pattern_ok(x, tps=1):
    """x: complex64 from fc32 (scaled 1/32767). True if I counts by tps and Q = ~I.
    Returns (ok, I[0])."""
    i = np.round(x.real * 32767).astype(np.int64).astype(np.int16).view(np.uint16)
    q = np.round(x.imag * 32767).astype(np.int64).astype(np.int16).view(np.uint16)
    k = np.arange(x.size, dtype=np.int64)
    exp = ((int(i[0]) + k * tps) & 0xFFFF).astype(np.uint16)
    return bool(np.all(i == exp) and np.all(q == (~i & 0xFFFF))), int(i[0])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--args', required=True,
                    help='device args, e.g. type=zcu216,addr=<board-ip>,pattern=1')
    ap.add_argument('--rate', type=float, default=4e6)
    ap.add_argument('--freq', type=float, default=1e9)
    ap.add_argument('--no-tx', action='store_true')
    a = ap.parse_args()
    fails = 0

    usrp = uhd.usrp.MultiUSRP(a.args)
    print(usrp.get_pp_string())
    tick = usrp.get_master_clock_rate()
    N = usrp.get_rx_num_channels()
    chans = list(range(N))

    def all_ok(x, tps):
        """every channel a counter, and channel c offset by c from channel 0"""
        res = [pattern_ok(x[c], tps) for c in chans]
        i0 = res[0][1]
        return all(r[0] for r in res) and all((r[1] - i0) & 0xFFFF == c for c, r in zip(chans, res)), i0

    # 1. recv_num_samps
    x = usrp.recv_num_samps(200000 // N, a.freq, a.rate, chans, 0)
    tps = int(round(tick / usrp.get_rx_rate(0)))
    ok, i0 = all_ok(x, tps)
    print('recv_num_samps: %d x %d samples, rate %.6g, first I %d: %s' % (
        x.shape[0], x.shape[1], usrp.get_rx_rate(0), i0, 'PASS' if ok else 'FAIL'))
    fails += not ok

    # 2. timed, unaligned, odd-sized burst
    usrp.set_rx_rate(a.rate, 0)
    tps = int(round(tick / usrp.get_rx_rate(0)))
    sa = uhd.usrp.StreamArgs('fc32', 'sc16')
    sa.channels = chans
    st = usrp.get_rx_stream(sa)
    usrp.set_time_now(uhd.types.TimeSpec(0.0))
    n_req = 12345
    t_req = uhd.types.TimeSpec(0.5 + 3.0 / tick)  # 3 ticks past a beat boundary
    # the first sample at or after t_req: samples sit on a grid of tps ticks
    t0_ticks = (t_req.to_ticks(tick) + tps - 1) // tps * tps
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = n_req
    cmd.stream_now = False
    cmd.time_spec = t_req
    st.issue_stream_cmd(cmd)
    md = uhd.types.RXMetadata()
    buf = np.zeros((N, st.get_max_num_samps()), dtype=np.complex64)
    got, first_ts, sob, eob, chunks = [], None, False, False, 0
    timeout = 1.5
    while not eob:
        n = st.recv(buf, md, timeout)
        timeout = 0.2
        if md.error_code != uhd.types.RXMetadataErrorCode.none:
            print('  recv error:', md.strerror())
            break
        if first_ts is None:
            first_ts, sob = md.time_spec.to_ticks(tick), md.start_of_burst
        got.append(buf[:, :n].copy())
        chunks += 1
        eob = md.end_of_burst
    y = np.concatenate(got, axis=1) if got else np.zeros((N, 0), np.complex64)
    ok_p, i0 = all_ok(y, tps) if y.shape[1] else (False, -1)
    ok = (y.shape[1] == n_req and first_ts == t0_ticks and sob and eob and ok_p and i0 == (t0_ticks & 0xFFFF))
    print('timed num_done: asked %d x %d @ tick %d; got %d in %d recv(), time_spec tick %s, SOB %s, EOB %s, '
          'first I %d (want %d), pattern %s: %s' % (
              N, n_req, t_req.to_ticks(tick), y.shape[1], chunks, first_ts, sob, eob, i0, t0_ticks & 0xFFFF,
              'ok' if ok_p else 'BAD', 'PASS' if ok else 'FAIL'))
    fails += not ok
    del st

    # 3. send_waveform
    if not a.no_tx:
        wf = (0.5 * np.exp(2j * np.pi * np.arange(1000) / 100)).astype(np.complex64)
        dur = 0.5
        t = time.monotonic()
        sent = usrp.send_waveform(np.tile(wf, (N, 1)), dur, a.freq, a.rate, chans, 0)
        el = time.monotonic() - t
        want = int(np.floor(dur * a.rate))
        ok = sent == want
        print('send_waveform: %d of %d samples accepted in %.2f s: %s' % (sent, want, el, 'PASS' if ok else 'FAIL'))
        fails += not ok

    print('RESULT:', 'PASS' if fails == 0 else 'FAIL (%d)' % fails)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
