# GNU Radio flowgraphs

One flowgraph per channel count: `grc/tones_<N>ch.grc`, N = 1, 2, 4, 8, 16.
It works with any board that has N-channel builds.

Each flowgraph:

- sends a timed tone burst on every TX channel, each channel with its own
  phase and amplitude;
- captures every RX channel during the burst;
- shows the capture in a Qt time sink and a Qt frequency sink (above 4
  channels, one tab per group of 4).

You need GNU Radio 3.10, the installed module (`../README.md`) and the board
daemon serving. The daemon loads the flowgraph's bitstream itself (~16 s the
first time).

## Run

From a terminal on the PC's desktop. DPDK needs root, so `uhd-rfsoc` asks
for the sudo password:

```sh
host/gnuradio/run_tones.sh 4                                # 4T4R, 625 MS/s per channel
host/gnuradio/run_tones.sh 1 --addr <board-ip> -r 2.5e9     # an RFSoC 4x2 at 2500 MS/s
host/gnuradio/run_tones.sh 4 -f 950e6 -t 20e6 --tx-phases 0,90,180,-90 --tx-amps 0.25,0.25,0.25,0.25
```

| option | meaning | default |
|---|---|---|
| `--addr` | the board | the one discovery finds (the first, if several) |
| `-r` | rate per channel; served from below by the board (`../../README.md` has the rates) | N's fastest sc16 rate on the ZCU216: 1250 MS/s at 1 and 2 channels, 625 / 312.5 / 156.25 at 4 / 8 / 16 |
| `-f` | RF centre frequency | 950 MHz |
| `-t` | tone offset above the RF centre | 10 MHz |
| `--tx-phases` | start phase per TX channel, in degrees | 0 |
| `--tx-amps` | start amplitude per TX channel, 0..1 of full scale | 0.25 |

`run_tones.sh` compiles the `.grc` with `grcc` into
`~/.cache/uhd_rfsoc_gnuradio` whenever the `.grc` is newer.

**Without a display:** `SECONDS_HEADLESS=30 run_tones.sh 1 ...` runs 30 s
offscreen, saves the window to `tones_1ch.png` (`SNAPSHOT=<png>` to change)
and prints the bursts sent.

**From GNU Radio Companion:**
`gnuradio-companion host/gnuradio/grc/tones_4ch.grc`, then Execute (F6). The
generated Python starts through `pkexec` (a password dialog) and the
installed `/usr/local/bin/uhd-rfsoc`.

## What you see

GNU Radio cannot consume these rates continuously, so the flowgraph works
in bursts. Every 0.5 s it sends one burst and captures 16384 samples per
channel (8192 at 8 channels, 4096 at 16): contiguous, at full rate,
time-aligned across channels.

- **RX:** with TX c connected to RX c (cable or over the air), RX c shows
  the tone. Unconnected channels show noise.
- **Time plots:** the real (solid) and imaginary (dashed) part of every RX
  channel, one colour per channel, so offsets between channels are visible.
- **Sliders:** the tabs under the plots hold one phase slider (-180..180
  deg) and one amplitude slider (0..1) per TX channel. A change takes
  effect at the next burst.

Expected in the console, once at start: "start_of_burst inside a burst" and
a few "cmd time errors" (gr-uhd's sink opens a timed burst when it starts,
and the first real burst closes it late). After that there should be no `L`
or `U`.

## The sources

The `.grc` files are the sources (GNU Radio Companion 3.10). They use
standard blocks (UHD USRP Sink / Source, Qt GUI sinks) plus an embedded
Python block for the tone bursts and a Python snippet that issues the timed
RX command and fires each burst. Generated `.py` files are ignored by git.
