#!/usr/bin/env python3
"""make_flowgraphs.py [--out DIR] -- write one GNU Radio flowgraph (.grc) per
multi-channel family and channel count: zcu216_tones_<family>_<N>ch.grc.

The builds are benchmark/oracle_builds.txt (N >= 2), the max-rate build of
each family and N. Every flowgraph is the same burst-mode tone test at that
build's rate and wire format:

  * TX: every PERIOD seconds one timed burst (device time now + LEAD), the
    same tone on every channel at samp_rate / 64 (zcu216_tone_bursts.py,
    embedded) -> UHD: USRP Sink, all N channels;
  * RX: UHD: USRP Source, all N channels, one timed capture of CAP_LEN samples
    per channel inside every burst (num_samps_and_done, issued by the snippet)
    -> Qt time sink and Qt frequency sink, 4 channels per pair (a tab per group
    of 4 above 4 channels).

The burst is 131072 slots (a quarter of the host's TX credit) so that it is
wholly buffered before it plays; the capture sits in its middle.

Burst mode because GNU Radio cannot consume these rates continuously: the
captures are contiguous, full-rate and time-aligned across channels, but only
4 x CAP_LEN samples per period reach the flowgraph.

With GNU Radio importable (the PC), every file is loaded, validated and saved
back through GRC, which fills in every block's defaults; elsewhere the files
are written as generated.
"""
import argparse
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
BUILDS = os.path.join(HERE, "..", "benchmark", "oracle_builds.txt")
FREQ, AMP, TONE_STEP = 950e6, 0.25, 1.0 / 64
CAP_LEN, LEAD, PERIOD = 16384, 0.3, 0.5     # CAP_LEN: at most half a burst
# GRC's Run button: the ZCU216 module needs root (DPDK), so the flowgraph runs
# through zcu216-uhd under pkexec (a graphical password prompt), keeping the display
RUN_CMD = ("/bin/bash -c 'exec pkexec env DISPLAY=\"$DISPLAY\" XAUTHORITY=\"$XAUTHORITY\" "
           "/usr/local/bin/zcu216-uhd \"$0\" -u \"$1\"' {python} {filename}")


def builds():
    """The max-rate build of each (family, N >= 2): the first such row of
    oracle_builds.txt (the rest of the normal family's rate ladder is reached
    by lowering samp_rate in the flowgraph -- the daemon serves the highest
    build at or below it)."""
    seen = set()
    for line in open(BUILDS):
        f = line.split()
        if not f or f[0].startswith("#") or int(f[1]) < 2 or (f[0], f[1]) in seen:
            continue
        seen.add((f[0], f[1]))
        fam, n, rate, bit, fmts = f[0], int(f[1]), float(f[2]), f[3], f[4].split(",")
        yield fam, n, rate, bit, ("sc16" if "sc16" in fmts else fmts[0])


def blk(name, bid, params, xy):
    return {"name": name, "id": bid, "parameters": params,
            "states": {"bus_sink": False, "bus_source": False, "bus_structure": None,
                       "coordinate": list(xy), "rotation": 0, "state": "enabled"}}


def var(name, value, xy):
    return blk(name, "variable", {"comment": "", "value": value}, xy)


