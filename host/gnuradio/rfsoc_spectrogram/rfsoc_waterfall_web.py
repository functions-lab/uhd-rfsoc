#!/usr/bin/env python3
"""Web waterfall: the GPU spectrogram of rfsoc_spectrogram in a browser.

  uhd-rfsoc env PYTHONPATH=<this dir> python3 rfsoc_waterfall_web.py --nch 4 --addr <board-ip>
  (host/gnuradio/run_waterfall_web.sh does that)  then open  http://127.0.0.1:8080

The same pipeline as the GNU Radio flowgraphs (UHD rx_streamer -> GPU: window,
cuFFT, average or peak-hold), with the plotting in the page: one waterfall per
channel, three fixed labels on each axis (x: -BW/2, 0, +BW/2 MHz; y: 0, -T/2,
-T s), and controls for the RF centre, RX gain, detector and colour range.
Standard library only. Lines go to every browser over Server-Sent Events, one
byte per bin (dB quantised over QMIN..QMAX); the controls are POSTs.

The page can retune the radio, so the server listens on 127.0.0.1 only unless
--host says otherwise (then anyone who can reach the port can retune it).
"""
import argparse
import base64
import collections
import json
import os
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rfsoc_spectrogram import Spectrogram  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
QMIN, QMAX = -140.0, 0.0  # dB range of the one-byte quantisation (0.55 dB steps)


class Hub:
    """Owns the Spectrogram, keeps the recent lines and fans them out to clients."""

    def __init__(self, a):
        dev = "type=rfsoc" + (",addr=" + a.addr if a.addr else "") \
            + (",otw=" + a.otw if a.otw != "sc16" else "") + ("," + a.extra if a.extra else "")
        self.sg = Spectrogram(dev, a.nch, a.rate, a.freq, a.gain, a.nfft, a.overlap, "blackmanharris",
                              a.bins, 0, 0.0, a.otw, a.sim, 10e6)
        st = self.sg.stats()
        self.nch, self.bins, self.rows = a.nch, a.bins, a.rows
        self.rate, self.freq, self.line_rate = st.rate, st.center_freq, self.sg.line_rate
        self.gain, self.detector = a.gain, 0
        self.hist = collections.deque(maxlen=self.rows)  # newest last; each (nch*bins) uint8
        self.clients = set()
        self.lock = threading.Lock()
        self.run = True
        self.session = str(time.time())  # a page that sees it change reloads itself
        self.seen = [0, 0, 0.0]  # overflows, dropped batches, time of the last loss

    def info(self):
        return dict(nch=self.nch, bins=self.bins, rows=self.rows, rate=self.rate, freq=self.freq,
                    line_rate=self.line_rate, qmin=QMIN, qmax=QMAX, gain=self.gain,
                    detector=self.detector)

    def status(self):
        s = self.sg.stats()
        if s.overflows > self.seen[0] or s.batches_dropped > self.seen[1]:
            self.seen[2] = time.time()
        self.seen[0], self.seen[1] = s.overflows, s.batches_dropped
        return dict(freq=s.center_freq, rate=s.rate, line_rate=self.line_rate,
                    history_s=self.rows / self.line_rate,
                    gpu_pct=100.0 * s.gpu_ms_per_batch / max(s.batch_ms, 1e-9),
                    overflows=s.overflows, dropped=s.batches_dropped, lines=s.lines,
                    lost=(time.time() - self.seen[2]) < 10.0, error=self.sg.error())

    def history_blob(self):
        with self.lock:
            rows = list(self.hist)
        if not rows:
            return b""
        return np.stack(rows).tobytes()  # (n, nch*bins), oldest first

    def reader(self):
        self.sg.start()
        n = 0
        while self.run:
            try:
                line = self.sg.read_line(200)
            except RuntimeError as e:
                self.broadcast("status", json.dumps(dict(self.status(), error=str(e))))
                time.sleep(1.0)
                continue
            if line is None:
                continue
            q = np.clip((line.reshape(-1) - QMIN) * (255.0 / (QMAX - QMIN)), 0, 255).astype(np.uint8)
            with self.lock:
                self.hist.append(q)
            self.broadcast("line", base64.b64encode(q.tobytes()).decode())
            n += 1
            if n % max(1, int(self.line_rate)) == 0:  # about once a second
                self.broadcast("status", json.dumps(self.status()))

    def broadcast(self, event, data):
        msg = "event: %s\ndata: %s\n\n" % (event, data)
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            try:
                c.put_nowait(msg)
            except queue.Full:  # a slow browser loses lines, never the others'
                try:
                    c.get_nowait()
                    c.put_nowait(msg)
                except queue.Empty:
                    pass

    def control(self, d):
        if "freq" in d:
            if self.sg.set_freq(float(d["freq"])) == 0:
                self.freq = self.sg.stats().center_freq
        if "gain" in d:
            self.gain = float(d["gain"])
            self.sg.set_gain(self.gain)
        if "detector" in d:
            self.detector = 1 if int(d["detector"]) else 0
            self.sg.set_detector(self.detector)
        return dict(freq=self.freq, gain=self.gain, detector=self.detector)


