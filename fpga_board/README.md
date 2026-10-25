# fpga_board — the FPGA builds, one directory per board

| directory | board | channel counts N | clock families (fs, MS/s) |
|---|---|---|---|
| `zcu216/` | Xilinx ZCU216 | 1, 2, 4, 8, 16 | 250 MHz: 2500 · 245.76 MHz: 2457.6 |
| `rfsoc4x2/` | Real Digital RFSoC 4x2 | 1, 2 | 250 MHz: 5000 · 245.76 MHz: 4915.2 |

Each board directory holds one self-contained block design per clock family
(`block_designs/<board>_uhd_v49/` and `<board>_uhd_v49_245m76/`, each a
`.tcl` + `.xdc` parameterised by channel count N, RFDC factor F and
converter rate fs), the build script `scripts/v49_build.tcl`, the ladder
script `scripts/v49_ladder.sh` and a `Makefile` with the targets below.
`FS=` picks the family; `N` and `F` the build.

## Prerequisites

- Vivado 2021.1 on PATH (`source <Vivado>/settings64.sh`). The ZCU216 board
  part ships with Vivado; the RFSoC 4x2's is vendored in
  `rfsoc4x2/board_files/` and found automatically. Nothing is installed.
- The custom cores packaged once: `make -C zcu216 v49-package` (or
  `-C rfsoc4x2`; both run `make package` in `../fpga_ip/ip_design/uhd_ip`).
- Disk for the Vivado project of each build (several GB, deleted once the
  bitstream is out); `v49-ladder` / `v49-templates` run up to `MAXPAR`
  builds at once and start the next only with `MIN_FREE_GB` (12) free.

## Build

```sh
make -C zcu216   v49-package                      # once: ../fpga_ip/ip_design/uhd_ip -> ../fpga_ip/ip/uhd_ip
make -C zcu216   v49-templates                    # the 5 ZCU216 templates: 1/2/4ch F2, 8ch F4, 16ch F8 at fs 2500
make -C zcu216   v49-templates-245m76             # the same five at fs 2457.6
make -C rfsoc4x2 v49-templates                    # the RFSoC 4x2's two: 1ch F2, 2ch F4 at fs 5000
make -C rfsoc4x2 v49-templates-245m76             # 1ch F2, 2ch F2 at fs 4915.2
make -C zcu216   v49 N=8 F=4 FS=2500 [STEP=bd]    # one build (STEP=bd: block design only, minutes)
make -C zcu216   v49-ladder [MAXPAR=3] [JOBS=8]   # every fixed-factor build of host/benchmark/oracle_builds.txt
```

Every build is a run-time-rate template (Protocol §8 in the top
`AGENTS.md`): the daemon retunes it in place to every RFDC factor above the
built one, so the templates alone cover every rate of their family; the
per-factor ladder exists for fixed-rate comparisons. `make v49` accepts
`STEP=bd|synth|bit`, `JOBS=<threads>`, `STRATEGY=<Vivado impl strategy>`;
`V49_KEEP_PROJ=1` in the environment keeps the Vivado project (several GB)
after the build.

Output: `<board>/build/v49_qsfp/bitstreams/<board>_v49_<N>ch_qsfp_f<F>_fs<fs>.{bit,hwh}`
plus timing and utilization reports (fs with its decimal point as `p`:
`_fs2457p6`); a build that misses timing lands in `bitstreams_timing_fail/`
instead. Logs of the ladder scripts: `build/v49_qsfp/logs/`. Copy a
bitstream directory to the board with `rfsoc/push_bitstreams.sh <dir>
xilinx@<board>` (from the top of the repository).

Design rules and board facts: `AGENTS.md` here and in each board directory.
