# benchmark — tests on the real board + PC

Run on the PC through the wrapper (`zcu216-uhd`, root) against a running
daemon; `loopback_test.py` runs on the board.

## The oracle

`oracle.sh` is the project's test oracle: three suites, measured on the real
board and reported as measured (`oracle_builds.txt` lists the ZCU216 builds,
`oracle_builds_rfsoc4x2.txt` the RFSoC 4x2 ones). It drives the board over
ssh (passwordless, as the user who ran sudo) and restarts its daemon with
each build's bitstream, so the bitstreams must already be in the board's
checkout (`rfsoc/push_bitstreams.sh <bitstream dir> <ssh target>`) and
nothing else may use the board during the run. From `host/`:

```
sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> benchmark/oracle.sh robustness|compliance|beamforming|all [filter]
sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> BUILDS=oracle_builds_rfsoc4x2.txt benchmark/oracle.sh robustness
```

`BOARD` (the ssh target) is required; `ADDR` defaults to the one board
discovery finds, `BOARD_DIR` to `/home/xilinx/jupyter_notebooks/rfsoc-uhd`.
`RUNS`, `DUR`, `FREQ`, `LAYOUT`, `APP_CPUS`, `ISOLATE` and `OUT` are listed
in the script's header. The default `LAYOUT` / `APP_CPUS` are the full-rate
duplex layout of `../AGENTS.md` for a 6-core / 12-thread host: adapt them to
yours.

| suite | what | pass |
|---|---|---|
| robustness | per build x wire format it carries: RUNS (default 10) strict full-rate simultaneous TX+RX runs of DUR (30) s through the DACs and ADCs; then `otw_tx_ota.py`, every TX wire format against sc16 over the air (sc8-only builds: TX sc8 from fc32 and sc16 buffers, captured in sc8) | a run: no dropped sample, overflow, underrun, sequence error or late packet. Reported per case as "x / RUNS runs with TX underruns", "x / RUNS with RX loss"; each run keeps its own log (`<OUT>/bench/<bitstream>_r<N>/`). OTA: amplitude and phase vs the reference within 0.5 dB / 5 deg (sc8: 1 dB / 10 deg), no TX error event |
| compliance | `uhd_examples_hw.sh`: every stock UHD example that applies, unmodified | its PASS lines; N/A (with the reason) for an example a build cannot run, e.g. one that hard-codes otw sc16 on an sc8-only build |
| beamforming | 4T4R over the air on the 4-channel builds: `phase_cal.py calibrate` (null search), `phase_cal.py verify`, `bf_air_test.py` (TX), `rx_bf_air_test.py` (RX) | verify: every residual offset within 10 deg and coherent gain >= 0.9, TX and RX; the two beamformer tests' own criteria |

The run ends with a table per (build, wire format): runs, clean runs, runs
with TX underruns, runs with RX loss; the exit code is the number of failed
items. `classify_runs.py [log root]` sorts the per-run logs into clean / cold
start (a one-off loss in the first second, then a clean stream: does not
count) / failures to sustain the rate.

Without a board: `../build/zcu216_kernel_check` (the SIMD kernels against the
scalar ones, bit for bit), `../build/zcu216_kernel_bench` (kernel and pool
throughput), `../build/zcu216_dram_bench` (x86 only: host data path vs DRAM)
and the FPGA simulations (`../../fpga_ip/ip_design/uhd_ip/sim`).

| script | measures |
|---|---|
| `oracle.sh`, `oracle_builds.txt` | the three suites above, over the builds |
| `uhd_examples_hw.sh` | every applicable stock UHD example (C++, C API, Python) against the real board, bit-exact RX captures; lists the examples that do not apply |
| `bench_strict.sh` | one strict `benchmark_rate` run (all error thresholds 0) → PASS/FAIL line |
| `classify_runs.py` | per-run logs → clean / cold start / sustain failure per build, with when each loss began |
| `dpdk_rx_test.sh` | real-link check: probe, full-rate RX/TX, bit-exact capture |
| `otw_rx_check.py`, `otw_tx_ota.py`, `otw_ctl_refusal.py` | FPGA wire-format converters (RX bit-exact, TX over the air, refusals) |
| `tx_start_test.py` | TX start-of-stream underflows |
| `rate_sweep.sh`, `rate_loopback.py` | run-time rate change on a template build: per rate the in-place retune, then a TX->RX pulse at it |
| `rate_bandwidth.py` | the RX / TX filter response at a rate with UHD tones over the air (fixed RF tone, NCO sweep); `--compare` checks the bandwidth scales with the rate |
| `bf_air_test.py`, `rx_bf_air_test.py` | TX / RX beamformer over the air |
| `bf_cal_sweep.py` | channel phase offsets with the beamformers (power sweep), calibration |
| `phase_matrix_ota.py`, `bf_phase_ota.py`, `phase_check.py` | NTNR phase matrix, NT1R/1TNR offsets, phase after retune |
| `phase_cal.py` | `calibrate`: per-channel TX/RX phase calibration by the ArrayCalibTask null search (`--method null`, default; `peak`, `matrix`); `verify`: residual offsets and coherent gain with it loaded in the beamformers |
| `phase_loads_report.py` | load-to-load consistency of the offsets over many `phase_matrix_ota.py --save` runs |
| `loopback_test.py` | board-only GT loopback throughput (no PC) |

```
zcu216-uhd python3 benchmark/bf_cal_sweep.py --args type=zcu216,addr=<board-ip>,channels=4
ADDR=<board-ip> DEV_ARGS=channels=8 benchmark/bench_strict.sh rxtx 312.5e6 8 sc16 sc16
```
