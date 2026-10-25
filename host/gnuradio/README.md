# GNU Radio flowgraphs for the ZCU216 and the RFSoC 4x2

One flowgraph per board and channel count, `grc/<board>_tones_<family>_<N>ch.grc`,
at the build's fastest sc16 rate (the bandwidth): a timed tone burst on every
TX channel (the same tone, `tone` = 10 MHz above the RF centre `freq` = 950 MHz;
both are parameters: `-t` / `-f` on the command line), each channel with its
own phase and amplitude, and a timed capture of
every RX channel inside it, shown in a Qt time sink and a Qt frequency sink (a
tab per group of 4 channels above 4). GNU Radio 3.10 and the installed module
(`../README.md`) are needed; the board daemon must be serving, and it loads
the flowgraph's bitstream itself (~16 s the first time).

## Which flowgraph

| board | family | N | per-channel rate | wire | run |
|---|---|---|---|---|---|
| ZCU216 | normal | 1 / 2 | 1250 MS/s | sc16 | `run_tones.sh normal 1` (2) |
| | normal | 4 / 8 / 16 | 625 / 312.5 / 156.25 MS/s | sc16 | `run_tones.sh normal 4` (8, 16) |
| RFSoC 4x2 | normal | 1 / 2 | 2500 / 1250 MS/s | sc16 | `run_tones.sh rfsoc4x2 normal 1` (2) |

Each flowgraph runs the channel count's template at its fastest sc16 rate;
set `samp_rate` lower and the
daemon retunes the template to the highest rate at or below it
(`../README.md` has the rates). The RFSoC 4x2 flowgraphs use `type=rfsoc4x2`
(the module then finds only RFSoC 4x2 boards).

## Run

From a terminal on the PC's desktop (DPDK needs root: it asks for the sudo
password; the ZCU216 flowgraphs go through `zcu216-uhd`, the RFSoC 4x2 ones
through plain `sudo`):

    host/gnuradio/run_tones.sh normal 4                       # ZCU216 4T4R, 625 MS/s per channel
    host/gnuradio/run_tones.sh normal 4 --addr <board-ip> -f 950e6 -t 20e6

`run_tones.sh` compiles the `.grc` with `grcc` (GNU Radio 3.10's; `GRCC=<path>`
picks another) into `~/.cache/<board>_gnuradio` when the `.grc` is newer.

From GNU Radio Companion instead:

    gnuradio-companion host/gnuradio/grc/zcu216_tones_normal_4ch.grc

then Execute (F6). The flowgraph's run command starts the generated Python
through `pkexec` (a password dialog) and, for the ZCU216, the installed
`/usr/local/bin/zcu216-uhd` (where `cmake --install` puts it by default).

## What you see

Burst mode: GNU Radio cannot consume these rates continuously, so every 0.5 s
one burst is sent and `cap_len` samples per channel (16384; 8192 at 8
channels, 4096 at 16) are captured -- contiguous, full rate, time-aligned
across channels. Built from standard blocks (UHD: USRP Sink / Source, Qt GUI
sinks) plus an embedded Python block (the tone bursts, its source inside each
`.grc`) and a Python snippet that issues the timed RX command and fires each
burst.

With channels 0-3 cabled over the air as a 4T4R link, RX 0-3 show the tone
(the sum of the four TX, at its own amplitude and phase per RX); channels not
cabled show noise. Other peaks in the spectrum are over-the-air signals near
the band.

**TX phase and amplitude per channel** (every flowgraph): the tabs under the
plots hold one slider per channel for the TX phase (-180..180 deg) and one for
the TX amplitude (0..1 of full scale), movable while it runs; a change takes
effect on the next burst. Their start values come from `--tx-phases` and
`--tx-amps` (comma-separated, one value per channel; default 0 deg and 0.25):

```sh
./run_tones.sh normal 4 --tx-phases 0,21.3,158.3,-55.8 --tx-amps 0.25,0.16,0.25,0.18
```

The time plots show the real (solid) and imaginary (dashed) part of every RX
channel in one figure, one colour per channel (up to 4 channels per figure;
the 8- and 16-channel flowgraphs have one tab per group of 4), so the offsets
between channels are visible. With DAC c cabled to ADC c, move the
sliders until the traces show what you want (e.g. RX phases 90 deg apart, equal
amplitudes): the TX setting that does it is the inverse of that loopback's own
phase and gain, which stays the same across runs at the same carrier, tone and
rate.

Expected in the console: once at start, "start_of_burst inside a burst" and
a few "cmd time errors" (gr-uhd's sink opens a timed burst when it starts,
which the first real burst closes late). After that every burst plays on
time: no `L` or `U`.

`ZCU216_GR_SNAPSHOT=<png>` saves the window after `ZCU216_GR_SNAPSHOT_S`
(default 6) s and quits (use with `QT_QPA_PLATFORM=offscreen` headless).

The `.grc` files are the sources: edit them in GNU Radio Companion (3.10).
`grc/` holds nothing else (the generated `.py` next to a `.grc` is ignored by
git).
