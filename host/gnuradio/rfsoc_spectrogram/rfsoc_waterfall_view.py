"""GNU Radio sink block: scrolling waterfalls of the spectrum lines of rfsoc_spectrogram.

`rfsoc_waterfall_view` takes the N vector outputs of `rfsoc_spectrogram` (one
spectrum line of `bins` dB values per channel and item) and shows one waterfall
per channel in a single Qt widget (tabs of 4 channels above 4).

Axes (the same in rfsoc_waterfall_web.py's page):
  x, bottom  offset from the RF centre, -BW/2 .. +BW/2     (BW = the actual rate)
  x, top     the RF frequency itself (centre + offset); follows a retune
  y          time, 0 at the top (the newest line) down to -T   (T = rows / line rate)
Ticks are multiples of a 1-2-5 step, as many as fit the plot (about one per
70 px on x, one per 40 px on y: they follow the window size), with minor ticks
and a faint grid; 0 and the two edges are always labelled, and a tick that
would crowd an edge label is dropped. The units scale themselves to the span:
Hz / kHz / MHz / GHz for x, us / ms / s / min / h for y (the axis titles follow).

BW and T follow from the source block (attach()): the sample rate it got from
the board, and the line rate it chose from that bandwidth.
"""
import math

import numpy as np
import pyqtgraph as pg
from gnuradio import gr
from PyQt5 import Qt, QtCore

pg.setConfigOptions(imageAxisOrder="row-major", antialias=False)


X_MIN_PX, Y_MIN_PX = 70.0, 40.0  # least pixels between two labels


def nice_step(span, n):
    """The smallest 1-2-5 step (x 10^k) that gives at most n steps over the span."""
    raw = span / max(n, 1.0)
    mag = 10.0 ** math.floor(math.log10(raw))
    for m in (1.0, 2.0, 5.0, 10.0):
        if m * mag >= raw * (1 - 1e-9):
            return m * mag


def make_ticks(lo, hi, px, min_px, zero=False):
    """Ticks of an axis lo..hi drawn over px pixels, one per min_px at most.

    -> (major, minor, step): major = [(value, is_edge)], the two edges and the
    multiples of the step between them (none closer than 0.55 min_px to an edge:
    its label would crowd the edge's; `zero` keeps 0 when it is inside); minor = the
    subdivisions."""
    step = nice_step(hi - lo, px / min_px)
    near = 0.55 * min_px / px * (hi - lo)  # 0.55 min_px, in axis units
    k0, k1 = math.ceil(lo / step - 1e-9), math.floor(hi / step + 1e-9)
    inner = [k * step for k in range(k0, k1 + 1) if lo + near <= k * step <= hi - near]
    if zero and lo < 0 < hi and not any(abs(v) < step * 1e-6 for v in inner):
        inner = sorted(inner + [0.0])
    major = [(lo, True)] + [(v, False) for v in inner] + [(hi, True)]
    mant = step / 10.0 ** math.floor(math.log10(step) + 1e-9)
    mstep = step / (4 if abs(mant - 2.0) < 1e-6 else 5)
    m0, m1 = math.ceil(lo / mstep - 1e-9), math.floor(hi / mstep + 1e-9)
    minor = [k * mstep for k in range(m0, m1 + 1)
             if lo < k * mstep < hi and all(abs(k * mstep - m) > mstep * 1e-3 for m, _ in major)]
    return major, minor, step


def _decimals(step):
    return max(0, int(math.ceil(-math.log10(step) - 1e-9)))


def tick_label(v, step, edge, signed=False, sig=4):
    """A tick's text: the step's decimals, an edge with `sig` significant digits; 0 is "0"."""
    if abs(v) < step * 1e-6:
        return "0"
    txt = ("%.*g" % (sig, v)) if edge else ("%.*f" % (_decimals(step), v))
    return "+" + txt if signed and v > 0 else txt


# (smallest span that uses the unit, size of the unit, name)
_X_UNITS = [(1e9, 1e9, "GHz"), (1e6, 1e6, "MHz"), (1e3, 1e3, "kHz"), (0.0, 1.0, "Hz")]
_Y_UNITS = [(7200.0, 3600.0, "h"), (120.0, 60.0, "min"), (1.0, 1.0, "s"), (1e-3, 1e-3, "ms"),
            (0.0, 1e-6, "us")]


