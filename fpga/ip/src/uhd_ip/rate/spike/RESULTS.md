# Gate 0: FIR Compiler stages (fir_spike.tcl)

Out-of-context synthesis, xczu49dr-ffvf1760-2-e, 3.2 ns (312.5 MHz), FIR
Compiler 7.2. `fir_spike.sh <release> <out> [dir:p:paths ...]`.

## First architecture (rejected): FIR Compiler decimators / interpolators

Integer-rate ÷2 / ×2 cores with the 51-tap half-band. Half-band structure is
refused above one sample per clock (super sample rate), and there the core
spends ~51 multipliers per output sample (the zeros and the symmetry are not
used):

| dir | p (samples/clock) | paths | DSP | WNS (ns) |
|---|---|---|---|---|
| rx | 8 | 2 | 208 | 0.738 |
| rx | 4 | 2 | 104 | 1.241 |
| rx | 2 | 2 | 52 | 1.602 |
| rx | 1 (half-band) | 2 | 14 | 2.027 |
| rx | 0.5 (half-band) | 2 | 8 | 2.141 |
| tx | 8 | 2 | 208 | 0.759 |
| rx | 4 | 16 | 832 | -0.949 |
| tx | 4 | 16 | 1024 | -1.297 |

The RFSoC 4x2 2ch (8 samples per clock) would have exceeded the budget.

## Chosen: the polyphase odd branch (rate_sr_cfg, 32 taps symmetric)

2021.1:

| p (samples/clock/path) | paths | DSP | WNS (ns) |
|---|---|---|---|
| 4 | 2 | 128 | 1.117 |
| 2 | 2 | 64 | 1.513 |
| 1 | 2 | 32 | 1.799 |
| 0.5 | 2 | 16 | 1.998 |
| 0.25 | 2 | 8 | 2.146 |
| 0.125 | 2 | 4 | 2.235 |
| 1/16, 1/32, 1/64 | 2 | 2 | 2.246 |

16 DSP per path per sample per clock (16 multipliers: the symmetric 32 taps),
at least one per path. BRAM 0. A design's chains (RX + TX, every stage,
2 N_CH paths):

| design | SPC | K | DSP (RX + TX) | of 4272 |
|---|---|---|---|---|
| ZCU216 1ch | 4 | 5 | 248 | 6 % |
| ZCU216 2ch | 4 | 5 | 496 | 12 % |
| ZCU216 4ch | 4 | 5 | 992 | 23 % |
| ZCU216 8ch | 2 | 5 | 992 | 23 % |
| ZCU216 16ch | 1 | 5 | ~1000 | 23 % |
| RFSoC 4x2 1ch | 8 | 6 | 504 | 12 % |
| RFSoC 4x2 2ch (4915.2 / 4800) | 8 | 6 | 1008 | 24 % |
| RFSoC 4x2 2ch (5000) | 4 | 6 | 504 | 12 % |

Gate 0 DSP / BRAM: **pass** (<= 1500 DSP, <= 10 % BRAM). Whole designs:
the template builds' utilization reports.

## Every release

`fir_compiler:7.2` is current in 2021.1, 2022.1 and 2024.1 (`rate_sr_cfg`
generates in each). The chain sims with each release's own FIR Compiler
models (`RATE_TAG=v<rel> VIVADO_ROOT=... GEOMS="1:4:5:1 2:8:6:1"
sim/run_sim_rate.sh`, RX and TX, every depth): bit-exact against
`check_rate.py` in all three, no stall, no DAC underrun — the cores pad and
delay alike (2021.1 runs all eight geometries: `make sim-rate`).
Whole-design timing per release: the template builds.
