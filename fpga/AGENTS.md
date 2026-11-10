# AGENTS.md — fpga

Rules and map of the FPGA side. `README.md` has the commands; each board's
`AGENTS.md` its design rules and board facts.

## Map
| path | role |
|---|---|
| `Makefile` | the only entry point: `package`, `templates`, `bitstream`, `ladder`, `list`, `clean` (`BOARD=`, `PYNQ=`), `versions` |
| `flow/versions.txt` | the PYNQ version -> Vivado release mapping, and the IP versions of each release that differ from the designs' |
| `flow/versions.sh` | reads it for the Makefile (Vivado of a PYNQ version, build directory, `settings64.sh`, `check`) |
| `flow/build.tcl` | one build of one board: project, CMAC IP, block design, generated RTL top (`v49_gen_top`), bitstream, outputs |
| `flow/ladder.sh` | the builds of `builds.txt` (filtered by kind / fs / name), in parallel, with a summary |
| `boards/<b>/board.tcl` | the board's facts for the flow: part, board part, board files, xrfclk dir, clock families, CMAC lanes, top tie-offs, XDC net checks |
| `boards/<b>/builds.txt` | `N F fs kind [strategy]`: the templates and fixed-factor builds, each with its implementation strategy |
| `boards/<b>/block_designs/<b>_uhd_v49[_245m76]/` | the design of a clock family (`.tcl` + `.xdc`), every N |
| `boards/rfsoc4x2/board_files/` | Real Digital's Vivado board files (vendored, Apache-2.0): do not edit |
| `ip/src/uhd_ip/`, `ip/repo/uhd_ip/` | the data-plane cores: sources + sims, and packaged (`make package`) |
| `ip/src/cmac_100g/` | the 100G CMAC + GT wrapper RTL (in the generated top, never in a block design) |
| `ip/repo/dual_*` | the RFSoC 4x2's dual RF-ADC I/Q joiners (packaged in place) |
| `build/<b>/`, `build/pynq<v>/<b>/` | outputs, gitignored: `bitstreams/`, `bitstreams_timing_fail/`, `logs/` (default PYNQ version, other ones) |

## Rules
- `flow/` names no board: everything board-specific is in `boards/<b>/`
  (`board.tcl` variables are all `board_*`). A new board is a new directory
  plus its xrfclk register files (`README.md`, "Add a board").
- A block design is ONE self-contained `.tcl` + `.xdc` per board and clock
  family, parameterised by `V49_NCH` / `V49_FACTOR` / `V49_FS`; never derive
  one from another (no sourcing between them). The two families differ only
  in the clock tree (MTS_clk_wiz input 300 / 122.88 MHz, PL_CLK / PL_SYSREF,
  the XDC PL_CLK period, the geometry rows, the default fs): a data-path
  change is made in every design of every board.
- `build.tcl` picks the design from fs: the family (`board_families`) whose
  LMX2594 reference has a register file for fs in
  `rfsoc/rfsoc_lib/xrfclk/<board_xrfclk>/` (the board needs the same file to
  run the build). It sources the design once with `V49_DEFINE_ONLY=1` for
  `v49_geometry`, then builds; `verify_rate_variant` refuses a design that
  disagrees with the geometry table.
- The converter factor and Data_Width are block-design parameters on EVERY
  tile and slice (`v49_geometry` is the single table); the daemon's template
  retune is the only run-time factor change (Protocol §8).
- Names are a contract with the daemon (Protocol §8): design
  `<b>_v49_<N>ch_qsfp`, bitstream `<b>_v49_<N>ch_qsfp_f<F>_fs<fs>`, `<b>` the
  board directory's name.
- The PS address map is fixed (daemon and `rfsoc_lib` depend on it):
  MTS_clk_wiz 0x8020_0000, axi_gpio_led 0x8023_0000, axi_intc 0x8024_0000,
  RFDC 0x8028_0000, eth100g 0x8002_0000 .. 0x8008_0000 (Protocol §11, §12,
  `rfsoc/server/eth100g.py`). `verify_rate_variant` checks it.
