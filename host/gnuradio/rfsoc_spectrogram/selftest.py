#!/usr/bin/env python3
"""Self-test of librfsoc_waterfall on the GPU with a synthetic source (no board).

  selftest.py            correctness: tone bin and level per channel, both
                         detectors, both windows
  selftest.py --bench    GPU throughput: how many channels x MS/s the pipeline
                         sustains, synthetic data as fast as the GPU takes it

Exit status 0 when every check passes.
"""
import argparse
import sys
import time

import numpy as np

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from rfsoc_spectrogram import Spectrogram  # noqa: E402


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (" " + detail if detail else ""))
    return ok


def correctness():
    ok = True
    rate, nch, nfft, bins = 100e6, 3, 4096, 4096
    for window in ("hann", "blackmanharris"):
        for overlap in (0, 50, 75):
            sg = Spectrogram(nch=nch, rate=rate, freq=1e9, nfft=nfft, overlap=overlap,
                             window=window, bins=bins, detector=0, line_rate=50, sim=1,
                             sim_tone=5e6, sim_tone_dbfs=-20.0)
            sg.start()
            lines = [l.copy() for l in (sg.read_line(2000) for _ in range(5)) if l is not None]
            sg.close()
            if not check(f"{window}/{overlap}% got lines", len(lines) >= 4, f"({len(lines)})"):
                ok = False
                continue
            avg = np.mean(lines[1:], axis=0)
            for c in range(nch):
                want_hz = (5e6 * (c + 1) + rate / 2) % rate - rate / 2
                want_bin = int(round(nfft / 2 + want_hz / rate * nfft))
                got_bin = int(np.argmax(avg[c]))
                level = avg[c][got_bin]
                floor = np.median(avg[c])
                ok &= check(f"{window}/{overlap}% ch{c} tone bin", abs(got_bin - want_bin) <= 1,
                            f"got {got_bin} want {want_bin}")
                # a window's peak bin is within its scalloping of -20 dBFS
                ok &= check(f"{window}/{overlap}% ch{c} level", -22.0 < level < -19.5,
                            f"{level:.2f} dBFS (tone -20)")
                ok &= check(f"{window}/{overlap}% ch{c} floor", level - floor > 50,
                            f"peak-floor {level - floor:.0f} dB")
    # peak vs average: the peak detector is never below the average
    sg = Spectrogram(nch=1, rate=rate, freq=1e9, nfft=nfft, overlap=50, bins=1024,
                     detector=0, line_rate=50, sim=1, sim_tone=5e6)
    sg.start()
    a = [sg.read_line(2000).copy() for _ in range(4)][-1]
    sg.set_detector(1)
    time.sleep(0.1)
    p = [sg.read_line(2000).copy() for _ in range(4)][-1]
    sg.close()
    ok &= check("peak >= average (1024 bins)", float(np.mean(p - a)) > 0.5,
                f"mean +{np.mean(p - a):.1f} dB")
    return ok


def bench():
    print("synthetic source as fast as the GPU takes it (sim=2)\n"
          "nch  rate MS/s  nfft ovl  aggregate MS/s   GPU ms/batch  batch ms  load   dropped batches")
    for nch, rate_ms, nfft, overlap in [(1, 1250, 4096, 50), (4, 625, 4096, 50),
                                         (16, 156.25, 4096, 50), (16, 156.25, 4096, 0),
                                         (16, 156.25, 16384, 50), (16, 156.25, 1024, 75)]:
        sg = Spectrogram(nch=nch, rate=rate_ms * 1e6, freq=1e9, nfft=nfft, overlap=overlap,
                         bins=1024 if nfft >= 1024 else nfft, line_rate=30, sim=2)
        sg.start()
        time.sleep(1.0)
        s0 = sg.stats()
        t0 = time.time()
        time.sleep(4.0)
        s1 = sg.stats()
        dt = time.time() - t0
        sg.close()
        proc = (s1.samples_processed - s0.samples_processed) * nch / dt / 1e6
        print(f"{nch:3d}  {rate_ms:9.2f}  {nfft:5d} {overlap:3d}  {proc:14.0f}   "
              f"{s1.gpu_ms_per_batch:11.3f}  {s1.batch_ms:8.3f}  "
              f"{100 * s1.gpu_ms_per_batch / s1.batch_ms:4.0f}%  {s1.batches_dropped}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", action="store_true")
    a = ap.parse_args()
    if a.bench:
        bench()
        sys.exit(0)
    sys.exit(0 if correctness() else 1)
