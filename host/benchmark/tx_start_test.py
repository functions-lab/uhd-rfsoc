#!/usr/bin/env python3
"""tx_start_test.py -- does a continuous TX stream underflow at its start?

Streams DUR seconds of zeros (fc32, NSAMPS per send()) at RATE per channel, as fast as send() takes them,
once with an untimed start and once with a timed start (now + LEAD), and counts
the async events (underflow, late, seq, burst ACK) of each. Run through the
wrapper (DPDK needs root and the module):

    uhd-rfsoc python3 benchmark/tx_start_test.py --args type=rfsoc,addr=<board-ip> --rate 1.25e9
"""
import argparse
import threading
import time

import numpy as np
import uhd

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--args", default="type=rfsoc")
ap.add_argument("--rate", type=float, default=1.25e9)
ap.add_argument("--dur", type=float, default=2.0)
ap.add_argument("--lead", type=float, default=0.05, help="timed start: seconds ahead of now")
ap.add_argument("--otw", default="sc16")
ap.add_argument("--reps", type=int, default=3)
ap.add_argument("--timed-first", action="store_true", help="timed run before untimed in each rep")
ap.add_argument("--fresh-streamer", action="store_true",
                help="a new TX streamer (new stream_setup_tx, FPGA flush) for every run")
ap.add_argument("--nsamps", type=int, default=1 << 17, help="samples per send()")
a = ap.parse_args()

usrp = uhd.usrp.MultiUSRP(a.args)
usrp.set_tx_rate(a.rate)
st_args = uhd.usrp.StreamArgs("fc32", a.otw)
st = usrp.get_tx_stream(st_args)
# many packets per send(): Python cannot make one call per 1.7 us packet
buf = np.zeros((1, a.nsamps), dtype=np.complex64)


def run(timed):
    global st
    if a.fresh_streamer:
        st = None
        st = usrp.get_tx_stream(st_args)
    ev = {"underflow": 0, "late": 0, "seq": 0, "ack": 0, "first_underflow_s": None}
    stop = threading.Event()
    t_start = [None]

    def async_loop():
        md = uhd.types.TXAsyncMetadata()
        while not (stop.is_set() and ev["ack"]):
            if not st.recv_async_msg(md, 0.1):
                if stop.is_set() and time.monotonic() - stop_t[0] > 1.0:
                    break
                continue
            c = md.event_code
            if c in (uhd.types.TXMetadataEventCode.underflow,
                     uhd.types.TXMetadataEventCode.underflow_in_packet):
                ev["underflow"] += 1
                if ev["first_underflow_s"] is None and t_start[0] is not None:
                    ev["first_underflow_s"] = time.monotonic() - t_start[0]
            elif c == uhd.types.TXMetadataEventCode.time_error:
                ev["late"] += 1
            elif c in (uhd.types.TXMetadataEventCode.seq_error,
                       uhd.types.TXMetadataEventCode.seq_error_in_packet):
                ev["seq"] += 1
            elif c == uhd.types.TXMetadataEventCode.burst_ack:
                ev["ack"] += 1

    stop_t = [0.0]
    th = threading.Thread(target=async_loop)
    th.start()
    md = uhd.types.TXMetadata()
    md.start_of_burst = True
    md.end_of_burst = False
    if timed:
        md.has_time_spec = True
        md.time_spec = usrp.get_time_now() + uhd.types.TimeSpec(a.lead)
    n = 0
    t_start[0] = time.monotonic()
    t_end = t_start[0] + a.dur + (a.lead if timed else 0)
    while time.monotonic() < t_end:
        n += st.send(buf, md)
        md.start_of_burst = False
        md.has_time_spec = False
    md.end_of_burst = True
    st.send(np.zeros((1, 0), dtype=np.complex64), md)
    stop_t[0] = time.monotonic()
    stop.set()
    th.join()
    return n, ev


for r in range(a.reps):
    for timed in ((True, False) if a.timed_first else (False, True)):
        n, ev = run(timed)
        print(f"{'timed  ' if timed else 'untimed'} rep {r}: {n / a.rate / a.dur * 100:6.1f} % of "
              f"{a.rate / 1e6:.0f} MS/s, underflow {ev['underflow']} (first at "
              f"{ev['first_underflow_s']}), late {ev['late']}, seq {ev['seq']}, ack {ev['ack']}",
              flush=True)
