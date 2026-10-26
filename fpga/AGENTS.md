# AGENTS.md — fpga

Rules and map of the FPGA side. `README.md` has the commands; each board's
`AGENTS.md` its design rules and board facts.

## Map
| path | role |
|---|---|
| `Makefile` | the only entry point: `package`, `templates`, `bitstream`, `ladder`, `list`, `clean` (`BOARD=`) |
| `flow/build.tcl` | one build of one board: project, CMAC IP, block design, generated RTL top (`v49_gen_top`), bitstream, outputs |
| `flow/ladder.sh` | the builds of `builds.txt` (filtered by kind / fs / name), in parallel, with a summary |
| `boards/<b>/board.tcl` | the board's facts for the flow: part, board part, board files, xrfclk dir, clock families, CMAC lanes, top tie-offs, XDC net checks |
| `boards/<b>/builds.txt` | `N F fs kind [strategy]`: the templates and fixed-factor builds, each with its implementation strategy |
| `boards/<b>/block_designs/<b>_uhd_v49[_245m76]/` | the design of a clock family (`.tcl` + `.xdc`), every N |
| `boards/rfsoc4x2/board_files/` | Real Digital's Vivado board files (vendored, Apache-2.0): do not edit |
| `ip/src/uhd_ip/`, `ip/repo/uhd_ip/` | the data-plane cores: sources + sims, and packaged (`make package`) |
| `ip/src/cmac_100g/` | the 100G CMAC + GT wrapper RTL (in the generated top, never in a block design) |
| `ip/repo/dual_*` | the RFSoC 4x2's dual RF-ADC I/Q joiners (packaged in place) |
| `build/<b>/` | outputs, gitignored: `bitstreams/`, `bitstreams_timing_fail/`, `logs/` |

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
  RFDC 0x8028_0000, eth100g 0x8002_0000 .. 0x8007_0000 (Protocol §11,
  `rfsoc/server/eth100g.py`). `verify_rate_variant` checks it.
- Build only through the Makefile (Vivado 2021.1, checked). Only the
  bitstream is kept (`V49_KEEP_PROJ=1` keeps the project). Bitstreams are
  never committed: release assets.
- After a change under `ip/src/uhd_ip/src/`: its sims (`make -C
  ip/src/uhd_ip all`), then `make package`; commit the sources and
  `ip/repo/uhd_ip` together.