- Build only through the Makefile (the Vivado release of `PYNQ=`, checked;
  `build.tcl` refuses a release `flow/versions.txt` does not name). Only
  the bitstream is kept (`V49_KEEP_PROJ=1` keeps the project). Bitstreams
  are never committed: they are built locally and published as release assets.
- The designs and `create_cmac_ip.tcl` name Vivado 2021.1's IP versions and
  stay so; every `xilinx.com:ip` VLNV goes through `v49_vlnv` (defined by
  `build.tcl`; identity when a design is sourced on its own), which
  substitutes the `ip` lines of `flow/versions.txt` for the running
  release and refuses a version that is not current in its catalog. A new
  IP in a design: write its 2021.1 VLNV as `[v49_vlnv xilinx.com:ip:...]`.
- Package the cores (`make package`) with 2021.1 only: every release of
  `flow/versions.txt` reads the packaged `ip/repo/` as it is (2022.1 does,
  unchanged); a newer packager's `component.xml` is not known to load in
  2021.1.
- After a change under `ip/src/uhd_ip/src/`: its sims (`make -C
  ip/src/uhd_ip all`), then `make package`; commit the sources and
  `ip/repo/uhd_ip` together.

## PYNQ versions

What ties a bitstream to a PYNQ image, as of PYNQ 2.7, 3.0.1 and 3.1.x
(their sources):

- **Not the bitstream itself**: PYNQ loads the `.bit` through the FPGA
  manager whatever Vivado wrote it, and sets nothing of the PS from it.
- **The `.hwh`**: PYNQ parses it to build the overlay (2.7 its own
  `pl_server` parser, 3.x the `pynqmetadata` one); the daemon reads it too
  (`rfsoc/server/hw_backend.py`). A PYNQ image is tested against the
  `.hwh` of the Vivado release its own overlays are built with: PYNQ 2.7
  2020.2, 3.0 2022.1, 3.1 2024.1 (PYNQ changelog; the RFSoC 4x2 base
  overlays of 3.0 / 3.1 are 2022.1 / 2024.1 designs).
- **The RFDC driver**: `xrfdc` is the same in 2.7, 3.0 and 3.1: the same
  Python wrapper (no MTS: `rfsoc/setup_board.sh` adds it on each), libxrfdc
  from the 2020.2 RFDC driver, bound to IP versions 2.3 / 2.4 (2.7) and
  2.6 / 2.4 / 2.3 (3.x). Vivado 2021.1's RFDC 2.5 is in neither list, so the
  daemon loads overlays with `ignore_version=True` (`rfsoc_lib/rfsoc_overlay.py`).
- **The PS IP**: `zynq_ultra_ps_e` 3.3 (2021.1), 3.4 (2022.1), 3.5 (2023.1,
  2024.1); the PL clocks PYNQ sets come from the `.hwh`.

So "a bitstream per PYNQ version" is a build per Vivado release: the one
whose `.hwh` and IP versions that PYNQ's own overlays use. PYNQ 2.7 is the
exception: its builds stay on 2021.1, which the boards run with PYNQ 2.7
today; 2020.2 would downgrade the RFDC to 2.4 and `util_ds_buf` to 2.1 for
nothing the image needs.

Adding a PYNQ version (or moving one to another Vivado release):

1. a `pynq` line in `flow/versions.txt`, and `ip` lines for every
   `xilinx.com:ip` the designs name that the release has only at another
   version (its catalog; `v49_vlnv` names any it misses);
2. `make BOARD=<b> PYNQ=<v> templates STEP=bd` for every board: the
   designs' own checks (`verify_rate_variant`) run there;
3. one full build per board, then on a board with that image: the daemon
   brings it up (`rfsoc/server`), the `.hwh` parses (`hw_backend.py`).
