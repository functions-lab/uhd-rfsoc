# fpga — the bitstreams

One build flow for every board: `boards/<board>/` says what is
board-specific, `flow/` builds it, `make` drives it. A bitstream is
`<board>_v49_<N>ch_qsfp_f<F>_fs<fs>.bit` + `.hwh` (N channels, RFDC factor F,
converter rate fs in MS/s, its decimal point as `p`).

| board | `BOARD=` | channels N | clock families (fs, MS/s) | templates |
|---|---|---|---|---|
| AMD ZCU216 | `zcu216` | 1, 2, 4, 8, 16 | 2500, 2400 (250 MHz); 2457.6 (245.76 MHz) | 15 |
| Real Digital RFSoC 4x2 | `rfsoc4x2` | 1, 2 | 5000, 4800 (250 MHz); 4915.2 (245.76 MHz) | 6 |

## Prerequisites

- Linux x86_64 with the **Vivado release of the PYNQ version** you build
  for on PATH (table below; 2021.1 by default): `vivado -version` must say
  it, else `source <Vivado install>/<release>/settings64.sh` (`make` checks
  it).
- The no-charge AMD license for the **UltraScale+ Integrated 100G Ethernet
  Subsystem** (`cmac_usplus`), installed for Vivado (e.g.
  `~/.Xilinx/<host>.lic`). Without it implementation fails.
- Per build running at once: ~16 GB RAM and ~15 GB free disk (`MAXPAR=1`
  runs one build at a time; the next starts only with 12 GB of disk free).

The RFSoC 4x2's board files are in `boards/rfsoc4x2/board_files/`; the
ZCU216's ship with Vivado. Nothing gets installed.

## PYNQ versions

The bitstreams are built per PYNQ image, each with one Vivado release
(`flow/versions.txt`, the single mapping; `make versions` prints it):

| PYNQ | Vivado | `make ... PYNQ=` | outputs | prebuilt (`bitstreams/` submodule) | release asset |
|---|---|---|---|---|---|
| 2.7 | 2021.1 | (default) | `build/<board>/` | `bitstreams/pynq2.7/<board>/` | `uhd-rfsoc-bitstreams-<board>-pynq2.7.zip` |
| 3.0 | 2022.1 | `PYNQ=3.0` | `build/pynq3.0/<board>/` | `bitstreams/pynq3.0/<board>/` | `uhd-rfsoc-bitstreams-<board>-pynq3.0.zip` |
| 3.1 | 2024.1 | `PYNQ=3.1` | `build/pynq3.1/<board>/` | `bitstreams/pynq3.1/<board>/` | `uhd-rfsoc-bitstreams-<board>-pynq3.1.zip` |

PYNQ 2.7's own release is 2020.2; its bitstreams are the 2021.1 builds the
boards run today. The file names inside are the same for every PYNQ
version (the daemon needs them so), so keep each version's builds in
their own directory and install the set that matches the board's image.
`AGENTS.md` ("PYNQ versions") says what ties a bitstream to a PYNQ version
and what a new one needs.

## Build

From this directory:

```sh
make BOARD=zcu216 templates             # the ZCU216's 15 templates (PYNQ 2.7, Vivado 2021.1)
make BOARD=rfsoc4x2 templates           # the RFSoC 4x2's 6 templates
make BOARD=zcu216 PYNQ=3.0 templates    # for PYNQ 3.0 (Vivado 2022.1 on PATH)
make BOARD=zcu216 list                  # every build of the board: built, TIMING-FAIL or - (not built)
```

The custom cores come packaged (`ip/repo/`, in git); `make package`
repackages them, needed only after a change to their sources
(`ip/src/uhd_ip/`; it also updates the packages' timestamps in git).

The RFSoC 4x2 has one extra build, sc8max (2 channels at 2 x 2500 MS/s in
sc8): `make BOARD=rfsoc4x2 bitstream N=2 F=2`.

A template is a channel count's top build at an fs. At run time the board's
daemon retunes it to every lower RFDC factor, so the templates alone cover
every rate (each about 25 min on a 12-core machine; `MAXPAR=2` builds run at
once, `JOBS=6` threads each). `make help` lists every target and option.

| | |
|---|---|
| `make BOARD=<b> templates [FS=<fs>]` | the templates (of one fs with `FS=`) |
| `make BOARD=<b> bitstream N=<n> [F=<f>] [FS=<fs>]` | one build (default F: the template's; default fs: the board's first family) |
| `make BOARD=<b> ladder` | every build in `boards/<b>/builds.txt`, the fixed-factor ones too (days) |
| `STEP=bd` | block design only: checks a design in minutes |
| `SKIP_EXISTING=1` | skip builds already in `bitstreams/` |
| `PYNQ=<v>` | build for that PYNQ version, with its Vivado release (above) |
| `BUILD_DIR=<dir>` | outputs (and the Vivado projects) there instead |
| `make BOARD=<b> clean` | delete the build directory (`build/<b>/`, or that of `PYNQ=`) |

Outputs, in `build/<board>/` (`build/pynq<v>/<board>/` for `PYNQ=<v>`):

- `bitstreams/<name>.{bit,hwh}` and its timing and utilization reports: the
  builds that met timing, the ones to deploy;
- `bitstreams_timing_fail/`: builds that missed timing (never deploy these);
- `logs/<name>.log`: one per build. `templates` and `ladder` end with a
  summary, one line per build (`OK`, `TIMING` or `FAILED`), and exit non-zero
  if any build is not `OK`.

The Vivado project of each build is deleted once its bitstream is out
(`V49_KEEP_PROJ=1` keeps it).

## Install on a board

From the top of the repository, with the board's checkout already set up
(`../rfsoc/README.md`):

```sh
rfsoc/push_bitstreams.sh fpga/build/<board>/bitstreams xilinx@<board-ip>             # PYNQ 2.7 image
rfsoc/push_bitstreams.sh fpga/build/pynq3.0/<board>/bitstreams xilinx@<board-ip>     # PYNQ 3.0 image
rfsoc/push_bitstreams.sh bitstreams/pynq3.1/<board> xilinx@<board-ip>                # the prebuilt set
```

A new prebuilt set goes into the `bitstreams/` submodule as
`pynq<v>/<board>/` (only builds that met timing, with their reports, a
regenerated `manifest.json` and `SHA256SUMS`), then the submodule is bumped
here.

## Add a board

A board needs an RFSoC with RF data converters, an LMK04828 + LMX2594 clock
chain (or new register files and clock code in `rfsoc/rfsoc_lib`) and a 100G
port on GTY lanes that `ip/src/cmac_100g` can drive.

1. `boards/<board>/board.tcl`: copy one and fill in the part, board part,
   clock families, link and pin tie-offs (every variable is commented).
2. `boards/<board>/block_designs/<board>_uhd_v49[_245m76]/`: one `.tcl` +
   `.xdc` per clock family, adapted from the closest board (channel map,
   pins, geometry table `v49_geometry`). Keep the PS address map.
3. `boards/<board>/builds.txt`: the templates (and any fixed-factor builds).
4. `rfsoc/rfsoc_lib/xrfclk/<board_xrfclk>/`: the LMK04828 / LMX2594 register
   files for each fs (the flow picks the clock family from them).
5. Check with `make BOARD=<board> bitstream N=1 STEP=bd`, then build.
6. The software side: a `Board` entry in `rfsoc/server/boards.py`.

`AGENTS.md` has the design rules.
