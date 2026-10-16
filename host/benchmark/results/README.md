# Benchmark results — robustness of the v49 rate ladder

Measured on zcu216-0 (ZCU216) and wei-duke-wsp5 (PC, ConnectX-5 over 100GbE): the 48 normal-family builds 2026-10-07 (software 75f30e22e to 4d8465686), the 3 sc8max builds 2026-10-09 and -10 (abe86e6c8 to 32f448a77) -- the 51 bitstreams of `../oracle_builds.txt`.

## Result

**Normal family: every build x wire-format case the daemon accepts ran with zero missing samples: 166 of 166 cases, 505 of 505 runs clean.** No dropped sample, overflow, underrun, sequence error or late packet, in full-rate simultaneous TX and RX on every channel through the DACs and ADCs, from 1 to 16 channels and up to 97 % of the 100GbE link.

**Over the air, every TX wire format matches the sc16 reference on all 48 normal-family builds.**

**sc8max family (2x the sc16 rate per channel at 8 and 16 channels, sc8 only): the board carries it without loss; full duplex at that rate is at the limit of this PC.** Bit-exact sc8 capture on every channel of all three builds, the over-the-air sc8 check passing, 0 FPGA streamer overflows in every run where it was read (147 sc8max runs), and **each direction alone at full rate 40 of 40 runs clean**. Full duplex (96 Gb/s each way at 8 and 16 channels): ignoring cold-start losses (a one-off overflow in the first second, after which the stream runs clean), the rate is sustained in 4ch 35 of 35, 8ch 124-126 of 132 and 16ch 38-40 of 46 runs; the rest lost data on the PC mid-run, at a rate no higher than the normal family's sc16 at the same 96 Gb/s duplex (8ch: 3 of 25). Details under "sc8max".

## What was measured

`benchmark/oracle.sh robustness` per build:

- **Throughput**: for every wire format the build accepts, strict `benchmark_rate` (`bench_strict.sh`: every error threshold 0) in rxtx mode at the build's rate on all its channels, 30 s, 3 runs (the 97 % case 10 runs). A run passes only with zero drops, overflows, underruns, sequence errors and late packets.
- **Over the air** (`otw_tx_ota.py`): a tone sent in each TX wire format (sc16, sc12, sc8, fc32 from sc16 and fc32 host buffers), received in sc16 and compared with the sc16 reference: amplitude within 0.5 dB and phase within 5 deg (sc8: 1 dB / 10 deg), no TX error event.

Setup, required for the rates near the link limit (see `../../host/AGENTS.md`):

```
device args  rx_workers=2,worker_cpus=2:3,tx_workers=3,tx_worker_cpus=4:5:11,dpdk_rx_cores=8,
             dpdk_tx_core=10,dpdk_rxd=128,tx_max_pkts=256,num_recv_frames=1024
environment  ZCU216_APP_CPUS=0,1,6,7
PC           host/tools/isolate_cpus.sh apply, cpufreq governor performance, no other heavy load
```

Reproduce: `sudo -E env PATH=$PATH ADDR=<board-ip> RUNS=3 DUR=30 benchmark/oracle.sh robustness [filter]`.

## Coverage

51 bitstreams x 4 wire formats = 204 combinations; 169 are accepted by the daemon and all were tested. The rest are refused at `set_rx_rate` / `set_tx_rate`, so no application can stream them:

| combinations | count |
|---|---|
| tested | 169 |
| refused: N x rate x bytes per sample exceeds the link payload rate (12.38 GB/s) | 20 |
| refused: RX fc32 on a 512-bit-beat build (all 4-, 8- and 16-channel builds; the streamer cannot emit two FIFO words per clock) | 15 |

(The sc8max 8ch and 16ch builds have a 1024-bit beat and carry sc8 only; their sc16 / sc12 / fc32 would also exceed the link, counted above.)

## Per build

Cell: clean runs / runs, and the share of the link that format uses. `link` = refused, exceeds the link; `512b` = refused, RX fc32 on a 512-bit beat.

