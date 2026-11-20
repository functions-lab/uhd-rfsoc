"""GNU Radio source block: gap-free GPU spectrogram of an N-channel uhd-rfsoc stream.

`rfsoc_spectrogram` has N outputs (one per channel) of vectors of `bins` floats.
Every item is one spectrum line: dB relative to a full-scale complex tone, low
to high frequency across centre +- rate/2. Feed the outputs to
rfsoc_waterfall_view (rfsoc_waterfall_view.py) for scrolling waterfalls. The
samples never pass through GNU Radio: librfsoc_waterfall.so
reads them from UHD's rx_streamer and does window / cuFFT / power / average or
peak-hold on the GPU (see rfsoc_waterfall.h).
"""
import ctypes
import os

import numpy as np
from gnuradio import gr

_HERE = os.path.dirname(os.path.abspath(__file__))


class _Cfg(ctypes.Structure):
    _fields_ = [
        ("dev_args", ctypes.c_char_p), ("otw", ctypes.c_char_p),
        ("nch", ctypes.c_int), ("rate", ctypes.c_double),
        ("center_freq", ctypes.c_double), ("gain", ctypes.c_double),
        ("nfft", ctypes.c_int), ("overlap_pct", ctypes.c_int),
        ("window", ctypes.c_int), ("bins", ctypes.c_int),
        ("detector", ctypes.c_int), ("line_rate", ctypes.c_double),
        ("sim", ctypes.c_int), ("sim_tone_hz", ctypes.c_double),
        ("sim_tone_dbfs", ctypes.c_double),
    ]


class Stats(ctypes.Structure):
    _fields_ = [
        ("samples_captured", ctypes.c_uint64), ("samples_processed", ctypes.c_uint64),
        ("batches_dropped", ctypes.c_uint64), ("overflows", ctypes.c_uint64),
        ("lines", ctypes.c_uint64), ("lines_dropped", ctypes.c_uint64),
        ("gpu_ms_per_batch", ctypes.c_double), ("batch_ms", ctypes.c_double),
        ("rate", ctypes.c_double), ("center_freq", ctypes.c_double),
    ]


def _load():
    cands = [os.environ.get("RFSOC_WATERFALL_LIB", ""),
             os.path.join(_HERE, "build", "librfsoc_waterfall.so"),
             os.path.join(_HERE, "librfsoc_waterfall.so")]
    for p in cands:
        if p and os.path.exists(p):
            lib = ctypes.CDLL(p)
            break
    else:
        raise RuntimeError("librfsoc_waterfall.so not found; build it: "
                           "cmake -S %s -B %s/build && cmake --build %s/build"
                           % (_HERE, _HERE, _HERE))
    lib.wf_create.restype = ctypes.c_void_p
    lib.wf_create.argtypes = [ctypes.POINTER(_Cfg), ctypes.c_char_p, ctypes.c_int]
    lib.wf_start.argtypes = [ctypes.c_void_p]
    lib.wf_read_line.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    lib.wf_set_freq.argtypes = [ctypes.c_void_p, ctypes.c_double]
    lib.wf_set_gain.argtypes = [ctypes.c_void_p, ctypes.c_double]
    lib.wf_set_detector.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.wf_set_line_rate.argtypes = [ctypes.c_void_p, ctypes.c_double]
    lib.wf_get_stats.argtypes = [ctypes.c_void_p, ctypes.POINTER(Stats)]
    lib.wf_error.restype = ctypes.c_char_p
    lib.wf_error.argtypes = [ctypes.c_void_p]
    lib.wf_destroy.argtypes = [ctypes.c_void_p]
    return lib


WINDOWS = {"hann": 0, "blackmanharris": 1}

# Automatic line rate (line_rate <= 0): a line averages this many FFT frames, so a
# narrower bandwidth gives a slower, longer-history waterfall; kept to what a
# display can follow
FRAMES_PER_LINE = 8192
LINE_RATE_MIN, LINE_RATE_MAX = 5.0, 50.0


def auto_line_rate(rate, nfft, overlap):
    hop = nfft * (100 - overlap) // 100
    return min(LINE_RATE_MAX, max(LINE_RATE_MIN, rate / (FRAMES_PER_LINE * hop)))


