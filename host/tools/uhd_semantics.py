#!/usr/bin/env python3
"""uhd_semantics.py -- USRP semantics of the uhd-rfsoc UHD module, through the
Python API (Protocol §3b-§3d, §4a).

Needs the section-5 test pattern (device arg pattern=1). Runs against the
board (../benchmark/uhd_examples_hw.sh does):

    tools/uhd-rfsoc python3 tools/uhd_semantics.py --args type=rfsoc,addr=<board-ip>,pattern=1

Checks (each prints PASS/FAIL; exit code = number of failures):
  late        a timed command in the past: ERROR_CODE_LATE_COMMAND, no samples;
              the next command streams normally
  broken      num_more without a continuation: the samples, then
              ERROR_CODE_BROKEN_CHAIN
  chain       num_more + num_more + num_done issued together: exactly the sum,
              one contiguous counter, one SOB, EOB at the end
  chain_late  a continuation issued while the chain streams: seamless, or
              (if it came too late) BROKEN_CHAIN and a new burst -- either way
              consistent with the samples
  fifo        two timed num_done and one "now": three bursts, in order, at
              their times
  tune        tune_request with an LO offset: rf / dsp split and signs like
              UHD's tune helper (RX dsp = rf - f, TX dsp = f - rf), centre =
              the request; dsp range +-rate/2; clamped to 0..fs/2
  lo          get_*_lo_names / lo_freq / lo_source / lo_freq_range
  antenna     aliases (RX2, TX/RX) select the one port, which is reported
  bandwidth   = rate (fs / factor), range
  sensors     lo_locked per channel, every mboard sensor readable
  fragments   a recv() buffer smaller than a packet: more_fragments
  timed       set_command_time + tune/gain on every channel: replied at once
              (the daemon's log shows them applied in ONE group at the time)
  pps         set_time_unknown_pps: no wait beyond multi_usrp's own, the time
              reads just past 0 afterwards (the emulated edge, like a USRP)
  N >= 2 only:
  subdev      "A:1 A:0": multi_usrp channel 0 streams converter channel 1
  async       one burst ACK per channel of the TX streamer (md.channel)
  streamers   a second RX streamer on other channels is refused clearly
"""
import argparse
import re
import sys
import time

import numpy as np
import uhd

T = uhd.types
ERR = T.RXMetadataErrorCode


def pat(x, tps):
    """(I as uint16, ok): I counts by tps and Q = ~I"""
    i = np.round(x.real * 32767).astype(np.int64).astype(np.int16).view(np.uint16)
    q = np.round(x.imag * 32767).astype(np.int64).astype(np.int16).view(np.uint16)
    k = np.arange(x.size, dtype=np.int64)
    ok = x.size == 0 or bool(np.all(i == ((int(i[0]) + k * tps) & 0xFFFF)) and np.all(q == (~i & 0xFFFF)))
    return i, ok