| family | N | F | fs (MS/s) | per-channel rate | beat / fabric clock | sc16 | sc12 | sc8 | fc32 | over the air |
|---|---|---|---|---|---|---|---|---|---|---|
| normal | 1 | 2 | 2500 | 1250 MS/s | 128 b / 312.5 MHz | 3/3 (40 %) | 3/3 (30 %) | 3/3 (20 %) | 3/3 (81 %) | pass |
| normal | 1 | 3 | 2500 | 833.333 MS/s | 128 b / 208.333 MHz | 3/3 (27 %) | 3/3 (20 %) | 3/3 (13 %) | 3/3 (54 %) | pass |
| normal | 1 | 4 | 2500 | 625 MS/s | 128 b / 156.25 MHz | 3/3 (20 %) | 3/3 (15 %) | 3/3 (10 %) | 3/3 (40 %) | pass |
| normal | 1 | 5 | 2500 | 500 MS/s | 128 b / 125 MHz | 3/3 (16 %) | 3/3 (12 %) | 3/3 (8 %) | 3/3 (32 %) | pass |
| normal | 1 | 6 | 2500 | 416.667 MS/s | 128 b / 104.167 MHz | 3/3 (13 %) | 3/3 (10 %) | 3/3 (7 %) | 3/3 (27 %) | pass |
| normal | 1 | 8 | 2500 | 312.5 MS/s | 128 b / 78.125 MHz | 3/3 (10 %) | 3/3 (8 %) | 3/3 (5 %) | 3/3 (20 %) | pass |
| normal | 1 | 10 | 2500 | 250 MS/s | 128 b / 62.5 MHz | 3/3 (8 %) | 3/3 (6 %) | 3/3 (4 %) | 3/3 (16 %) | pass |
| normal | 1 | 12 | 2500 | 208.333 MS/s | 128 b / 52.0833 MHz | 3/3 (7 %) | 3/3 (5 %) | 3/3 (3 %) | 3/3 (13 %) | pass |
| normal | 1 | 16 | 2500 | 156.25 MS/s | 128 b / 39.0625 MHz | 3/3 (5 %) | 3/3 (4 %) | 3/3 (3 %) | 3/3 (10 %) | pass |
| normal | 1 | 20 | 2500 | 125 MS/s | 128 b / 31.25 MHz | 3/3 (4 %) | 3/3 (3 %) | 3/3 (2 %) | 3/3 (8 %) | pass |
| normal | 1 | 24 | 2500 | 104.167 MS/s | 128 b / 26.0417 MHz | 3/3 (3 %) | 3/3 (3 %) | 3/3 (2 %) | 3/3 (7 %) | pass |
| normal | 1 | 40 | 2500 | 62.5 MS/s | 128 b / 15.625 MHz | 3/3 (2 %) | 3/3 (2 %) | 3/3 (1 %) | 3/3 (4 %) | pass |
| normal | 2 | 2 | 2500 | 1250 MS/s | 256 b / 312.5 MHz | 3/3 (81 %) | 3/3 (61 %) | 3/3 (40 %) | link | pass |
| normal | 2 | 3 | 2500 | 833.333 MS/s | 256 b / 208.333 MHz | 3/3 (54 %) | 3/3 (40 %) | 3/3 (27 %) | link | pass |
| normal | 2 | 4 | 2500 | 625 MS/s | 256 b / 156.25 MHz | 3/3 (40 %) | 3/3 (30 %) | 3/3 (20 %) | 3/3 (81 %) | pass |
| normal | 2 | 5 | 2500 | 500 MS/s | 256 b / 125 MHz | 3/3 (32 %) | 3/3 (24 %) | 3/3 (16 %) | 3/3 (65 %) | pass |
| normal | 2 | 6 | 2500 | 416.667 MS/s | 256 b / 104.167 MHz | 3/3 (27 %) | 3/3 (20 %) | 3/3 (13 %) | 3/3 (54 %) | pass |
| normal | 2 | 8 | 2500 | 312.5 MS/s | 256 b / 78.125 MHz | 3/3 (20 %) | 3/3 (15 %) | 3/3 (10 %) | 3/3 (40 %) | pass |
| normal | 2 | 10 | 2500 | 250 MS/s | 256 b / 62.5 MHz | 3/3 (16 %) | 3/3 (12 %) | 3/3 (8 %) | 3/3 (32 %) | pass |
| normal | 2 | 12 | 2500 | 208.333 MS/s | 256 b / 52.0833 MHz | 3/3 (13 %) | 3/3 (10 %) | 3/3 (7 %) | 3/3 (27 %) | pass |
| normal | 2 | 16 | 2500 | 156.25 MS/s | 256 b / 39.0625 MHz | 3/3 (10 %) | 3/3 (8 %) | 3/3 (5 %) | 3/3 (20 %) | pass |
| normal | 2 | 20 | 2500 | 125 MS/s | 256 b / 31.25 MHz | 3/3 (8 %) | 3/3 (6 %) | 3/3 (4 %) | 3/3 (16 %) | pass |
| normal | 2 | 24 | 2500 | 104.167 MS/s | 256 b / 26.0417 MHz | 3/3 (7 %) | 3/3 (5 %) | 3/3 (3 %) | 3/3 (13 %) | pass |
| normal | 2 | 40 | 2500 | 62.5 MS/s | 256 b / 15.625 MHz | 3/3 (4 %) | 3/3 (3 %) | 3/3 (2 %) | 3/3 (8 %) | pass |
| normal | 4 | 3 | 2250 | 750 MS/s | 512 b / 187.5 MHz | 10/10 (97 %) | 3/3 (73 %) | 3/3 (48 %) | link | pass |
| normal | 4 | 4 | 2250 | 562.5 MS/s | 512 b / 140.625 MHz | 3/3 (73 %) | 3/3 (55 %) | 3/3 (36 %) | link | pass |
| normal | 4 | 5 | 2250 | 450 MS/s | 512 b / 112.5 MHz | 3/3 (58 %) | 3/3 (44 %) | 3/3 (29 %) | link | pass |
| normal | 4 | 6 | 2250 | 375 MS/s | 512 b / 93.75 MHz | 3/3 (48 %) | 3/3 (36 %) | 3/3 (24 %) | 512b | pass |
| normal | 4 | 8 | 2250 | 281.25 MS/s | 512 b / 70.3125 MHz | 3/3 (36 %) | 3/3 (27 %) | 3/3 (18 %) | 512b | pass |
| normal | 4 | 10 | 2250 | 225 MS/s | 512 b / 56.25 MHz | 3/3 (29 %) | 3/3 (22 %) | 3/3 (15 %) | 512b | pass |
| normal | 4 | 12 | 2250 | 187.5 MS/s | 512 b / 46.875 MHz | 3/3 (24 %) | 3/3 (18 %) | 3/3 (12 %) | 512b | pass |
| normal | 4 | 16 | 2250 | 140.625 MS/s | 512 b / 35.1562 MHz | 3/3 (18 %) | 3/3 (14 %) | 3/3 (9 %) | 512b | pass |
| normal | 4 | 20 | 2250 | 112.5 MS/s | 512 b / 28.125 MHz | 3/3 (15 %) | 3/3 (11 %) | 3/3 (7 %) | 512b | pass |
| normal | 4 | 24 | 2250 | 93.75 MS/s | 512 b / 23.4375 MHz | 3/3 (12 %) | 3/3 (9 %) | 3/3 (6 %) | 512b | pass |
| normal | 4 | 40 | 2250 | 56.25 MS/s | 512 b / 14.0625 MHz | 3/3 (7 %) | 3/3 (5 %) | 3/3 (4 %) | 512b | pass |
| normal | 8 | 6 | 2250 | 375 MS/s | 512 b / 187.5 MHz | 3/3 (97 %) | 3/3 (73 %) | 3/3 (48 %) | link | pass |
| normal | 8 | 8 | 2250 | 281.25 MS/s | 512 b / 140.625 MHz | 3/3 (73 %) | 3/3 (55 %) | 3/3 (36 %) | link | pass |
| normal | 8 | 10 | 2250 | 225 MS/s | 512 b / 112.5 MHz | 3/3 (58 %) | 3/3 (44 %) | 3/3 (29 %) | link | pass |
| normal | 8 | 12 | 2250 | 187.5 MS/s | 512 b / 93.75 MHz | 3/3 (48 %) | 3/3 (36 %) | 3/3 (24 %) | 512b | pass |
| normal | 8 | 16 | 2250 | 140.625 MS/s | 512 b / 70.3125 MHz | 3/3 (36 %) | 3/3 (27 %) | 3/3 (18 %) | 512b | pass |
| normal | 8 | 20 | 2250 | 112.5 MS/s | 512 b / 56.25 MHz | 3/3 (29 %) | 3/3 (22 %) | 3/3 (15 %) | 512b | pass |
| normal | 8 | 24 | 2250 | 93.75 MS/s | 512 b / 46.875 MHz | 3/3 (24 %) | 3/3 (18 %) | 3/3 (12 %) | 512b | pass |
| normal | 8 | 40 | 2250 | 56.25 MS/s | 512 b / 28.125 MHz | 3/3 (15 %) | 3/3 (11 %) | 3/3 (7 %) | 512b | pass |
| normal | 16 | 12 | 2250 | 187.5 MS/s | 512 b / 187.5 MHz | 3/3 (97 %) | 3/3 (73 %) | 3/3 (48 %) | link | pass |
| normal | 16 | 16 | 2250 | 140.625 MS/s | 512 b / 140.625 MHz | 3/3 (73 %) | 3/3 (55 %) | 3/3 (36 %) | link | pass |
| normal | 16 | 20 | 2250 | 112.5 MS/s | 512 b / 112.5 MHz | 3/3 (58 %) | 3/3 (44 %) | 3/3 (29 %) | link | pass |
| normal | 16 | 24 | 2250 | 93.75 MS/s | 512 b / 93.75 MHz | 3/3 (48 %) | 3/3 (36 %) | 3/3 (24 %) | 512b | pass |
| normal | 16 | 40 | 2250 | 56.25 MS/s | 512 b / 56.25 MHz | 3/3 (29 %) | 3/3 (22 %) | 3/3 (15 %) | 512b | pass |
| sc8max | 4 | 2 | 2500 | 1250 MS/s | 512 b / 312.5 MHz | link | link | 9/10 (81 %) | link | sc8: pass (4/4) |
| sc8max | 8 | 3 | 2250 | 750 MS/s | 1024 b / 187.5 MHz | link | link | 40/50 (97 %) | link | sc8: pass (5/5) |
| sc8max | 16 | 6 | 2250 | 375 MS/s | 1024 b / 187.5 MHz | link | link | 10/10 (97 %) | link | sc8: pass (4 of 5) |

