# AGENTS.md — fpga_board

- Per board: `block_designs/<board>_uhd_v49/<board>_uhd_v49.{tcl,xdc}` (250
  MHz clock family) and `block_designs/<board>_uhd_v49_245m76/` (245.76 MHz
  family, Protocol §8a), `scripts/v49_build.tcl`, `scripts/v49_ladder.sh`,
  `Makefile`. The RFSoC
  4x2 build also uses Real Digital's board files in `rfsoc4x2/board_files/`
  (vendored, Apache-2.0: do not edit).
- Build only with `make v49` / `make v49-ladder` / `make v49-templates` /
  `make v49-templates-245m76` (Vivado 2021.1 on PATH). `v49_build.tcl` picks
  the design from fs: the family whose LMX2594 reference has a register file
  for fs in `rfsoc/rfsoc_lib/xrfclk/<board>/` (`LMX2594_250.0_<fs>.0.txt` or
  `LMX2594_245.76_<fs>.txt`).
  `v49_build.tcl` sources the design once with V49_DEFINE_ONLY=1 for
  `v49_geometry`, then builds; `verify_rate_variant` refuses a block design
  that disagrees with the geometry table.
- Keep only the bitstream: the flow deletes each Vivado project; keep
  projects only with V49_KEEP_PROJ=1 while debugging, then delete them.
- The converter factor is a block-design parameter on EVERY tile and slice;
  the board-specific rules (MTS, clocking, channel map) are in
  `zcu216/AGENTS.md` and `rfsoc4x2/AGENTS.md`. Only these two boards are
  supported.
- A block design is ONE self-contained `.tcl` + `.xdc` per board and clock
  family, parameterised by V49_NCH / V49_FACTOR / V49_FS; never derive one
  design from another's files. The two families' designs differ only in the
  clock tree (MTS_clk_wiz input 300 / 122.88 MHz, the PL_CLK / PL_SYSREF port
  frequencies and the XDC PL_CLK period, the geometry rows, the default fs):
  a data-path change is made in both.