def flowgraph(fam, n, rate, bit, otw):
    fid = f"zcu216_tones_{fam}_{n}ch"
    # 131072 slots per burst: a quarter of the host's TX credit (the 2 MiB URAM,
    # 524032 slots; the FPGA's 2 MiB block-RAM chain sits behind it), so the
    # whole burst is in the FPGA before it plays -- GNU Radio cannot refill a
    # burst in real time once playout starts
    burst_len = 2 ** 17 // n
    cap_len = min(CAP_LEN, burst_len // 2)
    groups = (n + 3) // 4
    B = [blk("options", "options", {
        "author": "", "catch_exceptions": "True", "category": "[GRC Hier Blocks]",
        "description": f"ZCU216 {fam} {n}ch ({bit}): timed tone bursts, captured on every channel",
        "generate_options": "qt_gui", "id": fid, "output_language": "python",
        "placement": "(0,0)", "run": "True", "run_command": RUN_CMD,
        "run_options": "prompt", "sizing_mode": "fixed",
        "title": f"ZCU216 {fam} {n}ch tones ({rate / 1e6:g} MS/s, otw {otw})"}, (8, 8))]
    B += [blk("addr", "parameter", {"label": "board address (empty: discover)", "short_id": "",
                                    "type": "str", "value": "", "hide": "none"}, (200, 8)),
          blk("freq", "parameter", {"label": "RF centre (Hz)", "short_id": "f",
                                    "type": "eng_float", "value": f"{FREQ:g}", "hide": "none"}, (360, 8))]
    args = f'"type=zcu216,channels={n}"' + (f' + ",otw={otw}"' if otw != "sc16" else "") + \
           ' + (",addr=" + addr if addr else "")'
    for i, (k, v) in enumerate([("samp_rate", f"{rate:g}"), ("nchan", str(n)), ("dev_args", args),
                                ("burst_len", str(burst_len)), ("cap_len", str(cap_len)),
                                ("cap_offset", "burst_len // 4"), ("lead", str(LEAD)),
                                ("period", str(PERIOD)), ("tx_gain", "0"), ("rx_gain", "0")]):
        B.append(var(k, v, (8 + 168 * (i % 6), 96 + 72 * (i // 6))))
    # GRC sizes an embedded block's ports from its __init__ defaults: nchan's default is N
    src = open(os.path.join(HERE, "zcu216_tone_bursts.py")).read().replace(
        "def __init__(self, nchan=4,", f"def __init__(self, nchan={n},")
    B.append(blk("tones", "epy_block", {
        "_source_code": src, "nchan": "nchan", "burst_len": "burst_len", "amp": str(AMP),
        "tone_step": f"{TONE_STEP!r}", "affinity": "", "alias": "", "comment": "",
        "maxoutbuf": "0", "minoutbuf": "0"}, (8, 280)))
    common = {"affinity": "", "alias": "", "comment": "", "dev_addr": "dev_args", "dev_args": '""',
              "clock_rate": "0e0", "clock_source0": "", "time_source0": "", "sd_spec0": "",
              "maxoutbuf": "0", "minoutbuf": "0", "nchan": "nchan", "num_mboards": "1",
              "otw": otw, "samp_rate": "samp_rate", "start_time": "-1.0", "stream_args": "",
              "stream_chans": "[]", "sync": "none", "type": "fc32", "show_lo_controls": "False"}
    sink = dict(common, len_tag_name='""')
    source = dict(common)
    for k in range(n):
        for p, d in ((sink, "tx_gain"), (source, "rx_gain")):
            p.update({f"center_freq{k}": "freq", f"gain{k}": d, f"norm_gain{k}": "False",
                      f"ant{k}": '""', f"bw{k}": "0", f"lo_source{k}": "internal",
                      f"lo_export{k}": "False"})
    B.append(blk("usrp_sink", "uhd_usrp_sink", sink, (320, 280)))
    B.append(blk("usrp_source", "uhd_usrp_source", source, (8, 480)))
    snippet = f"""import os, threading, time as _time
import pmt
from gnuradio import uhd as _uhd
from PyQt5 import Qt as _Qt
# burst mode: stop the continuous stream gr-uhd starts with the flowgraph, then
# every period one TX burst at device time t0 and one RX capture inside it
_src = self.usrp_source
_src.issue_stream_cmd(_uhd.stream_cmd_t(_uhd.STREAM_MODE_STOP_CONTINUOUS))
self.bursts_sent = 0
def _bursts(tb=self):
    _time.sleep(2.0)   # let the flowgraph and the GUI settle: the first bursts were late
    while True:
        t0 = _src.get_time_now().get_real_secs() + tb.lead
        tb.tones._post(pmt.intern("fire"), pmt.from_double(t0))
        cmd = _uhd.stream_cmd_t(_uhd.STREAM_MODE_NUM_SAMPS_AND_DONE)
        cmd.num_samps = tb.cap_len
        cmd.stream_now = False
        cmd.time_spec = _uhd.time_spec(t0 + tb.cap_offset / tb.samp_rate)
        _src.issue_stream_cmd(cmd)
        tb.bursts_sent += 1
        _time.sleep(tb.period)
threading.Thread(target=_bursts, daemon=True).start()
# ZCU216_GR_SNAPSHOT=<png>: save the window after ZCU216_GR_SNAPSHOT_S (default 6) s and quit
_snap = os.environ.get("ZCU216_GR_SNAPSHOT")
if _snap:
    self.resize(1600, 600)
    def _shot(tb=self):
        tb.grab().save(_snap)
        print(f"snapshot {{_snap}} after {{tb.bursts_sent}} bursts", flush=True)
        tb.close()
    _Qt.QTimer.singleShot(int(1000 * float(os.environ.get("ZCU216_GR_SNAPSHOT_S", "6"))), _shot)
"""
    B.append(blk("bursts", "snippet", {"section": "main_after_start", "priority": "0",
                                       "code": snippet, "alias": "", "comment": ""}, (480, 8)))
    if groups > 1:
        tw = {"num_tabs": str(groups), "gui_hint": "0,0,1,1", "alias": "", "comment": ""}
        for g in range(groups):
            tw[f"label{g}"] = f"RX {4 * g}-{min(n, 4 * g + 4) - 1}"
        B.append(blk("tabs", "qtgui_tab_widget", tw, (480, 480)))
    C = [["tones", str(k), "usrp_sink", str(k)] for k in range(n)]
    for g in range(groups):
        m = min(4, n - 4 * g)
        where = (lambda c: f"tabs@{g}: 0,{c},1,1") if groups > 1 else (lambda c: f"0,{c},1,1")
        t = {"type": "complex", "name": f'"RX {4 * g}-{4 * g + m - 1}: time"', "size": "512",
             "srate": "samp_rate", "nconnections": str(m), "autoscale": "True", "ymin": "-1",
             "ymax": "1", "update_time": "0.10", "grid": "True", "legend": "True",
             "tr_mode": "qtgui.TRIG_MODE_FREE", "gui_hint": where(0), "ctrlpanel": "False",
             "axislabels": "True", "entags": "False", "ylabel": "Amplitude", "yunit": '""',
             "alias": "", "comment": "", "affinity": ""}
        f = {"type": "complex", "name": f'"RX {4 * g}-{4 * g + m - 1}: spectrum"', "fftsize": "4096",
             "fc": "freq", "bw": "samp_rate", "nconnections": str(m), "ymin": "-130", "ymax": "0",
             "average": "1.0", "update_time": "0.10", "grid": "True", "legend": "True",
             "wintype": "window.WIN_BLACKMAN_hARRIS", "tr_mode": "qtgui.TRIG_MODE_FREE",
             "gui_hint": where(1), "ctrlpanel": "False", "axislabels": "True", "autoscale": "False",
             "units": "dB", "label": "Relative Gain", "freqhalf": "True", "showports": "False",
             "alias": "", "comment": "", "affinity": ""}
        for i in range(m):
            # a complex time sink draws I and Q of each input: curves 2i+1, 2i+2
            t[f"label{2 * i + 1}"] = f'"RX {4 * g + i} I"'
            t[f"label{2 * i + 2}"] = f'"RX {4 * g + i} Q"'
            f[f"label{i + 1}"] = f'"RX {4 * g + i}"'
            C.append(["usrp_source", str(4 * g + i), f"time{g}", str(i)])
            C.append(["usrp_source", str(4 * g + i), f"spec{g}", str(i)])
        B.append(blk(f"time{g}", "qtgui_time_sink_x", t, (320, 480 + 120 * g)))
        B.append(blk(f"spec{g}", "qtgui_freq_sink_x", f, (320, 540 + 120 * g)))
    opts = {k: v for k, v in B[0].items() if k in ("parameters", "states")}
    return fid, {"options": opts, "blocks": B[1:], "connections": C, "metadata": {"file_format": 1}}


def normalise(path):
    """Load, validate and save through GRC (fills every block's defaults)."""
    from gnuradio import gr
    from gnuradio.grc.core.platform import Platform
    p = Platform(version=gr.version(), version_parts=(gr.major_version(), gr.api_version(),
                 gr.minor_version()), prefs=gr.prefs())
    p.build_library()
    fg = p.make_flow_graph(path)
    fg.validate()
    if not fg.is_valid():
        raise SystemExit(f"{path}: " + "; ".join(str(e) for e in fg.iter_error_messages()))
    p.save_flow_graph(path, fg)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default=os.path.join(HERE, "grc"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    try:
        import gnuradio.grc  # noqa: F401
        grc = True
    except ImportError:
        grc = False
    for b in builds():
        fid, fg = flowgraph(*b)
        path = os.path.join(a.out, fid + ".grc")
        with open(path, "w") as fh:
            yaml.safe_dump(fg, fh, sort_keys=False, width=1000)
        if grc:
            normalise(path)
        print(f"{path}  ({b[3]}, {b[2] / 1e6:g} MS/s, otw {b[4]})")


if __name__ == "__main__":
    sys.exit(main())
