# rfsoc_spectrogram

Gap-free GPU waterfall of a uhd-rfsoc stream (1-16 channels). A capture thread
reads UHD's `rx_streamer` into pinned memory and the GPU does window, cuFFT,
power, average or peak-hold; one spectrum line per channel and line period
goes to a display. The samples bypass GNU Radio, whose UHD source cannot carry
2.5 GS/s (measured: ~700 MS/s at 1 channel, ~275 MS/s at 4, ~40 MS/s at 16).

```sh
host/gnuradio/run_waterfall.sh 4 --addr <board-ip>        # Qt window (grc/waterfall_<N>ch.grc)
host/gnuradio/run_waterfall_web.sh 4 --addr <board-ip>    # browser: http://127.0.0.1:8080
```

`--sim 1` runs a synthetic source without a board. Options: `-r` rate, `-f`
RF centre, `--nfft`, `--overlap`, `--bins`, `--otw`, `--extra` (UHD device
args). One process owns the board at a time.

Needs an NVIDIA GPU with the CUDA toolkit (nvcc, cuFFT), cmake and
`libuhd-dev`; the Qt window also `python3-pyqtgraph`. The library builds on
first run.

| file | what |
|---|---|
| `rfsoc_waterfall*.{h,cpp,cu,cuh}` | the C API, UHD capture and the GPU pipeline |
| `rfsoc_spectrogram.py`, `*.block.yml` | the GNU Radio source block and its GRC definition |
| `rfsoc_waterfall_view.py` | the Qt waterfall sink block (pyqtgraph) |
| `rfsoc_waterfall_web.py`, `web/index.html` | the web server (standard library) and its page |
| `selftest.py` | GPU check against known tones; `--bench` for throughput |

Axes: x is the offset from the RF centre (bottom) and the RF frequency (top),
y is time with 0 for the newest line; 1-2-5 ticks that follow the plot size,
units scaled to the span. A line averages 8192 FFT frames (5-50 lines/s), so
the time span follows the bandwidth.

Measured (GB10 GPU, ZCU216, 4096-point FFT, 50 % overlap, sc16): 0 UHD
overflows at 2.5 GS/s aggregate for 1-16 channels, GPU 17-20 % of real time.
