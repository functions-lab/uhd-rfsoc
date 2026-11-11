# benchmark — tests on the real board + PC

Everything here needs a board with its daemon serving and the 100G link up.
The scripts run on the PC, as root through the wrapper (`uhd-rfsoc`); only
`loopback_test.py` runs on the board. Checks that need no board are in
`../tools/`.

From `host/`:

```sh
benchmark/dpdk_rx_test.sh        # first check of a new link: probe, RX, bit-exact capture, TX
ADDR=<board-ip> DEV_ARGS=channels=8 benchmark/bench_strict.sh rxtx 312.5e6 8 sc16 sc16
uhd-rfsoc python3 benchmark/rate_bandwidth.py --args type=rfsoc,addr=<board-ip>,channels=4 --rate 625e6
```

Each script's header gives its arguments, environment variables and pass
criteria. `ADDR` defaults to the one board discovery finds.

## Which script for what

**The basics**

| to check | run |
|---|---|
| the link and the module work at all | `dpdk_rx_test.sh`: probe, `benchmark_rate` RX at 1.25 GS/s, a 100 M-sample bit-exact capture of the test pattern, a timed TX burst |
| one rate, strictly | `bench_strict.sh <rx\|tx\|rxtx> <rate> [nchan] [cpu] [otw]`: one `benchmark_rate` run that passes only with zero errors and >= 99 % of the samples |
| every stock UHD example | `uhd_examples_hw.sh`: the C++, C API and Python examples, unmodified |
| the whole project | `oracle.sh` (below) |

**Wire formats and rates**

| to check | run |
|---|---|
| the FPGA's wire-format converters, RX | `otw_rx_check.py`: bit-exact against the test pattern |
| the same, TX | `otw_tx_ota.py`: every format against sc16, over the air |
| a format a build cannot carry is refused | `otw_ctl_refusal.py` |
| a run-time rate change | `rate_sweep.sh <rate>...`: per rate, the retune, then a TX->RX pulse (`rate_loopback.py`) |
| the bandwidth at a rate | `rate_bandwidth.py`: the filter response; `--compare` shows it scaling with the rate |
| TX start-up | `tx_start_test.py`: underflows at the start of untimed and timed streams |

**Beamforming and phase** (channels 0-3 cabled as a 4T4R link)

| to check | run |
|---|---|
| the beamformers over the air | `bf_air_test.py` (TX), `rx_bf_air_test.py` (RX) |
| phase calibration | `phase_cal.py calibrate` / `verify`; `bf_cal_sweep.py` (offsets measured with the beamformers) |
| inter-channel phase | `phase_matrix_ota.py` (the NxN matrix; `--save` / `--compare` across reloads), `bf_phase_ota.py` (offsets, beam sweep) |
| phase across a retune or reload | `phase_check.py` (retune, Protocol §3d), `phase_loads_report.py` (bitstream loads) |

**Other**

| to check | run |
|---|---|
| the FPGA data plane alone, on the board | `loopback_test.py`: transceiver loopback, no PC (after `rfsoc/server/bringup.py --loopback`) |
| sort a run's logs | `classify_runs.py [log root]`: clean, cold start, or failure to sustain the rate, per build |

## The oracle

`oracle.sh` is the project's test oracle: three suites, measured on the real
board and reported as measured.

```sh
sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> benchmark/oracle.sh robustness|compliance|beamforming|all [filter]
sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> BUILDS=oracle_builds_rfsoc4x2.txt benchmark/oracle.sh robustness
```

Before a run:

- **It takes the board over.** It restarts the board's daemon with each
  build's bitstream, over passwordless ssh. Nothing else may use the board
  meanwhile.
- **The bitstreams must already be on the board**
  (`rfsoc/push_bitstreams.sh`).
- **Adapt the CPU layout to your host.** The defaults of `LAYOUT`,
  `APP_CPUS` and `HK_CPUS` are for a 6-core / 12-thread host (`../AGENTS.md`,
  "Full-rate duplex").

| variable | meaning | default |
|---|---|---|
| `BOARD` | the board's ssh target (required) | |
| `ADDR` | the board's LAN address | the one board discovery finds |
| `BOARD_DIR` | the board's checkout | `/home/xilinx/jupyter_notebooks/uhd-rfsoc` |
| `BUILDS` | the list of builds, rates and wire formats | `oracle_builds.txt` (ZCU216); `oracle_builds_rfsoc4x2.txt` for the RFSoC 4x2 |
| `RUNS`, `DUR` | runs per case, seconds per run | 10, 30 |

The others (`FREQ`, `LAYOUT`, `APP_CPUS`, `HK_CPUS`, `ISOLATE`, `OUT`) are
in the script's header.

### The suites

**robustness** — for every build and every wire format it carries:

- `RUNS` strict runs of simultaneous full-rate TX + RX through the DACs and
  ADCs. A run passes with no dropped sample, overflow, underrun, sequence
  error or late packet.
- Then `otw_tx_ota.py`: every TX wire format against sc16 over the air.
  Passes with amplitude and phase within 0.5 dB / 5 deg of the reference
  (sc8: 1 dB / 10 deg) and no TX error event.

**compliance** — `uhd_examples_hw.sh`: every stock UHD example that
applies, unmodified. An example a build cannot run is reported N/A with the
reason (e.g. one that hard-codes sc16 on an sc8-only build).

**beamforming** — 4T4R over the air on the 4-channel builds:
`phase_cal.py calibrate` and `verify`, `bf_air_test.py`, `rx_bf_air_test.py`.
`verify` passes with every residual offset within 10 deg and a coherent gain
>= 0.9, TX and RX; the two beamformer tests have their own criteria.

### Results

The run ends with a table per build and wire format: runs, clean runs, runs
with TX underruns, runs with RX loss. The exit code is the number of failed
items. Each run keeps its own log under `OUT`
(`<OUT>/bench/<bitstream>_r<N>/`).

`classify_runs.py [log root]` sorts those logs into:

- **clean**;
- **cold start**: a one-off loss in the first second, then a clean stream.
  Does not count as a failure;
- **failure to sustain the rate**.
