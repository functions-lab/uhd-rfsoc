# AGENTS.md — fpga_board

- Per board: `block_designs/<board>_uhd_v49/<board>_uhd_v49.{tcl,xdc}`,
  `scripts/v49_build.tcl`, `scripts/v49_ladder.sh`, `Makefile`. The RFSoC
  4x2 build also uses Real Digital's board files in `rfsoc4x2/board_files/`
  (vendored, Apache-2.0: do not edit).
- Build only with `make v49` / `make v49-ladder` / `make v49-templates`
  (Vivado 2021.1 on PATH).
  `v49_build.tcl` sources the design once with V49_DEFINE_ONLY=1 for
  `v49_geometry`, then builds; `verify_rate_variant` refuses a block design
  that disagrees with the geometry table.
- Keep only the bitstream: the flow deletes each Vivado project; keep
  projects only with V49_KEEP_PROJ=1 while debugging, then delete them.
- The converter factor is a block-design parameter on EVERY tile and slice;
  the board-specific rules (MTS, clocking, channel map) are in
  `zcu216/AGENTS.md` and `rfsoc4x2/AGENTS.md`. Only these two boards are
  supported.
- A block design is ONE self-contained `.tcl` + `.xdc` per board,
  parameterised by V49_NCH / V49_FACTOR / V49_FS; never derive one board's
  design from another's files.
