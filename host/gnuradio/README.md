# GNU Radio flowgraphs for the ZCU216 and the RFSoC 4x2 (`type=zcu216`)

One flowgraph per board and channel count, `grc/<board>_tones_<family>_<N>ch.grc`,
at the build's maximum rate (the bandwidth): a timed tone burst on every TX
channel (the same tone, `tone` = 10 MHz above the RF centre `freq` = 950 MHz;
both are parameters: `-t` / `-f` on the command line) and a timed capture of
every RX channel inside it, shown in a Qt time sink and a Qt frequency sink (a tab
per group of 4 channels above 4).

## Run it from GNU Radio Companion (on the PC, in its desktop session)

    gnuradio-companion rfsoc_lib/uhd/gnuradio/grc/zcu216_tones_normal_4ch.grc

then click Execute (the play button, F6). The ZCU216 module needs root (DPDK),
so the flowgraph's run command starts it through `pkexec` and `zcu216-uhd`: a
password dialog appears, then the plot window. The board daemon must be
serving; it loads the flowgraph's bitstream itself (~16 s the first time).

From a terminal instead (asks for the sudo password):

    rfsoc_lib/uhd/gnuradio/run_tones.sh normal 4

Burst mode: GNU Radio cannot consume these rates continuously, so every 0.5 s
one burst is sent and 16384 samples per channel (fewer at 8 and 16 channels)
are captured -- contiguous, full rate, time-aligned across channels. Built
from standard blocks (UHD: USRP Sink / Source, Qt GUI sinks) plus an embedded
Python block (the tone bursts, its source inside each `.grc`) and a Python
snippet that issues the timed RX command and fires each burst.

| family | N | build | per-channel rate | wire |
|---|---|---|---|---|
| normal | 1 / 2 / 4 / 8 / 16 | `_f2_fs2500` / `_f2_fs2500` / `_f3_fs2250` / `_f6_fs2250` / `_f12_fs2250` | 1250 / 1250 / 750 / 375 / 187.5 MS/s | sc16 |
| sc8max | 4 / 8 / 16 | `_f2_fs2500` / `_f3_fs2250` / `_f6_fs2250` | 1250 / 750 / 375 MS/s | sc8 |

RFSoC 4x2 (`grc/rfsoc4x2_tones_normal_{1,2}ch.grc`, fs 5000: twice the
ZCU216's per-channel rate at the same factor), run with
`run_tones.sh rfsoc4x2 normal 1` / `... normal 2`. Their device args carry
`product=rfsoc4x2`, so discovery picks the 4x2 with a ZCU216 on the network:

| family | N | build | per-channel rate | wire |
|---|---|---|---|---|
| normal | 1 / 2 | `rfsoc4x2_v49_1ch_qsfp_f2_fs5000` / `rfsoc4x2_v49_2ch_qsfp_f4_fs5000` | 2500 / 1250 MS/s | sc16 |

Each flowgraph opens at its family's maximum rate. The normal family has a
bitstream per RFDC factor below that (`benchmark/oracle_builds.txt`): set
`samp_rate` lower and the daemon loads the highest build at or below it.

Over the air only channels 0-3 are cabled (4T4R): RX 0-3 show the tone (the
sum of the four TX, at its own amplitude and phase per RX); channels 4-15 show
noise. Other peaks in the spectrum are over-the-air signals near the band.

Expected in the console: once at start, "start_of_burst inside a burst" and
a few "cmd time errors" (gr-uhd's sink opens a timed burst when it starts,
which the first real burst closes late). After that every burst plays on
time: no `L` or `U`. Measured on normal 4ch: 56 bursts in 30 s, 0 underflows,
4 late packets, all in the first 3 s.

`ZCU216_GR_SNAPSHOT=<png>` saves the window after `ZCU216_GR_SNAPSHOT_S`
(default 6) s and quits (use with `QT_QPA_PLATFORM=offscreen` headless).

The `.grc` files are the sources: edit them in GNU Radio Companion (3.10).
`grc/` holds nothing else; `run_tones.sh` compiles into
`~/.cache/zcu216_gnuradio`.
