# benchmark — tests on the real board + PC

Everything here needs a board with its daemon serving and the 100G link up;
the scripts run on the PC through the wrapper (`uhd-rfsoc`, root), except
`loopback_test.py`, which runs on the board. Without a board, the host-side
checks are in `../tools/` (`rfsoc_kernel_check`, the benches). From `host/`:

```sh
benchmark/dpdk_rx_test.sh                                   # first check of a new link: probe, RX, bit-exact capture, TX
ADDR=<board-ip> DEV_ARGS=channels=8 benchmark/bench_strict.sh rxtx 312.5e6 8 sc16 sc16
uhd-rfsoc python3 benchmark/rate_bandwidth.py --args type=rfsoc,addr=<board-ip>,channels=4 --rate 625e6
```

## Which script for what

| want to check | run |
|---|---|
| the link and the module work at all | `dpdk_rx_test.sh`: probe, `benchmark_rate` RX at 1.25 GS/s, a 100 M-sample bit-exact capture of the test pattern, a timed TX burst, ARP still working |
| one rate, one direction, strictly | `bench_strict.sh <rx\|tx\|rxtx> <rate> [nchan] [cpu] [otw]`: one `benchmark_rate` run with every error threshold 0 and >= 99 % of the nominal samples, one PASS/FAIL line |
| every stock UHD example against the board | `uhd_examples_hw.sh` (C++, C API and Python examples, unmodified; RX captures bit-exact; lists the examples that do not apply) |
| the FPGA's wire-format converters | `otw_rx_check.py` (RX, bit-exact against the pattern), `otw_tx_ota.py` (TX, every format against sc16 over the air), `otw_ctl_refusal.py` (the daemon refuses a format a build cannot carry) |
| a run-time rate change | `rate_sweep.sh <rate>...` (per rate: the in-place retune, then `rate_loopback.py`, a TX->RX pulse at it); `rate_bandwidth.py` (the RFDC filter response at a rate; `--compare` shows the bandwidth scaling with the rate) |
| TX start-up behaviour | `tx_start_test.py` (underflows at the start of untimed and timed streams) |
| the beamformers over the air (channels 0-3 cabled as a 4T4R link) | `bf_air_test.py` (TX), `rx_bf_air_test.py` (RX), `bf_cal_sweep.py` (phase offsets measured with the beamformers), `phase_cal.py calibrate` / `verify` (per-channel calibration and its residual) |
| inter-channel phase | `phase_matrix_ota.py` (the NxN matrix; `--save` / `--compare` across reloads), `bf_phase_ota.py` (NT1R / 1TNR offsets, beam sweep), `phase_check.py` (does the phase survive a retune, Protocol §3d), `phase_loads_report.py` (offsets across bitstream loads) |
| the whole project, as measured | `oracle.sh` (below) |
| the FPGA data plane alone, on the board | `loopback_test.py` (GT loopback, no PC; after `rfsoc/server/bringup.py --loopback`) |
| sort a run's logs | `classify_runs.py [log root]`: clean / cold start / failure to sustain the rate, per build |

Each script's header says its arguments, environment variables and pass
criteria; `ADDR` defaults to the one board discovery finds.

## The oracle

`oracle.sh` is the project's test oracle: three suites, measured on the real
board and reported as measured. It drives the board over ssh (passwordless,
as the user who ran sudo) and restarts its daemon with each build's bitstream
through the board's `run_daemon.sh`, so the bitstreams must already be in the
board's checkout (`rfsoc/push_bitstreams.sh <bitstream dir> <ssh target>`)
and nothing else may use the board during the run.

```sh
sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> benchmark/oracle.sh robustness|compliance|beamforming|all [filter]
sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> BUILDS=oracle_builds_rfsoc4x2.txt benchmark/oracle.sh robustness
```

`BOARD` (the ssh target) is required; `ADDR` defaults to the board discovery
finds, `BOARD_DIR` to `/home/xilinx/jupyter_notebooks/uhd-rfsoc`. `BUILDS`
lists the builds (`oracle_builds.txt`: the ZCU216, `oracle_builds_rfsoc4x2.txt`:
the RFSoC 4x2; one line per build and rate with its wire formats). `RUNS`,
`DUR`, `FREQ`, `LAYOUT`, `APP_CPUS`, `HK_CPUS`, `ISOLATE` and `OUT` are in
the script's header. The default `LAYOUT` / `APP_CPUS` / `HK_CPUS` are the
full-rate duplex layout of `../AGENTS.md` for a 6-core / 12-thread host:
adapt them to yours.

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