## sc8max

The sc8max family streams sc8 only at twice the normal family's maximum per
channel at 8 and 16 channels (6.0 GS/s, 96 Gb/s of sc8 -- the link load of the
sc16 maximum), on a 1024-bit converter beat that udp_streamer / udp_player move
as one sc8 wire word per clock. At 4 channels it reaches 1250 MS/s (1.67x; 2x
would be 1500 MS/s, beyond the 2.5 GS/s ADC at factor 2). Measured 2026-10-09
and -10 with MTS locked on every load (the daemon serves only after the lock
is confirmed; three loads needed the second attempt). The per-build table
above gives the runs with the reference layout (1024-frame RX ring).

**The board side:**

| check | 4ch 1250 MS/s | 8ch 750 MS/s | 16ch 375 MS/s |
|---|---|---|---|
| sc8 test pattern, every channel (`otw_rx_check.py`, cpu sc8) | bit-exact (x3) | bit-exact (x4, bursts up to 260k samples/ch) | bit-exact (x3) |
| over the air, TX sc8 (cpu fc32 and sc16) captured in sc8 | pass x4, tone 56-58 dB above the noise bin | pass x5, 53-59 dB | pass x4, 52-55 dB; one capture lost a packet on the PC |
| RX only, full rate, 30 s | -- | 10/10 | 10/10 |
| TX only, full rate, 30 s | -- | 10/10 | 10/10 |
| FPGA streamer overflows, every run where read (147 runs, duplex included) | -- | 0 | 0 |
| FPGA player underflows, RX-only / TX-only runs | -- | 0 | 0 |