class Spectrogram:
    """ctypes wrapper of the C API (usable without GNU Radio)."""

    def __init__(self, dev_args="", nch=1, rate=125e6, freq=950e6, gain=0.0,
                 nfft=4096, overlap=50, window="blackmanharris", bins=1024,
                 detector=0, line_rate=0.0, otw="sc16", sim=0,
                 sim_tone=10e6, sim_tone_dbfs=-20.0):
        self.lib = _load()
        # line_rate 0: automatic (auto_line_rate)
        self.nch, self.bins = int(nch), int(bins)
        cfg = _Cfg(dev_args.encode(), otw.encode(), self.nch, float(rate), float(freq),
                   float(gain), int(nfft), int(overlap),
                   WINDOWS[window] if isinstance(window, str) else int(window),
                   self.bins, int(detector), float(line_rate), int(sim),
                   float(sim_tone), float(sim_tone_dbfs))
        err = ctypes.create_string_buffer(512)
        self.h = self.lib.wf_create(ctypes.byref(cfg), err, len(err))
        if not self.h:
            raise RuntimeError(err.value.decode())
        self._buf = np.zeros(self.nch * self.bins, dtype=np.float32)
        self.started = False
        self.line_rate = float(line_rate)
        if self.line_rate <= 0:  # automatic, from the actual rate the board serves
            self.line_rate = auto_line_rate(self.stats().rate, int(nfft), int(overlap))
            self.set_line_rate(self.line_rate)

    def start(self):
        if not self.started:
            if self.lib.wf_start(self.h) != 0:
                raise RuntimeError(self.error())
            self.started = True

    def read_line(self, timeout_ms=100):
        """(nch, bins) float32 array, or None on timeout."""
        r = self.lib.wf_read_line(self.h, self._buf.ctypes.data, int(timeout_ms))
        if r < 0:
            raise RuntimeError(self.error())
        return self._buf.reshape(self.nch, self.bins) if r == 1 else None

    def stats(self):
        s = Stats()
        self.lib.wf_get_stats(self.h, ctypes.byref(s))
        return s

    def error(self):
        return (self.lib.wf_error(self.h) or b"").decode()

    def set_freq(self, hz):
        return self.lib.wf_set_freq(self.h, float(hz))

    def set_gain(self, db):
        return self.lib.wf_set_gain(self.h, float(db))

    def set_detector(self, d):
        self.lib.wf_set_detector(self.h, int(d))

    def set_line_rate(self, r):
        self.lib.wf_set_line_rate(self.h, float(r))

    def close(self):
        if self.h:
            self.lib.wf_destroy(self.h)
            self.h = None


class rfsoc_spectrogram(gr.sync_block):
    """N-output source of spectrum lines; see the module docstring."""

    def __init__(self, dev_args="", nch=1, rate=125e6, freq=950e6, gain=0.0,
                 nfft=4096, overlap=50, window="blackmanharris", bins=1024,
                 detector=0, line_rate=0.0, otw="sc16", sim=0, sim_tone=10e6):
        nch, bins = int(nch), int(bins)
        gr.sync_block.__init__(self, name="rfsoc_spectrogram", in_sig=None,
                               out_sig=[(np.float32, bins)] * nch)
        self.nch, self.bins = nch, bins
        self.sg = Spectrogram(dev_args, nch, rate, freq, gain, nfft, overlap, window,
                              bins, detector, line_rate, otw, sim, sim_tone)
        st = self.sg.stats()
        self.rate, self.center_freq = st.rate, st.center_freq

    def get_rate(self):
        """Per-channel sample rate the board serves (= the bandwidth), Hz."""
        return self.rate

    def get_line_rate(self):
        """Spectrum lines per second (chosen from the bandwidth when it was 0)."""
        return self.sg.line_rate

    def start(self):
        self.sg.start()
        return True

    def stop(self):
        self.sg.close()
        return True

    def work(self, input_items, output_items):
        line = self.sg.read_line(100)
        if line is None:
            return 0
        for c in range(self.nch):
            output_items[c][0][:] = line[c]
        return 1

    # run-time controls (QT GUI Range / Chooser callbacks)
    def set_center_freq(self, hz):
        if self.sg.h:
            self.sg.set_freq(hz)
            self.center_freq = self.sg.stats().center_freq

    def set_gain(self, db):
        if self.sg.h:
            self.sg.set_gain(db)

    def set_detector(self, d):
        if self.sg.h:
            self.sg.set_detector(d)

    def set_line_rate(self, r):
        if self.sg.h and r > 0:
            self.sg.set_line_rate(r)
            self.sg.line_rate = float(r)
