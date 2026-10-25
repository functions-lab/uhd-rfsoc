#!/usr/bin/env python3
"""phase_check.py -- does the inter-channel phase survive a retune?
(Protocol §3d: the daemon resets the NCO phases of a direction
together after every tune, one update event per tile.)

Feed ONE CW tone to every RX channel under test (a splitter from a generator, or from DAC 0 with
--tx: this script then plays the tone itself). Per trial the script retunes
all RX channels away and back (optionally with a common set_command_time),
captures, and measures each channel's phase relative to channel 0:
angle(mean(x_c * conj(x_0))). With the phase reset working, that relative
phase is the SAME in every trial for channels of one ADC tile (spread ~ a
degree, the noise); without it, it is uniformly random. Channels of other
tiles (N = 8, 16) are expected to vary (no SYSREF-timed event).

    zcu216-uhd python3 benchmark/phase_check.py --args type=zcu216,addr=<board-ip>,channels=4 \\
        --freq 1e9 --tone-offset 1e6 [--tx] [--trials 20] [--timed]

Exit code 0 if every channel of tile 0 has a circular spread < --max-spread-deg.
"""
import argparse
import sys
import time

import numpy as np
import uhd

T = uhd.types


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--args', required=True)
    ap.add_argument('--freq', type=float, default=1e9, help='RX (and TX) NCO frequency')
    ap.add_argument('--tone-offset', type=float, default=1e6,
                    help='the tone sits this far above --freq (TX: DAC 0 plays it with --tx)')
    ap.add_argument('--away', type=float, default=37.3e6, help='retune away by this much each trial')
    ap.add_argument('--trials', type=int, default=20)
    ap.add_argument('--nsamps', type=int, default=20000)
    ap.add_argument('--timed', action='store_true', help='retune with a common set_command_time')
    ap.add_argument('--tx', action='store_true', help='play the tone on TX channel 0')
    ap.add_argument('--max-spread-deg', type=float, default=5.0)
    a = ap.parse_args()

    u = uhd.usrp.MultiUSRP(a.args)
    N = u.get_rx_num_channels()
    rate = u.get_rx_rate(0)
    chans = list(range(N))
    tx = None
    if a.tx:
        u.set_tx_freq(T.TuneRequest(a.freq), 0)
        sa = uhd.usrp.StreamArgs('fc32', 'sc16')
        sa.channels = [0]
        tx = u.get_tx_stream(sa)
        n = int(round(rate / a.tone_offset)) * 100
        tone = (0.5 * np.exp(2j * np.pi * a.tone_offset / rate * np.arange(n))).astype(np.complex64)
        txmd = T.TXMetadata()
        txmd.start_of_burst = True
        import threading
        stop = threading.Event()

        def play():
            m = txmd
            while not stop.is_set():
                tx.send(tone, m, 1.0)
                m = T.TXMetadata()
            m.end_of_burst = True
            tx.send(np.zeros(16, np.complex64), m, 1.0)
        th = threading.Thread(target=play, daemon=True)
        th.start()
    sa = uhd.usrp.StreamArgs('fc32', 'sc16')
    sa.channels = chans
    st = u.get_rx_stream(sa)
    buf = np.zeros((N, a.nsamps), np.complex64)
    rel = []
    for k in range(a.trials):
        for f in (a.freq + a.away, a.freq):
            if a.timed:
                u.set_command_time(u.get_time_now() + T.TimeSpec(0.05))
            for c in chans:
                u.set_rx_freq(T.TuneRequest(f), c)
            if a.timed:
                u.clear_command_time()
                time.sleep(0.1)
        time.sleep(0.02)
        cmd = T.StreamCMD(T.StreamMode.num_done)
        cmd.num_samps, cmd.stream_now = a.nsamps, True
        st.issue_stream_cmd(cmd)
        md = T.RXMetadata()
        got = st.recv(buf, md, 2.0)
        if got != a.nsamps or md.error_code != T.RXMetadataErrorCode.none:
            print('trial %d: recv %d samples, %s' % (k, got, md.strerror()))
            continue
        x0 = buf[0]
        p = [np.angle(np.mean(buf[c] * np.conj(x0)), deg=True) for c in chans]
        pw = [10 * np.log10(np.mean(np.abs(buf[c]) ** 2) + 1e-20) for c in chans]
        rel.append(p)
        print('trial %2d: phase vs ch0 %s deg, power %s dBFS' % (
            k, ' '.join('%7.1f' % v for v in p), ' '.join('%5.1f' % v for v in pw)))
    if tx is not None:
        stop.set()
        th.join(timeout=2)
    if not rel:
        print('no capture')
        return 2
    r = np.radians(np.array(rel))
    fails = 0
    print('channel  tile  circular spread (deg)')
    for c in chans[1:]:
        R = np.abs(np.mean(np.exp(1j * r[:, c])))
        spread = np.degrees(np.sqrt(max(0.0, -2 * np.log(max(R, 1e-12)))))
        same_tile = c // 4 == 0
        bad = same_tile and spread > a.max_spread_deg
        fails += bad
        print('%7d  %4d  %8.2f%s' % (c, c // 4, spread, '  <- NOT STABLE' if bad else
                                    ('  (other tile: not expected stable)' if not same_tile else '')))
    print('RESULT:', 'PASS' if not fails else 'FAIL')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
