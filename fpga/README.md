# fpga — the bitstreams

One build flow for every board: `boards/<board>/` holds what is
board-specific, `flow/` builds it, `make` drives it.

| board | `BOARD=` | channels N | converter rates fs (MS/s) | templates |
|---|---|---|---|---|
| AMD ZCU216 | `zcu216` | 1, 2, 4, 8, 16 | 2500, 2457.6, 2400 | 15 |
| Real Digital RFSoC 4x2 | `rfsoc4x2` | 1, 2 | 5000, 4915.2, 4800 | 6 |

A **template** is the top-rate build of one channel count at one fs. At run
time the board's daemon retunes it to every lower rate, so the templates
alone cover every rate.

A bitstream is named `<board>_v49_<N>ch_qsfp_f<F>_fs<fs>.bit`, with a `.hwh`
next to it: N channels, RFDC factor F, converter rate fs in MS/s (decimal
point written `p`, e.g. `fs2457p6`).

## Prerequisites

- Linux x86_64 with Vivado on PATH, in the release that matches the PYNQ
  version you build for (next section). If `vivado -version` shows another
  one, run `source <Vivado install>/<release>/settings64.sh`. `make` checks.
- The no-charge AMD license for the **UltraScale+ Integrated 100G Ethernet
  Subsystem** (`cmac_usplus`), installed for Vivado. Without it,
  implementation fails.
- Per build running at once: about 16 GB of RAM and 15 GB of free disk.

Nothing gets installed: the RFSoC 4x2's board files are in
`boards/rfsoc4x2/board_files/`, the ZCU216's ship with Vivado.

## PYNQ versions

Each PYNQ image needs bitstreams built with one Vivado release
(`make versions` prints this table from `flow/versions.txt`):

| PYNQ | Vivado | `make` option | outputs | prebuilt set |
|---|---|---|---|---|
| 2.7 | 2021.1 | (default) | `build/<board>/` | `bitstreams/pynq2.7/<board>/` |
| 3.0 | 2022.1 | `PYNQ=3.0` | `build/pynq3.0/<board>/` | `bitstreams/pynq3.0/<board>/` |
| 3.1 | 2024.1 | `PYNQ=3.1` | `build/pynq3.1/<board>/` | `bitstreams/pynq3.1/<board>/` |

The prebuilt sets all come from
[uhd-rfsoc-bitstream](https://github.com/functions-lab/uhd-rfsoc-bitstream), the `bitstreams/`
submodule at the top of the repository. Each of its releases also has one
zip per set, `uhd-rfsoc-bitstreams-<board>-pynq<version>.zip`.

The file names are the same for every PYNQ version, so keep each version's
builds in their own directory and install the set that matches the board's
image. Background: `AGENTS.md`, "PYNQ versions".

## Build

From this directory:

```sh
make BOARD=zcu216 templates             # the ZCU216's 15 templates (PYNQ 2.7)
make BOARD=rfsoc4x2 templates           # the RFSoC 4x2's 6 templates
make BOARD=zcu216 PYNQ=3.0 templates    # for PYNQ 3.0 (Vivado 2022.1 on PATH)
make BOARD=zcu216 list                  # every build: built, TIMING-FAIL or - (not built)
```

A template takes about 25 minutes on a 12-core machine. By default two
builds run at once (`MAXPAR=2`) with 6 threads each (`JOBS=6`).

| target or option | what it does |
|---|---|
| `make BOARD=<b> templates [FS=<fs>]` | the templates (only those of one fs with `FS=`) |
| `make BOARD=<b> bitstream N=<n> [F=<f>] [FS=<fs>]` | one build; F defaults to the template's, fs to the board's first |
| `make BOARD=<b> ladder` | every build in `boards/<b>/builds.txt`, fixed-factor ones too (days) |
| `make BOARD=<b> list` | the state of every build |
| `make BOARD=<b> clean` | delete the build directory |
| `make package` | repackage the custom cores; only after a change in `ip/src/uhd_ip/` |
| `make help` | every target and option |
| `PYNQ=<v>` | build for that PYNQ version, with its Vivado release |
| `STEP=bd` | stop after the block design: checks a design in minutes |
| `SKIP_EXISTING=1` | skip builds already in `bitstreams/` |
| `BUILD_DIR=<dir>` | put the outputs (and the Vivado projects) there |
| `V49_KEEP_PROJ=1` | keep each build's Vivado project (deleted otherwise) |

The RFSoC 4x2 has one extra build, sc8max (2 channels at 2500 MS/s each, sc8
only): `make BOARD=rfsoc4x2 bitstream N=2 F=2`.

### Outputs

In `build/<board>/` (`build/pynq<v>/<board>/` with `PYNQ=<v>`):

| path | what |
|---|---|
| `bitstreams/<name>.{bit,hwh}` | the builds that met timing, with their timing and utilization reports: **deploy these** |
| `bitstreams_timing_fail/` | builds that missed timing: never deploy these |
| `logs/<name>.log` | one log per build |

`templates` and `ladder` end with one summary line per build (`OK`, `TIMING`
or `FAILED`) and exit non-zero unless every build is `OK`.

## Install on a board

From the top of the repository, with the board already set up
(`../rfsoc/README.md`):

```sh
rfsoc/push_bitstreams.sh fpga/build/<board>/bitstreams xilinx@<board-ip>            # your build, PYNQ 2.7 image
rfsoc/push_bitstreams.sh fpga/build/pynq3.0/<board>/bitstreams xilinx@<board-ip>    # your build, PYNQ 3.0 image
rfsoc/push_bitstreams.sh bitstreams/pynq3.1/<board> xilinx@<board-ip>               # a prebuilt set
```

To publish a new prebuilt set, commit it to the `bitstreams/` submodule as
`pynq<v>/<board>/` (only builds that met timing, with their reports, a
regenerated `manifest.json` and `SHA256SUMS`), then bump the submodule here.

## Add a board

The board needs:

- an RFSoC with RF data converters;
- an LMK04828 + LMX2594 clock chain (or new register files and clock code in
  `rfsoc/rfsoc_lib`);
- a 100G port on GTY lanes that `ip/src/cmac_100g` can drive.

Steps:

1. `boards/<board>/board.tcl`: copy an existing one and fill in the part,
   board part, clock families, link and pin tie-offs. Every variable is
   commented.
2. `boards/<board>/block_designs/<board>_uhd_v49[_245m76]/`: one `.tcl` +
   `.xdc` per clock family (250 MHz and 245.76 MHz: Protocol §8a in the top
   `AGENTS.md`), adapted from the closest board (channel map, pins, the
   geometry table `v49_geometry`). Keep the PS address map.
3. `boards/<board>/builds.txt`: the templates, and any fixed-factor builds.
4. `rfsoc/rfsoc_lib/xrfclk/<board_xrfclk>/`: the LMK04828 / LMX2594 register
   files for each fs. The flow picks the clock family from them.
5. Check with `make BOARD=<board> bitstream N=1 STEP=bd`, then build.
6. The software side: a `Board` entry in `rfsoc/server/boards.py`.

The design rules are in `AGENTS.md`.
