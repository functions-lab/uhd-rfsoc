# GNU Radio flowgraphs

One flowgraph per channel count, `grc/tones_<N>ch.grc` (N = 1, 2, 4, 8,
16), for any board with N-channel builds: a timed tone burst on every TX
channel (`tone` = 10 MHz above the RF centre `freq` = 950 MHz; `-t` / `-f`),
each channel with its own phase and amplitude, and a timed capture of every
RX channel inside it, shown in a Qt time sink and a Qt frequency sink (a tab
per group of 4 channels above 4). Needs GNU Radio 3.10, the installed module
(`../README.md`) and the board daemon serving; the daemon loads the
flowgraph's bitstream itself (~16 s the first time).

| N | default rate `-r` (MS/s per channel) | boards |
|---|---|---|
| 1, 2 | 1250 | ZCU216, RFSoC 4x2 (1ch up to `-r 2.5e9`) |
| 4 / 8 / 16 | 625 / 312.5 / 156.25 | ZCU216 |

The default is N's fastest sc16 rate on the ZCU216; any `-r` is served from
below by the board (`../../README.md` has the rates).

## Run

From a terminal on the PC's desktop (DPDK needs root: `uhd-rfsoc` asks for
the sudo password):

    host/gnuradio/run_tones.sh 4                                  # 4T4R, 625 MS/s per channel
    host/gnuradio/run_tones.sh 1 --addr <board-ip> -r 2.5e9       # an RFSoC 4x2 at 2500 MS/s
    host/gnuradio/run_tones.sh 4 -f 950e6 -t 20e6 --tx-phases 0,90,180,-90 --tx-amps 0.25,0.25,0.25,0.25

`--addr` picks the board (else discovery: the only board, or the first).
`run_tones.sh` compiles the `.grc` with `grcc` into
`~/.cache/uhd_rfsoc_gnuradio` when the `.grc` is newer. Without a display,
`SECONDS_HEADLESS=30 run_tones.sh 1 ...` runs 30 s offscreen, saves the
window to `tones_1ch.png` (`SNAPSHOT=<png>`) and prints the bursts sent.

From GNU Radio Companion instead: `gnuradio-companion
host/gnuradio/grc/tones_4ch.grc`, then Execute (F6); the run command starts
the generated Python through `pkexec` (a password dialog) and the installed
`/usr/local/bin/uhd-rfsoc`.

## What you see

Burst mode: GNU Radio cannot consume these rates continuously, so every 0.5 s
one burst is sent and `cap_len` samples per channel (16384; 8192 at 8
channels, 4096 at 16) are captured: contiguous, full rate, time-aligned
across channels. Built from standard blocks (UHD USRP Sink / Source, Qt GUI
sinks) plus an embedded Python block (the tone bursts) and a Python snippet
that issues the timed RX command and fires each burst.

With TX c cabled (or over the air) to RX c, RX shows the tone; channels not
connected show noise. The time plots show the real (solid) and imaginary
(dashed) part of every RX channel, one colour per channel, so offsets
between channels are visible. The tabs under the plots hold one slider per
channel for the TX phase (-180..180 deg) and amplitude (0..1 of full
scale), effective from the next burst; their start values are
`--tx-phases` / `--tx-amps` (one value per channel; default 0 deg and 0.25).

Expected in the console: once at start, "start_of_burst inside a burst" and
a few "cmd time errors" (gr-uhd's sink opens a timed burst when it starts,
which the first real burst closes late); after that no `L` or `U`.

The `.grc` files are the sources (GNU Radio Companion 3.10); `grc/` holds
nothing else (generated `.py` files are ignored by git).