def auto_unit(span, table):
    """(size, name) of the unit that suits a span (in Hz, or in s)."""
    for lo, size, name in table:
        if span >= lo:
            return size, name
    return table[-1][1], table[-1][2]


class _View(Qt.QWidget):
    lines = QtCore.pyqtSignal(object)  # (nch, bins) float32, one line per channel

    def __init__(self, nch, bins, rows, floor, ceil):
        super().__init__()
        self.geo = None     # axis geometry, set by set_axes()
        self.centre = None  # RF centre in Hz, known once the source says so
        self.nch, self.bins, self.rows = nch, bins, rows
        self.floor, self.ceil = floor, ceil
        self.buf = [np.full((rows, bins), floor, dtype=np.float32) for _ in range(nch)]
        self.imgs, self.plots, self.bars, self.holders, self.grids = [], [], [], [], []
        self.cmap = pg.colormap.get("inferno")
        lay = Qt.QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        if nch > 4:
            self.tabs = Qt.QTabWidget()
            lay.addWidget(self.tabs)
            groups = [range(i, min(i + 4, nch)) for i in range(0, nch, 4)]
            for g in groups:
                w = pg.GraphicsLayoutWidget()
                self.tabs.addTab(w, "ch %d-%d" % (g[0], g[-1]))
                for k, c in enumerate(g):
                    self._plot(w, c, k // 2, k % 2)
            self.tabs.currentChanged.connect(lambda _=None: self._refresh())
        else:
            self.tabs = None
            w = pg.GraphicsLayoutWidget()
            lay.addWidget(w)
            ncol = 1 if nch == 1 else 2
            for c in range(nch):
                self._plot(w, c, c // ncol, c % ncol)
        self.lines.connect(self._on_lines)
        self.set_axes(100e6, 1.0)

    def _plot(self, w, c, row, col):
        p = w.addPlot(row=row, col=2 * col, title="ch %d" % c)
        p.setMouseEnabled(False, False)
        p.hideButtons()
        p.setMenuEnabled(False)
        p.invertY(True)  # row 0 = newest, at the top
        img = pg.ImageItem()
        img.setColorMap(self.cmap)
        img.setImage(self.buf[c], autoLevels=False)  # setRect needs an image to scale
        img.setLevels((self.floor, self.ceil))
        p.addItem(img)
        p.getViewBox().setDefaultPadding(0.0)
        for side in ("bottom", "left", "top"):
            p.getAxis(side).setStyle(hideOverlappingLabels=70)  # edge labels may overhang the axis
        i = len(self.plots)
        p.getViewBox().sigResized.connect(lambda *_: self._retick(i))  # ticks follow the plot size
        bar = pg.ColorBarItem(values=(self.floor, self.ceil), colorMap=self.cmap, interactive=False,
                              label="dB")
        bar.setImageItem(img)
        w.addItem(bar, row=row, col=2 * col + 1)
        self.imgs.append(img)
        self.plots.append(p)
        self.bars.append(bar)
        self.holders.append(w)
        self.grids.append([])

    # -- axes ---------------------------------------------------------------
    def set_axes(self, bw_hz, span_s):
        """Range and units from the bandwidth and the history; the ticks from the plot size."""
        xs, xn = auto_unit(bw_hz, _X_UNITS)
        ys, yn = auto_unit(span_s, _Y_UNITS)
        self.geo = dict(xs=xs, xn=xn, h=bw_hz / xs / 2.0, ys=ys, yn=yn, t=span_s / ys)
        h, t = self.geo["h"], self.geo["t"]
        for i, (p, img) in enumerate(zip(self.plots, self.imgs)):
            img.setRect(QtCore.QRectF(-h, 0.0, 2 * h, t))
            p.setXRange(-h, h, padding=0)
            p.setYRange(0.0, t, padding=0)
            p.setLabel("bottom", "offset from centre (%s)" % xn)
            p.setLabel("left", "time (%s)" % yn)
            self._retick(i)

    def set_centre(self, hz):
        """The RF centre in Hz: the top axis shows the absolute frequency around it."""
        if hz != self.centre:
            self.centre = hz
            for i in range(len(self.plots)):
                self._retick(i)

    def _retick(self, i):
        g = self.geo
        if not g:
            return
        p = self.plots[i]
        vb = p.getViewBox()
        w, hgt = max(vb.width(), 120.0), max(vb.height(), 120.0)
        xmaj, xmin, xstep = make_ticks(-g["h"], g["h"], w, X_MIN_PX, zero=True)
        ymaj, ymin, ystep = make_ticks(0.0, g["t"], hgt, Y_MIN_PX)
        p.getAxis("bottom").setTicks([[(v, tick_label(v, xstep, e, True)) for v, e in xmaj],
                                      [(v, "") for v in xmin]])
        p.getAxis("left").setTicks([[(v, tick_label(-v, ystep, e)) for v, e in ymaj],
                                    [(v, "") for v in ymin]])
        # faint grid lines at the major ticks (showGrid would hide the edge labels)
        for ln in self.grids[i]:
            p.removeItem(ln)
        self.grids[i] = []
        pen = pg.mkPen((255, 255, 255, 38), width=1)
        for angle, ticks in ((90, xmaj), (0, ymaj)):
            for v, edge in ticks:
                if not edge:
                    ln = pg.InfiniteLine(pos=v, angle=angle, pen=pen, movable=False)
                    ln.setZValue(5)
                    p.addItem(ln, ignoreBounds=True)
                    self.grids[i].append(ln)
        if self.centre is None:
            p.showAxis("top", False)
            return
        fs, fn = auto_unit(abs(self.centre), _X_UNITS)  # the RF frequency in its own unit
        k = g["xs"] / fs
        astep = xstep * k
        p.showAxis("top", True)
        p.setLabel("top", "RF frequency (%s)" % fn)
        p.getAxis("top").setTicks([[(v, tick_label(self.centre / fs + v * k, astep, e, sig=7)) for v, e in xmaj],
                                   [(v, "") for v in xmin]])

    def set_range(self, lo, hi):
        self.floor, self.ceil = lo, hi
        for img, bar in zip(self.imgs, self.bars):
            img.setLevels((lo, hi))
            bar.setLevels((lo, hi))

    # -- data ---------------------------------------------------------------
    def _refresh(self):
        for c in range(self.nch):
            if self.holders[c].isVisible():
                self.imgs[c].setImage(self.buf[c], autoLevels=False)

    def _on_lines(self, lines):
        for c in range(self.nch):
            b = self.buf[c]
            b[1:] = b[:-1]
            b[0] = lines[c]
            if self.holders[c].isVisible():  # a hidden tab only keeps its history
                self.imgs[c].setImage(b, autoLevels=False)


class rfsoc_waterfall_view(gr.sync_block):
    """N-input sink (vectors of `bins` dB values): see the module docstring."""

    def __init__(self, nch=1, bins=1024, rows=256, floor=-120.0, ceil=-50.0):
        nch, bins = int(nch), int(bins)
        gr.sync_block.__init__(self, name="rfsoc_waterfall_view",
                               in_sig=[(np.float32, bins)] * nch, out_sig=None)
        self.nch, self.bins = nch, bins
        self._view = _View(nch, bins, int(rows), float(floor), float(ceil))

    def widget(self):
        return self._view

    def attach(self, source):
        """Take the bandwidth and the line rate from the rfsoc_spectrogram block."""
        self._view.set_axes(source.get_rate(), self._view.rows / source.get_line_rate())

    def set_range(self, lo, hi):
        self._view.set_range(float(lo), float(hi))

    def set_centre(self, hz):
        """RF centre in Hz, for the absolute frequency axis on top."""
        self._view.set_centre(float(hz))

    def work(self, input_items, output_items):
        n = len(input_items[0])
        for i in range(n):  # oldest first: each line scrolls the waterfall by one row
            self._view.lines.emit(np.stack([input_items[c][i] for c in range(self.nch)]))
        return n
