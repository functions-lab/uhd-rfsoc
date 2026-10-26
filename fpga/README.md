# fpga — the bitstreams

One build flow for every board: `boards/<board>/` says what is
board-specific, `flow/` builds it, `make` drives it. A bitstream is
`<board>_v49_<N>ch_qsfp_f<F>_fs<fs>.bit` + `.hwh` (N channels, RFDC factor F,
converter rate fs in MS/s, its decimal point as `p`).

| board | `BOARD=` | channels N | clock families (fs, MS/s) | templates |
|---|---|---|---|---|
| AMD ZCU216 | `zcu216` | 1, 2, 4, 8, 16 | 2500, 2457.6 | 10 |
| Real Digital RFSoC 4x2 | `rfsoc4x2` | 1, 2 | 5000, 4915.2 | 4 |

## Prerequisites

- Linux x86_64 with **Vivado 2021.1** (exactly this version) on PATH:
  `vivado -version` must say v2021.1, else `source <Vivado
  install>/2021.1/settings64.sh` (`make` checks it).
- The no-charge AMD license for the **UltraScale+ Integrated 100G Ethernet
  Subsystem** (`cmac_usplus`), installed for Vivado (e.g.
  `~/.Xilinx/<host>.lic`). Without it implementation fails.
- Per build running at once: ~16 GB RAM and ~15 GB free disk (`MAXPAR=1`
  runs one build at a time; the next starts only with 12 GB of disk free).

The RFSoC 4x2's board files are in `boards/rfsoc4x2/board_files/`; the
ZCU216's ship with Vivado. Nothing gets installed.

## Build

From this directory:

```sh
make BOARD=zcu216 templates     # the ZCU216's 10 templates
make BOARD=rfsoc4x2 templates   # the RFSoC 4x2's 4 templates
make BOARD=zcu216 list          # every build of the board: built, TIMING-FAIL or - (not built)
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
| `make BOARD=<b> templates [FS=<fs>]` | the templates (of one clock family with `FS=`) |
| `make BOARD=<b> bitstream N=<n> [F=<f>] [FS=<fs>]` | one build (default F: the template's; default fs: the board's first family) |
| `make BOARD=<b> ladder` | every build in `boards/<b>/builds.txt`, the fixed-factor ones too (days) |
| `STEP=bd` | block design only: checks a design in minutes |
| `SKIP_EXISTING=1` | skip builds already in `bitstreams/` |
| `make BOARD=<b> clean` | delete `build/<b>/` |

Outputs, in `build/<board>/`:

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
rfsoc/push_bitstreams.sh fpga/build/<board>/bitstreams xilinx@<board-ip>
```

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
