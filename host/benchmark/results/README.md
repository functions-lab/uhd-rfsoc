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