**Full duplex, 30 s runs** (every error threshold 0):

| host setting | 4ch | 8ch | 16ch |
|---|---|---|---|
| reference layout (RX ring 1024 frames) | 9/10 | 40/50 | 10/10 |
| RX ring 2048 | -- | 18/20 | -- |
| RX ring 4096 | 20/20 | 37/40 | 26/30 |
| ring 1024, deep C-states (C6) off | -- | 4/7 | -- |
| ring 1024, `tx_warmup=0` | 15/15 | 22/25 | 11/15 |
| same duplex load in sc16 (normal family, reference layout) | -- | 8ch F6: 18/20 | -- |

Every failed run lost data on the PC, never in the FPGA: the streamer's
overflows were 0, and where the player underflowed the host had not sent the
data in time. Three kinds:

- **Startup** (sc8 only): the host RX ring overflows once, ~5000 packets, at
  ~0.16 s of device time -- when `benchmark_rate` creates the TX streamer while
  RX already streams. Rarer with `tx_warmup=0` (the module then sends no burst
  of 512 full-size packets to the FPGA's discard port at TX creation: 1 of 25
  runs against 9 of 47), but at 16 channels that setting then showed small TX
  underruns (2 of 15 runs, ~90 each).
- **Collapse** (sc8 and sc16): a stall mid-run fills the RX ring and the NIC
  queues (hundreds of ring-full events, `imissed`), and at 97 % of the link the
  host never catches up; RX ends at 50-95 %, TX underflows. With a 4096-frame
  ring no startup overflow was seen, but collapses remained (`../../host/AGENTS.md`
  records RX falling behind on cold buffers after a stall with 4096 frames);
  no ring size or other host setting tried made full duplex clean.
