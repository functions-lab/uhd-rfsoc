#!/usr/bin/env python3
"""Write grc/waterfall_<N>ch.grc, N = 1, 2, 4, 8, 16.

One flowgraph per channel count, all the same shape: the `RFSoC Spectrogram
(CUDA)` source block and the `RFSoC Waterfall View` sink (rfsoc_spectrogram/):
a scrolling waterfall per channel, newest line on top, tabs of 4 channels above
4. Controls: RF centre, RX gain, detector, colour range. The line rate and the
time span of the y axis follow from the bandwidth, so there is no control for
them; the axes (rfsoc_waterfall_view.py) have 1-2-5 ticks that follow the plot
size, offset from the centre along the bottom, the RF frequency along the top,
time on y.

    host/gnuradio/gen_waterfall_grc.py          # rewrites the five files

The .grc files are the sources users open in GNU Radio Companion; this script
only keeps the five consistent.
"""
import os

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))

# per channel count: fastest sc16 rate per channel on a ZCU216 (served from
# below on any other board), display bins and history rows
PLAN = {
    1: dict(rate=1.25e9, bins=1024, rows=256),
    2: dict(rate=1.25e9, bins=1024, rows=256),
    4: dict(rate=625e6, bins=1024, rows=256),
    8: dict(rate=312.5e6, bins=512, rows=200),
    16: dict(rate=156.25e6, bins=512, rows=200),
}

STATES = dict(bus_sink=False, bus_source=False, bus_structure=None, rotation=0, state="enabled")


def block(name, id_, params, xy):
    return dict(name=name, id=id_, parameters={k: str(v) for k, v in params.items()},
                states=dict(STATES, coordinate=list(xy)))


def ui_snippet(n):
    return f'''import os
from PyQt5 import Qt as _Qt
# bandwidth and line rate come from the source, the RF centre follows it: the axes get their ticks from them
self.wv.attach(self.wf)
self.wv.set_centre(self.wf.center_freq)
# colour range of every waterfall: two spin boxes, dB relative to a full-scale tone
_box = _Qt.QWidget()
_lay = _Qt.QHBoxLayout(_box)
_lay.setContentsMargins(0, 0, 0, 0)
_spins = []
for _txt, _v in (("floor (dB)", -120.0), ("ceiling (dB)", -50.0)):
    _lay.addWidget(_Qt.QLabel(_txt))
    _s = _Qt.QDoubleSpinBox()
    _s.setRange(-200.0, 20.0)
    _s.setSingleStep(5.0)
    _s.setValue(_v)
    _lay.addWidget(_s)
    _spins.append(_s)
def _range(_=None, tb=self):
    tb.wv.set_range(_spins[0].value(), _spins[1].value())
for _s in _spins:
    _s.valueChanged.connect(_range)
_range()
self.top_grid_layout.addWidget(_box, 2, 1, 1, 3)
# status line: what the GPU pipeline is doing
_lbl = _Qt.QLabel()
self.top_grid_layout.addWidget(_lbl, 3, 0, 1, 4)
import time
_seen = [0, 0, 0.0]  # overflows, dropped batches, time of the last loss
def _status(tb=self):
    s = tb.wf.sg.stats()
    tb.wv.set_centre(s.center_freq)  # the top axis follows a retune
    if s.overflows > _seen[0] or s.batches_dropped > _seen[1]:
        _seen[2] = time.time()
    _seen[0], _seen[1] = s.overflows, s.batches_dropped
    lost = time.time() - _seen[2] < 10.0
    _lbl.setText("centre %.3f MHz | %.3f MS/s x {n} ch | %.1f lines/s, %.1f s of history | GPU %.0f%% of "
                 "real time | UHD overflows %d | dropped batches %d%s"
                 % (s.center_freq / 1e6, s.rate / 1e6, tb.wf.get_line_rate(), tb.rows / tb.wf.get_line_rate(),
                    100 * s.gpu_ms_per_batch / max(s.batch_ms, 1e-9), s.overflows, s.batches_dropped,
                    "  (samples lost in the last 10 s)" if lost else ""))
_t = _Qt.QTimer(self)
_t.timeout.connect(_status)
_t.start(500)
# the waterfall takes the room the controls leave
for _r in range(4):
    self.top_grid_layout.setRowStretch(_r, 0)
self.top_grid_layout.setRowStretch(4, 1)
# UHD_RFSOC_GR_SNAPSHOT=<png>: save the window after UHD_RFSOC_GR_SNAPSHOT_S (default 8) s and quit
_snap = os.environ.get("UHD_RFSOC_GR_SNAPSHOT")
if not _snap:
    # fit the window to the screen: after show() and after GNU Radio has restored the
    # geometry it saved on the last run, which would otherwise win
    def _fit(tb=self):
        _g = _Qt.QApplication.primaryScreen().availableGeometry()
        tb.showNormal()
        tb.setGeometry(_g.x() + _g.width() // 20, _g.y() + _g.height() // 20,
                       _g.width() * 9 // 10, _g.height() * 9 // 10)
    _Qt.QTimer.singleShot(300, _fit)
    _Qt.QTimer.singleShot(1200, _fit)
if _snap:
    self.resize(1500, 1000)
    def _shot(tb=self):
        _status()
        tb.grab().save(_snap)
        _st = tb.wf.sg.stats()
        print("snapshot %s: %d lines, UHD overflows %d, dropped batches %d, GPU %.0f%%"
              % (_snap, _st.lines, _st.overflows, _st.batches_dropped,
                 100 * _st.gpu_ms_per_batch / max(_st.batch_ms, 1e-9)), flush=True)
        tb.close()
    _Qt.QTimer.singleShot(int(1000 * float(os.environ.get("UHD_RFSOC_GR_SNAPSHOT_S", "8"))), _shot)
'''