class Run:
    def __init__(self, a):
        self.a = a
        self.u = uhd.usrp.MultiUSRP(a.args)
        self.tick = self.u.get_master_clock_rate()
        self.N = self.u.get_rx_num_channels()
        self.fails = 0
        self.u.set_rx_rate(a.rate) if a.rate else None
        self.rate = self.u.get_rx_rate(0)
        self.tps = int(round(self.tick / self.rate))
        self.st = None

    def result(self, name, ok, why=''):
        print('%-4s %-10s %s' % ('PASS' if ok else 'FAIL', name, why), flush=True)
        self.fails += not ok

    def rx(self, chans=None):
        if self.st is None:
            sa = uhd.usrp.StreamArgs('fc32', 'sc16')
            sa.channels = chans if chans is not None else list(range(self.N))
            self.st = self.u.get_rx_stream(sa)
            self.buf = np.zeros((len(sa.channels), 200000), dtype=np.complex64)
        return self.st

    def cmd(self, mode, n=0, t=None):
        c = T.StreamCMD(mode)
        c.num_samps = n
        c.stream_now = t is None
        if t is not None:
            c.time_spec = T.TimeSpec(t)
        self.st.issue_stream_cmd(c)

    def recv(self, n, timeout=0.5):
        """recv() into self.buf[:, :n] -- through a C-contiguous array: a
        column slice of a 2-D array is not one, and the bindings take the
        channel rows as consecutive blocks of n samples"""
        b = self.buf[:, :n] if n == self.buf.shape[1] else np.zeros((self.buf.shape[0], n), np.complex64)
        md = T.RXMetadata()
        k = self.st.recv(b, md, timeout)
        if b is not self.buf:
            self.buf[:, :k] = b[:, :k]
        return k, md

    def burst(self, timeout=1.0):
        """samples until EOB / error / timeout -> (array, [md of each recv])"""
        out, mds = [], []
        while True:
            k, md = self.recv(self.buf.shape[1], timeout)
            mds.append(md)
            if k:
                out.append(self.buf[:, :k].copy())
            if md.error_code != ERR.none or md.end_of_burst:
                break
            timeout = 0.2
        y = np.concatenate(out, axis=1) if out else np.zeros((self.buf.shape[0], 0), np.complex64)
        return y, mds

    def drain(self):
        while True:
            k, md = self.recv(self.buf.shape[1], 0.1)
            if md.error_code == ERR.timeout:
                return

    def first_break(self, y):
        """(channel, index, I there, I before) of the first sample that does
        not continue its channel's counter, or None"""
        for c in range(y.shape[0]):
            i = np.round(y[c].real * 32767).astype(np.int64).astype(np.int16).view(np.uint16).astype(np.int64)
            d = np.nonzero(((i[1:] - i[:-1]) & 0xFFFF) != self.tps)[0]
            if d.size:
                return c, int(d[0] + 1), int(i[d[0] + 1]), int(i[d[0]])
        return None

    def chans_ok(self, y):
        """every channel a counter, channel c = channel 0 + c"""
        if y.shape[1] == 0:
            return False
        i0 = [pat(y[c], self.tps) for c in range(y.shape[0])]
        return all(o for _, o in i0) and all(((int(i[0]) - int(i0[0][0][0])) & 0xFFFF) == c
                                             for c, (i, _) in enumerate(i0))

    # ---------------------------------------------------------------- RX queue
    def t_late(self):
        self.rx()
        self.u.set_time_now(T.TimeSpec(200.0))
        self.cmd(T.StreamMode.num_done, self.st.get_max_num_samps(), 100.0)
        k, md = self.recv(self.st.get_max_num_samps(), 0.5)
        ok1 = md.error_code == ERR.late and k == 0
        self.cmd(T.StreamMode.num_done, 3000)
        y, mds = self.burst()
        ok2 = y.shape[1] == 3000 and mds[-1].end_of_burst and self.chans_ok(y)
        self.drain()
        self.result('late', ok1 and ok2, 'first recv: %s, %d samples; next burst %d samples' % (
            md.strerror(), k, y.shape[1]))

    def t_broken(self):
        self.rx()
        n = self.st.get_max_num_samps()
        self.cmd(T.StreamMode.num_more, n)
        k1, md1 = self.recv(n, 1.0)
        k2, md2 = self.recv(n, 0.5)
        ok = (k1 == n and md1.error_code == ERR.none and not md1.end_of_burst
              and md2.error_code == ERR.broken_chain and k2 == 0)
        self.cmd(T.StreamMode.num_done, 5000)
        y, mds = self.burst()
        ok = ok and y.shape[1] == 5000 and mds[0].start_of_burst and self.chans_ok(y)
        self.drain()
        self.result('broken', ok, '%d samples (%s), then %s; next num_done %d samples' % (
            k1, md1.strerror(), md2.strerror(), y.shape[1]))

    def t_chain(self):
        self.rx()
        for mode, n in ((T.StreamMode.num_more, 5000), (T.StreamMode.num_more, 7000),
                        (T.StreamMode.num_done, 3001)):
            self.cmd(mode, n)
        y, mds = self.burst()
        sobs = sum(m.start_of_burst for m in mds)
        errs = [m.strerror() for m in mds if m.error_code != ERR.none]
        ok = y.shape[1] == 15001 and sobs == 1 and mds[-1].end_of_burst and not errs and self.chans_ok(y)
        self.drain()
        self.result('chain', ok, '%d samples (want 15001), %d SOB, EOB %s, errors %s, contiguous %s' % (
            y.shape[1], sobs, mds[-1].end_of_burst, errs, self.chans_ok(y)))

    def t_chain_late(self):
        self.rx()
        self.cmd(T.StreamMode.num_more, 20000)
        k1, md1 = self.recv(10000, 1.0)
        first = self.buf[:, :k1].copy()
        self.cmd(T.StreamMode.num_done, 5000)          # continuation, while it streams
        y, mds = self.burst()
        errs = [m.error_code for m in mds]
        if ERR.broken_chain in errs:
            # broken: the rest of the chain, the error, then a new burst
            tail, _ = self.burst()
            ok = tail.shape[1] == 5000 and self.chans_ok(tail)
            how = 'broken chain, then a new burst of %d' % tail.shape[1]
        else:
            z = np.concatenate([first, y], axis=1)
            ok = z.shape[1] == 25000 and self.chans_ok(z) and mds[-1].end_of_burst
            how = 'seamless: %d contiguous samples (first recv %d; pattern %s %s, EOB %s, errors %s)' % (
                z.shape[1], k1, self.chans_ok(z), self.first_break(z), mds[-1].end_of_burst,
                [m.strerror() for m in mds if m.error_code != ERR.none])
        self.drain()
        self.result('chain_late', ok, how)

    def t_fifo(self):
        self.rx()
        now = self.u.get_time_now().get_real_secs()
        t1, t2 = now + 0.2, now + 0.3
        self.cmd(T.StreamMode.num_done, 4000, t1)
        self.cmd(T.StreamMode.num_done, 4000, t2)
        self.cmd(T.StreamMode.num_done, 4000)
        got = []
        for _ in range(3):
            y, mds = self.burst(1.0)
            got.append((y.shape[1], mds[0].time_spec.get_real_secs() if mds[0].has_time_spec else -1,
                        mds[0].error_code))
        okt = (abs(got[0][1] - t1) < 2 * self.tps / self.tick and abs(got[1][1] - t2) < 2 * self.tps / self.tick
               and got[2][1] > t2)
        ok = okt and all(n == 4000 and e == ERR.none for n, _t, e in got)
        self.drain()
        self.result('fifo', ok, 'bursts (samples, time) %s, asked %.6f %.6f then now' % (
            [(n, round(t, 6)) for n, t, _e in got], t1, t2))

    # ------------------------------------------------------------- tune etc.
    def t_tune(self):
        u, ok, why = self.u, True, []
        f, lo = 1.0e9, min(2.0e6, 0.25 * self.rate)       # within the DSP range +-rate/2
        r = u.set_rx_freq(T.TuneRequest(f, lo), 0)
        ok &= abs(r.actual_rf_freq - (f + lo)) < 1 and abs(r.actual_dsp_freq - lo) < 1
        ok &= abs(u.get_rx_freq(0) - f) < 1
        why.append('RX rf %.9g dsp %.9g -> %.9g' % (r.actual_rf_freq, r.actual_dsp_freq, u.get_rx_freq(0)))
        r = u.set_tx_freq(T.TuneRequest(f, lo), 0)
        ok &= abs(r.actual_rf_freq - (f + lo)) < 1 and abs(r.actual_dsp_freq + lo) < 1
        ok &= abs(u.get_tx_freq(0) - f) < 1
        why.append('TX rf %.9g dsp %.9g -> %.9g' % (r.actual_rf_freq, r.actual_dsp_freq, u.get_tx_freq(0)))
        rng = u.get_rx_dsp_freq_range(0) if hasattr(u, 'get_rx_dsp_freq_range') else None
        if rng is not None:
            ok &= abs(rng.start() + self.rate / 2) < 1 and abs(rng.stop() - self.rate / 2) < 1
        # manual DSP part beyond the CORDIC range: clipped to +-rate/2
        tr = T.TuneRequest(f)
        tr.dsp_freq_policy = T.TuneRequestPolicy.manual
        tr.dsp_freq = 10 * self.rate
        r = u.set_rx_freq(tr, 0)
        ok &= abs(r.actual_dsp_freq - self.rate / 2) < 1
        why.append('manual dsp clipped to %.9g' % r.actual_dsp_freq)
        fmax = u.get_fe_rx_freq_range(0).stop()
        u.set_rx_freq(T.TuneRequest(fmax + 0.3 * self.rate), 0)
        ok &= u.get_rx_freq(0) <= fmax + 1
        why.append('beyond fs/2 -> %.9g (max %.9g)' % (u.get_rx_freq(0), fmax))
        r = u.set_rx_freq(T.TuneRequest(f), 0)
        ok &= abs(r.actual_dsp_freq) < 1e-3 and abs(u.get_rx_freq(0) - f) < 1
        self.result('tune', ok, '; '.join(why))

    def t_lo(self):
        u, bad = self.u, []

        def chk(what, cond):
            if not cond:
                bad.append(what)
        names = list(u.get_rx_lo_names(0))
        chk('rx names', 'NCO' in names)
        chk('tx names', 'NCO' in list(u.get_tx_lo_names(0)))
        u.set_rx_freq(T.TuneRequest(1.1e9), 0)
        chk('rx lo freq', abs(u.get_rx_lo_freq('NCO', 0) - 1.1e9) < 1)
        chk('rx lo source', u.get_rx_lo_source('NCO', 0) == 'internal')
        chk('rx lo sources', list(u.get_rx_lo_sources('NCO', 0)) == ['internal'])
        chk('rx lo range', abs(u.get_rx_lo_freq_range('NCO', 0).stop() - u.get_fe_rx_freq_range(0).stop()) < 1)
        u.set_tx_freq(T.TuneRequest(1.05e9), 0)
        chk('tx lo freq', abs(u.get_tx_lo_freq('NCO', 0) - 1.05e9) < 1)
        chk('rx lo export', not u.get_rx_lo_export_enabled('NCO', 0))
        try:
            u.set_rx_lo_source('external', 'NCO', 0)
            bad.append('external source accepted')
        except Exception:
            pass
        self.result('lo', not bad, 'names %s, NCO %.9g Hz%s' % (
            names, u.get_rx_lo_freq('NCO', 0), '; wrong: ' + ', '.join(bad) if bad else ''))

    def t_antenna(self):
        u = self.u
        u.set_rx_antenna('RX2', 0)
        u.set_tx_antenna('TX/RX', 0)
        ok = u.get_rx_antenna(0) == 'RX' and u.get_tx_antenna(0) == 'TX'
        try:
            u.set_rx_antenna('BOGUS', 0)
            ok = False
        except Exception:
            pass
        self.result('antenna', ok, 'RX2 -> %s, TX/RX -> %s' % (u.get_rx_antenna(0), u.get_tx_antenna(0)))

    def t_bandwidth(self):
        u = self.u
        bw = u.get_rx_bandwidth(0)
        r = u.get_rx_bandwidth_range(0)
        ok = abs(bw - self.rate) < 1 and abs(r.stop() - bw) < 1 and abs(u.get_tx_bandwidth(0) - bw) < 1
        self.result('bandwidth', ok, '%.6g Hz at %.6g S/s' % (bw, self.rate))

    def t_sensors(self):
        u = self.u
        ok, why = True, []
        for c in range(self.N):
            ok &= u.get_rx_sensor('lo_locked', c).to_bool() and u.get_tx_sensor('lo_locked', c).to_bool()
        names = list(u.get_mboard_sensor_names(0))
        for n in names:
            why.append('%s=%s' % (n, u.get_mboard_sensor(n, 0).value))
        ok &= 'pps_present' in names
        self.result('sensors', ok, ', '.join(why))

    def t_fragments(self):
        self.rx()
        self.cmd(T.StreamMode.num_done, 3000)
        k1, md1 = self.recv(100, 1.0)
        k2, md2 = self.recv(100, 1.0)
        # (the Python RXMetadata has more_fragments, not fragment_offset)
        ok = k1 == 100 and k2 == 100 and md1.more_fragments and md2.more_fragments
        y, mds = self.burst()
        ok = ok and y.shape[1] == 2800 and not mds[-1].more_fragments
        self.drain()
        self.result('fragments', ok, 'recv 100 of a packet: more_fragments %s, %s; the rest %d, last %s' % (
            md1.more_fragments, md2.more_fragments, y.shape[1], mds[-1].more_fragments))

    def t_timed(self):
        # the daemon's log shows the grouping ("timed group: 2N op(s) applied
        # together at t=..."); here only the replies are checked
        u = self.u
        t = u.get_time_now() + T.TimeSpec(0.3)
        u.set_command_time(t)
        for c in range(self.N):
            u.set_rx_freq(T.TuneRequest(7e8 + 1e6 * c), c)
            u.set_rx_gain(-3.0, c)
        u.clear_command_time()
        ok = all(abs(u.get_rx_freq(c) - (7e8 + 1e6 * c)) < 1 for c in range(self.N))
        time.sleep(0.6)
        self.result('timed', ok, 'replied at once %s' % ok)

    def t_pps(self):
        u = self.u
        t0 = time.monotonic()
        u.set_time_unknown_pps(T.TimeSpec(0.0))
        el = time.monotonic() - t0
        now = u.get_time_now().get_real_secs()
        # like a USRP: the time became 0 at the edge 1 s after the one caught,
        # and multi_usrp slept just past it
        ok = el < 2.3 and 0.0 <= now < 0.25
        self.result('pps', ok, 'set_time_unknown_pps took %.2f s, time now %.3f s' % (el, now))

    # ------------------------------------------------------------- N >= 2
    def t_subdev(self):
        u = self.u
        self.st = None
        u.set_rx_subdev_spec(uhd.usrp.SubdevSpec('A:1 A:0'), 0)
        u.set_rx_freq(T.TuneRequest(1.15e9), 0)              # multi_usrp channel 0 = A:1
        sa = uhd.usrp.StreamArgs('fc32', 'sc16')
        sa.channels = [0, 1]
        st = u.get_rx_stream(sa)
        c = T.StreamCMD(T.StreamMode.num_done)
        c.num_samps, c.stream_now = 2000, True
        st.issue_stream_cmd(c)
        buf = np.zeros((2, 2000), dtype=np.complex64)
        md = T.RXMetadata()
        k = st.recv(buf, md, 1.0)
        del st
        i0, ok0 = pat(buf[0, :k], self.tps)
        i1, ok1 = pat(buf[1, :k], self.tps)
        ok = k == 2000 and ok0 and ok1 and ((int(i0[0]) - int(i1[0])) & 0xFFFF) == 1
        u.set_rx_subdev_spec(uhd.usrp.SubdevSpec(' '.join('A:%d' % c for c in range(self.N))), 0)
        ok &= abs(u.get_rx_freq(1) - 1.15e9) < 1
        self.result('subdev', ok, 'A:1 A:0: stream channel 0 carries converter channel %s; frontend 1 tuned to %.9g' % (
            'ch1' if ((int(i0[0]) - int(i1[0])) & 0xFFFF) == 1 else '?', u.get_rx_freq(1)))

    def t_async(self):
        u = self.u
        sa = uhd.usrp.StreamArgs('fc32', 'sc16')
        sa.channels = list(range(self.N))
        tx = u.get_tx_stream(sa)
        md = T.TXMetadata()
        md.start_of_burst = md.end_of_burst = True
        tx.send(np.zeros((self.N, 4000), dtype=np.complex64), md, 1.0)
        acks, amd = set(), T.TXAsyncMetadata()
        t_end = time.monotonic() + 2.0
        while time.monotonic() < t_end and len(acks) < self.N:
            if tx.recv_async_msg(amd, 0.2) and amd.event_code == T.TXMetadataEventCode.burst_ack:
                acks.add(amd.channel)
        del tx
        self.result('async', acks == set(range(self.N)), 'burst ACK on channels %s' % sorted(acks))

    def t_streamers(self):
        u = self.u
        self.st = None
        sa0, sa1 = uhd.usrp.StreamArgs('fc32', 'sc16'), uhd.usrp.StreamArgs('fc32', 'sc16')
        sa0.channels, sa1.channels = [0], [1]
        s0 = u.get_rx_stream(sa0)
        try:
            u.get_rx_stream(sa1)
            ok, why = False, 'second streamer accepted'
        except Exception as e:
            ok, why = 'still exists' in str(e), str(e).split('\n')[0][:160]
        del s0
        s1 = u.get_rx_stream(sa1)                            # fine once the first is gone
        del s1
        self.result('streamers', ok, why)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--args', required=True)
    ap.add_argument('--rate', type=float, default=0.0, help='per-channel rate (default: the device\'s)')
    ap.add_argument('--only', default='', help='comma list of checks')
    a = ap.parse_args()
    r = Run(a)
    tests = ['late', 'broken', 'chain', 'chain_late', 'fifo', 'tune', 'lo', 'antenna', 'bandwidth',
             'sensors', 'fragments', 'timed', 'pps']
    if r.N >= 2:
        tests += ['subdev', 'async', 'streamers']
    if a.only:
        tests = [t for t in tests if t in a.only.split(',')]
    print('%d channel(s), %.6g S/s, tick %.6g Hz' % (r.N, r.rate, r.tick), flush=True)
    for t in tests:
        try:
            getattr(r, 't_' + t)()
        except Exception as e:
            r.result(t, False, 'exception: %s' % e)
    print('RESULT:', 'PASS' if r.fails == 0 else 'FAIL (%d)' % r.fails)
    return r.fails


if __name__ == '__main__':
    sys.exit(main())