- **Small TX underruns** only (a few runs).

**Sustained rate, cold start ignored.** Every full-duplex run with a per-run
log (all host settings above, 2026-10-09 and -10), classified by when the loss
happened:

| build | runs | clean | cold-start loss only (ignored) | cold-start loss, never recovered | first loss after 1 s | small TX underruns only (not timed) |
|---|---|---|---|---|---|---|
| sc8max 4ch 1250 MS/s | 35 | 35 | 0 | 0 | 0 | 0 |
| sc8max 8ch 750 MS/s | 132 | 112 | 12 | 2 | 4 | 2 |
| sc8max 16ch 375 MS/s | 46 | 38 | 0 | 2 | 4 | 2 |
| normal 8ch F6, sc16, same 96 Gb/s | 25 | 22 | 0 | 0 | 3 | 0 |

A cold-start loss is the one-off RX overflow ~0.17 s into the run; after it the
stream runs clean to the end, so the rate is sustained. A run that never
recovered from it, a loss after the first second (some of them a single
packet: 16ch 3840 samples, sc16 2304 and 10240) and TX underruns the log does
not time count against sustaining it. So the FPGA path carries the sc8max
rates without loss, each direction streams cleanly at full rate, and full
duplex is sustained in 4ch 100 %, 8ch 94-95 %, 16ch 83-87 % of 30 s runs on this
PC (6 cores, one DIMM channel) -- the mid-run losses at the rate the normal
family's sc16 shows at the same load (8ch 3 of 25).

## Run-time rate change (template builds)

A template build serves every Gen3 factor at or above its own from one
bitstream: `set_rx_rate` / `set_tx_rate` retune it in place (RFDC factor,
MMCM over DRP, MTS; `../../PROTOCOL.md` section 8). Pass per rate: the
daemon logs `MTS LOCKED`, the factor read back on every enabled block and the
converter clock measured by the timekeeper within 1 %, and
`rate_loopback.py` finds its TX->RX pulse (channel 0, over the air) >= 20 dB
over the median in every trial, at the rate asked. Latency is not a criterion
(it moves by whole samples between MTS runs).

**Every template, 1 to 16 channels: every rate asked PASS (71 of 71), MTS
locked at every bring-up and retune (71 of 71, all four DAC and ADC tiles),
after one 4ch bring-up refused under the old 2-attempt limit (below).**

| template | rates served (MS/s) | rates asked | PASS | MTS locks | failed attempts before a lock | retune s | clock error max |
|---|---|---|---|---|---|---|---|
| 1ch F2 fs2500 | 1250, 833.333, 625, 500, 416.667, 312.5, 250, 208.333, 156.25, 125, 104.167, 62.5 | 19 | 19 | 19 | 3 (F4) | 1.0-1.9 | 0.02 % |
| 2ch F2 fs2500 | same as 1ch | 16 | 16 | 16 | 2 (F4) | 1.0-1.4 | 0.008 % |
| 4ch F3 fs2250 | 750, 562.5, 450, 375, 281.25, 225, 187.5, 140.625, 112.5, 93.75, 56.25 | 15 | 15 | 15 | 0 | 1.1 | 0.011 % |
| 8ch F6 fs2250 | 375, 281.25, 225, 187.5, 140.625, 112.5, 93.75, 56.25 | 12 | 12 | 12 | 3 (F6) | 1.2-2.0 | 0.004 % |
| 16ch F12 fs2250 | 187.5, 140.625, 112.5, 93.75, 56.25 | 9 | 9 | 9 | 0 | 1.3 | 0.006 % |