def flowgraph(n):
    p = PLAN[n]
    blocks = []

    def put(b):
        blocks.append(b)

    def param(name, label, type_, value, xy, short=""):
        put(block(name, "parameter", dict(alias="", comment="", hide="none", label=label,
                  short_id=short, type=type_, value=value), xy))

    param("addr", "board address (empty: discover)", "str", "", (200, 8))
    param("samp_rate", "per-channel sample rate (S/s; the daemon serves the highest at or below it)",
          "eng_float", repr(p["rate"]), (8, 96), "r")
    param("freq", "RF centre (Hz)", "eng_float", "9.5e+08", (360, 8), "f")
    param("nfft", "FFT size", "intx", "4096", (8, 184), "n")
    param("overlap", "frame overlap in % (0, 50, 75)", "intx", "50", (200, 184))
    param("bins", "display bins per line (divides the FFT size)", "intx", str(p["bins"]), (392, 184), "b")
    param("otw", "wire format (sc16, sc12, sc8; the narrow ones reach higher rates)", "str", "sc16", (584, 184))
    param("extra", "extra UHD device args, e.g. app_cpus=1-4 (CPUs for the GUI and capture threads)", "str",
          "", (968, 184))
    param("sim", "1: synthetic source instead of the board (no hardware)", "intx", "0", (776, 184))
    put(block("nchan", "variable", dict(comment="", value=str(n)), (176, 96)))
    put(block("rows", "variable", dict(comment="", value=str(p["rows"])), (344, 96)))
    put(block("dev_args", "variable", dict(comment="",
              value='"type=rfsoc" + (",addr=" + addr if addr else "") + (",otw=" + otw if otw != "sc16" else "")'
                    ' + ("," + extra if extra else "")'), (512, 96)))

    # controls
    put(block("rf_freq", "variable_qtgui_range", dict(comment="", gui_hint="0, 0, 1, 4",
              label="RF centre (Hz)", min_len="200", orient="QtCore.Qt.Horizontal", rangeType="float",
              start="0", step="1e6", stop="2.5e9", value="freq", widget="counter_slider"), (8, 260)))
    put(block("rx_gain", "variable_qtgui_range", dict(comment="", gui_hint="1, 0, 1, 4",
              label="RX gain (dB)", min_len="100", orient="QtCore.Qt.Horizontal", rangeType="float",
              start="-30", step="0.5", stop="0", value="0", widget="counter_slider"), (8, 340)))
    put(block("detector", "variable_qtgui_chooser", dict(comment="", gui_hint="2, 0, 1, 1",
              label="detector", num_opts="0", option0="0", option1="1", option2="2", option3="3",
              option4="4", label0="", label1="", label2="", label3="", label4="", options="[0, 1]",
              labels="['Average', 'Peak hold']", orient="QtCore.Qt.Horizontal", type="int", value="0",
              widget="combo_box"), (8, 420)))

    put(block("wf", "rfsoc_spectrogram", dict(
        affinity="", alias="", comment="GPU spectrogram: samples go from UHD to the GPU, not through GNU Radio",
        dev_args="dev_args", nch="nchan", rate="samp_rate", freq="rf_freq", gain="rx_gain",
        nfft="nfft", overlap="overlap", window="blackmanharris", bins="bins", detector="detector",
        line_rate="0", otw="otw", sim="sim", sim_tone="10e6", maxoutbuf="0", minoutbuf="0"),
        (360, 300)))
    put(block("wv", "rfsoc_waterfall_view", dict(
        affinity="", alias="", comment="", nch="nchan", bins="bins", rows="rows", floor="-120",
        ceil="-50", gui_hint="4, 0, 1, 4", maxoutbuf="0", minoutbuf="0"), (700, 300)))
    put(block("ui", "snippet", dict(alias="", code=ui_snippet(n), comment="", priority="0",
              section="main_after_init"), (700, 8)))

    opts = dict(
        parameters=dict(
            author="", catch_exceptions="True", category="[GRC Hier Blocks]", cmake_opt="", comment="",
            copyright="", description=f"{n}-channel gap-free GPU waterfall (CUDA), any board with "
                                      f"{n}-channel builds", gen_cmake="On", gen_linking="dynamic",
            generate_options="qt_gui", hier_block_src_path=".:", id=f"waterfall_{n}ch", max_nouts="0",
            output_language="python", placement="(0,0)", qt_qss_theme="", realtime_scheduling="",
            run="True",
            run_command="/bin/bash -c 'exec pkexec env DISPLAY=\"$DISPLAY\" XAUTHORITY=\"$XAUTHORITY\" "
                        "PYTHONPATH=\"$RFSOC_SPECTROGRAM_DIR\" /usr/local/bin/uhd-rfsoc \"$0\" -u \"$1\"' "
                        "{python} {filename}",
            run_options="prompt", sizing_mode="fixed", thread_safe_setters="",
            title=f"{n}ch GPU waterfall (CUDA cuFFT, gap-free)", window_size="(1500,1000)"),
        states=dict(bus_sink=False, bus_source=False, bus_structure=None, coordinate=[8, 8],
                    rotation=0, state="enabled"))
    opts["parameters"] = {k: str(v) for k, v in opts["parameters"].items()}
    conns = [["wf", str(c), "wv", str(c)] for c in range(n)]
    return dict(options=opts, blocks=blocks, connections=conns, metadata=dict(file_format=1))


class _Dumper(yaml.SafeDumper):
    pass


def _str(d, s):
    return d.represent_scalar("tag:yaml.org,2002:str", s, style="|" if "\n" in s else None)


_Dumper.add_representer(str, _str)

if __name__ == "__main__":
    for n in PLAN:
        path = os.path.join(HERE, "grc", f"waterfall_{n}ch.grc")
        with open(path, "w") as f:
            yaml.dump(flowgraph(n), f, Dumper=_Dumper, sort_keys=False, default_flow_style=False,
                      width=100)
        print(path)