def make_handler(hub):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):  # quiet
            pass

        def _send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "web", "index.html"), "rb") as f:  # read per request
                    self._send(200, f.read(), "text/html; charset=utf-8")
            elif self.path == "/api/info":
                self._send(200, json.dumps(hub.info()).encode(), "application/json")
            elif self.path == "/api/stream":
                self._stream()
            else:
                self._send(404, b"not found", "text/plain")

        def _stream(self):
            c = queue.Queue(maxsize=300)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                self.wfile.write(("event: hello\ndata: %s\n\n" % hub.session).encode())
                blob = hub.history_blob()
                if blob:  # the recent lines first, so the waterfall is full at once
                    self.wfile.write(("event: history\ndata: %s\n\n"
                                      % base64.b64encode(blob).decode()).encode())
                    self.wfile.flush()
                with hub.lock:
                    hub.clients.add(c)
                self.wfile.write(("event: status\ndata: %s\n\n" % json.dumps(hub.status())).encode())
                self.wfile.flush()
                while hub.run:
                    try:
                        self.wfile.write(c.get(timeout=15).encode())
                    except queue.Empty:
                        self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with hub.lock:
                    hub.clients.discard(c)

        def do_POST(self):
            if self.path != "/api/control":
                return self._send(404, b"not found", "text/plain")
            try:
                n = int(self.headers.get("Content-Length", "0"))
                out = hub.control(json.loads(self.rfile.read(n) or b"{}"))
                self._send(200, json.dumps(out).encode(), "application/json")
            except Exception as e:  # bad request or a refused retune
                self._send(400, json.dumps(dict(error=str(e))).encode(), "application/json")

    return H


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--nch", type=int, default=1, help="channels: 1, 2, 4, 8, 16")
    ap.add_argument("--addr", default="", help="board address (empty: discover)")
    ap.add_argument("-r", "--rate", type=float, default=0.0,
                    help="per-channel rate, served from below (default: the fastest sc16 rate of N)")
    ap.add_argument("-f", "--freq", type=float, default=950e6, help="RF centre, Hz")
    ap.add_argument("--gain", type=float, default=0.0)
    ap.add_argument("--nfft", type=int, default=4096)
    ap.add_argument("--overlap", type=int, default=50, choices=(0, 50, 75))
    ap.add_argument("--bins", type=int, default=0, help="bins per line (default 1024; 512 above 4 channels)")
    ap.add_argument("--rows", type=int, default=0, help="history lines (default 256; 200 above 4 channels)")
    ap.add_argument("--otw", default="sc16", choices=("sc16", "sc12", "sc8"))
    ap.add_argument("--extra", default="", help="more UHD device args, e.g. app_cpus=1-4")
    ap.add_argument("--sim", type=int, default=0, help="1: synthetic source, no board")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    a = ap.parse_args()
    defaults = {1: 1.25e9, 2: 1.25e9, 4: 625e6, 8: 312.5e6, 16: 156.25e6}
    a.rate = a.rate or defaults.get(a.nch, 625e6)
    a.bins = a.bins or (1024 if a.nch <= 4 else 512)
    a.rows = a.rows or (256 if a.nch <= 4 else 200)
    hub = Hub(a)
    threading.Thread(target=hub.reader, daemon=True).start()
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(hub))
    srv.daemon_threads = True
    print("serving %d channel(s) at %.3f MS/s, %.1f lines/s: http://%s:%d"
          % (a.nch, hub.rate / 1e6, hub.line_rate, a.host, a.port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        hub.run = False
        hub.sg.close()


if __name__ == "__main__":
    main()