Each run: down the ladder, back to the top, then jumps (e.g. 8ch 375 -> 140.625
-> 281.25 -> 375). A failed attempt is the DAC alignment error ("Alignment
correction delay 31 required exceeds maximum (31) for DAC Tile n"): it comes
at the 156.25 MHz (F4 at fs2500) and 187.5 MHz (F3 / F6 at fs2250) converter
clocks, and locking MTS again clears it. One 4ch bring-up failed both of the
2 attempts the daemon then allowed and refused to serve; since then bring-up
and retune both allow 10 (`MTS_ATTEMPTS`), and the rerun above locked first
time. Run with `rate_loopback.py`, 2 trials per rate, 2026-10-15 (2ch with
the 2-attempt bring-up).

### A requested rate is met from below, 2026-10-15

UHD `set_rx_rate` / `set_tx_rate` with rates between (and outside) the ones a
template serves: the daemon must serve the highest rate at or below the
request (`coerce_rate`, PROTOCOL.md section 8), retuning in place (MMCM over
DRP, factor, MTS). The expected rate per request was computed from the
template's rate list beforehand; `rate_loopback.py --expect` checks the
served rate and the TX->RX pulse at it.

**33 of 33 requests PASS on the five templates; 27 retunes, MTS locked at
every one (and at 5 bring-ups), first attempt.**

| template | asked -> served (MS/s) |
|---|---|
| 1ch | 2000 -> 1250, 1000 -> 833.333, 700 -> 625, 450 -> 416.667, 400 -> 312.5, 300 -> 250, 200 -> 156.25, 110 -> 104.167, 100 -> 62.5, 50 -> 62.5 |
| 2ch | 1300 -> 1250, 1000 -> 833.333, 600 -> 500, 240 -> 208.333, 70 -> 62.5 |
| 4ch | 800 -> 750, 740 -> 562.5, 500 -> 450, 300 -> 281.25, 200 -> 187.5, 100 -> 93.75, 60 -> 56.25 |
| 8ch | 400 -> 375, 300 -> 281.25, 200 -> 187.5, 150 -> 140.625, 100 -> 93.75, 80 -> 56.25 |
| 16ch | 200 -> 187.5, 180 -> 140.625, 120 -> 112.5, 100 -> 93.75, 60 -> 56.25 |

A request below every rate (1ch: 50) gets the lowest, so only there the
served rate exceeds the request. Reproduce:
`ADDR=<board-ip> DEV_ARGS=channels=4 benchmark/rate_sweep.sh 740e6:562.5e6 300e6:281.25e6 ...`
with the template loaded.

### Bandwidth follows the rate (`rate_bandwidth.py`), 2026-10-15

UHD tones over the air at every rate of the 1ch template and of the 16ch
template, each rate set by a UHD session on the running daemon (in-place
retune; MTS locked at all 17 bring-ups and retunes, first attempt). The RF
tone stays at 950 MHz; only the NCOs move, so the measured response is the
RFDC decimation (RX) and interpolation (TX) filters' at the rate in force.
Criteria (set before): flat within 1 dB to 0.35 x rate, -3 dB edge between
0.38 and 0.5 x rate, RX >= 40 dB down from 0.6 x rate; across rates the
bandwidth in MHz scales with the rate within 5 %.

**17 of 17 rates PASS; the measured bandwidth scales with the rate to
within 0.4 % (1201 MHz at 1250 MS/s down to 54 MHz at 56.25 MS/s).**

| template | MS/s | RX -3 dB bw MHz | TX -3 dB bw MHz | UHD `get_rx_bandwidth` MHz | RX bw / rate | RX stopband dB |
|---|---|---|---|---|---|---|
| 1ch F2 fs2500 | 1250 | 1201.07 | 1204.90 | 1000 | 0.961 | -41.7 |
| | 833.333 | 798.39 | 802.89 | 666.667 | 0.958 | -64.0 |
| | 625 | 600.34 | 602.37 | 500 | 0.961 | -42.7 |
| | 500 | 478.60 | 481.44 | 400 | 0.957 | -68.3 |
| | 416.667 | 399.68 | 401.12 | 333.333 | 0.959 | -46.4 |
| | 312.5 | 300.01 | 301.21 | 250 | 0.960 | -65.4 |
| | 250 | 239.54 | 240.71 | 200 | 0.958 | -70.3 |
| | 208.333 | 199.66 | 200.61 | 166.667 | 0.958 | -49.8 |
| | 156.25 | 150.09 | 150.59 | 125 | 0.961 | -70.8 |
| | 125 | 119.75 | 120.38 | 100 | 0.958 | -69.9 |
| | 104.167 | 99.89 | 100.29 | 83.333 | 0.959 | -75.8 |
| | 62.5 | 59.94 | 60.19 | 50 | 0.959 | -72.1 |
| 16ch F12 fs2250 | 187.5 | 179.77 | 180.63 | 150 | 0.959 | -55.7 |
| | 140.625 | 135.08 | 135.50 | 112.5 | 0.961 | -71.8 |
| | 112.5 | 107.85 | 108.26 | 90 | 0.959 | -76.2 |
| | 93.75 | 89.86 | 90.26 | 75 | 0.959 | -73.2 |
| | 56.25 | 53.90 | 54.15 | 45 | 0.958 | -69.1 |

The response is flat (within the ~0.5 dB point-to-point scatter of the
over-the-air level) to 0.44 x rate, -3 dB at 0.48 x rate, -6 dB at rate/2,
~-25 dB at 0.55 x rate, the same shape at every factor. The UHD column is
what the module reported then (0.8 x rate, the filters' specified passband);
since this measurement it reports the sample rate itself, fs / the factor
(checked on the 1ch template at 1250, 250 and 62.5 MS/s: `get_rx_bandwidth` =
`get_tx_bandwidth` = the rate, `uhd_semantics.py` bandwidth PASS; measured
-3 dB width 1200.22, 239.59, 59.91 MHz). The
stopband column is the level at the alias bin, worst of 0.6-0.7 x rate; there
the spectrum's strongest bin is an unrelated spur, so it is an upper bound on
what leaks through.

### 1ch F2 fs2500 (`zcu216_v49_1ch_qsfp_f2_fs2500`), 2026-10-14

**12 of 12 rates PASS, 1250 to 62.5 MS/s, from one bitstream; MTS locked at
every bring-up and retune (19 of 19).** Down the ladder and back to 1250, then a jumping
sequence (1250, 625, 312.5, 62.5, 500, 1250): each retune 1.0-1.9 s.

| MS/s | F | converter clock MHz (measured) | MTS | pulse dB |
|---|---|---|---|---|
| 1250 | 2 | 312.5 (bring-up) | attempt 1 | 48.5 |
| 833.333 | 3 | 208.3369 | attempt 1 | 46.2 |
| 625 | 4 | 156.2376 | attempt 2 | 48.4 |
| 500 | 5 | 125.0027 | attempt 1 | 62.1 |
| 416.667 | 6 | 104.1593 | attempt 1 | 60.7 |
| 312.5 | 8 | 78.1264 | attempt 1 | 65.6 |
| 250 | 10 | 62.5005 | attempt 1 | 66.6 |
| 208.333 | 12 | 52.0845 | attempt 1 | 64.9 |
| 156.25 | 16 | 39.0630 | attempt 1 | 70.8 |
| 125 | 20 | 31.2504 | attempt 1 | 71.8 |
| 104.167 | 24 | 26.0417 | attempt 1 | 74.9 |
| 62.5 | 40 | 15.6253 | attempt 1 | 79.4 |
| 1250 (back) | 2 | 312.4764 | attempt 1 | 49.4 |

Every measured clock is within 0.02 % of fs/F/4. On this template F=4 is the
one factor whose first MTS attempt failed ("Alignment correction delay 31 required exceeds
maximum (31) for DAC Tile n", with or without a target latency): attempt 2 in
the ladder, attempt 3 in the jumping sequence. Measured
with the predecessor of `rate_loopback.py` (same pulse and criterion, 2
trials per rate).

## SIMD kernels on x86 (AVX-512) and aarch64 (NEON), 2026-10-16

The kernels have two implementations of one algorithm (`../../lib/zcu216_kernels.cpp`):
AVX-512 F + BW on x86, NEON on aarch64, chosen by the host's architecture
(scalar on an x86 without AVX-512). `zcu216_kernel_check` (SIMD against
scalar, every format pair, N = 1..16, edge values) gives 0 mismatches and the
same output digests on both (RX `716ce70cb03059d5`, TX `b44eb762fc46d989`).
`zcu216_kernel_bench`, one thread on wei-duke-wsp5 (GS/s of wire slots), the
former AVX2 kernels -> AVX-512:

| kernel | AVX2 | AVX-512 |
|---|---|---|
| RX sc16 -> fc32 N=1 / 4 / 8 / 16 | 4.51 / 2.52 / 2.99 / 2.88 | 4.13 / 3.42 / 3.62 / 3.58 |
| RX sc16 -> sc16 N=4 | 4.00 | 7.02 |
| RX sc8 -> sc16 / sc8 N=8 | 5.25 / 5.59 | 7.25 / 7.75 |
| RX sc12 -> fc32 N=4 | 1.85 | 2.95 |
| TX fc32 -> sc16 N=1 / 4 / 16 | 5.57 / 3.03 / 2.85 | 6.83 / 6.35 / 4.92 |
| TX sc16 -> sc16 N=4 | 8.72 | 10.22 |
| TX fc32 -> sc12 / sc8 N=4 | 1.85 / 3.96 | 4.19 / 4.94 |
| TX sc8 -> sc8 N=8 | 7.30 | 8.15 |

Strict full-rate duplex (`bench_strict.sh rxtx`, 30 s, every threshold 0), 3
runs per wire format, then the over-the-air TX format check (`otw_tx_ota.py`):

| host / board | build | sc16 | sc8 | OTA |
|---|---|---|---|---|
| wei-duke-wsp5 (AVX-512) / ZCU216 | 1ch 1250 MS/s | 3/3 | 3/3 | pass |
| | 2ch 1250 MS/s | 2/3 | 3/3 | pass |
| | 4ch 750 MS/s | 1/3 | 3/3 | pass |
| | 8ch 375 MS/s | 0/3 | 3/3 | pass |
| | 16ch 187.5 MS/s | 1/3 | 3/3 | pass |
| | sc8max 4ch 1250 MS/s | -- | 3/3 | pass (sc8) |
| | sc8max 8ch 750 MS/s | -- | 0/3 | pass (sc8) |
| | sc8max 16ch 375 MS/s | -- | 0/3 | pass (sc8) |
| DGX Spark (NEON) / RFSoC 4x2 | 1ch 2500 MS/s | 3/3 | 3/3 | pass |
| | 2ch 1250 MS/s | 0/3 (8-10 TX underruns, TX 100.0 %) | 3/3 | pass |

ZCU216 sc16 at 4-16 channels (97 % of the link): every failure is one RX ring
overflow ~0.1 s after the stream starts, clean for the rest of the 30 s, the
NIC missing nothing; the same with the former AVX2 kernels and with Vivado
stopped and 18 GB free, so not the kernels. These builds passed 10/10 on
2026-10-07 (above): a regression since, not yet located (candidates: the IP
changes harvested 2026-10-12, the template bitstreams, the 2026-10-15 host
changes). sc8max 8ch / 16ch (96 Gb/s each way) remain at this PC's limit,
as before. The RFSoC 4x2 2ch sc8max (2 x 2500 MS/s) was still building.

DGX Spark (GB10, 10 x Cortex-X925 + 10 x A725, ConnectX-7, UHD 4.6 /
DPDK 23.11 from Ubuntu arm64), port enp1s0f0np0 forced to 100G CAUI-4 (autoneg
off, lanes 4, RS-FEC) for the RFSoC 4x2: before a DGX OS update its CX-7
transmitted at most ~16 Gb/s per PCIe function (kernel pktgen too, any queue
count; RX at full rate), the known GB10 ConnectX-7 throttle (dmesg
"insufficient power on the PCIe slot (27W)"); after `apt full-upgrade` and a
reboot (kernel 7.0.0-1019-nvidia, CX-7 FW 28.45.4028) pktgen sends 98-99.6
Gb/s. The module's layout puts the app (5, 8), the lcores (6, 7) and the
workers (9, 15-19) on the X925 cores.

## Defects found and fixed during these measurements

| symptom | cause | fix |
|---|---|---|
| a session's first receive one packet short, or a gap (`ERROR_CODE_OVERFLOW`) | `udp_streamer` kept its destination-port counter across sessions | the daemon zeroes it at every stream setup (d7efc1989) |
| receive packet size 2016 instead of 2048 after an sc12 client | the daemon's `spp` survived the client session | reset on release (75f30e22e) |
| underflow just after a timed start | the TX conversion workers were asleep after the wait for the start | TX warm-up at stream creation, keep-warm during credit waits (1344918c4) |
| 16-channel over-the-air test: receive gap, TX underflow | the tool ran without the full-rate CPU layout, and its TX burst exceeded the FPGA buffer | `oracle.sh` passes the layout; `otw_tx_ota.py` sizes the burst to the buffer (4d8465686) |

MTS was locked for every measurement here (`hw_design/ZCU216/CLAUDE.md`: no
measurement without it). Since 0c7b32de4 the daemon also runs, checks and logs
it at every load (`[m] MTS LOCKED`, sensor `mts_locked`); repeated with that
check, 2026-10-07: 4ch F3 sc16 full-rate duplex 30 s PASS, over the air 4ch F4
PASS (tone 73.6 dB above the noise bin), locked on the first attempt on all 12
loads.

Not re-measured on these bitstreams: the `compliance` (stock UHD examples) and `beamforming` (4T4R phase calibration) suites of `oracle.sh`.

Reproduce sc8max: `sudo -E env PATH=$PATH ADDR=<board-ip> RUNS=10 DUR=30 benchmark/oracle.sh robustness sc8max`
(it runs the sc8 over-the-air check).
