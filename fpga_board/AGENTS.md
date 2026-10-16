# AGENTS.md — fpga_board

- Per board: `block_designs/<board>_uhd_v49/<board>_uhd_v49.{tcl,xdc}`,
  `scripts/v49_build.tcl`, `scripts/v49_ladder.sh`, `Makefile` (local). The
  ZCU216's design and scripts come from SPEAR (renamed by a `sync/manifest`
  rewrite); the RFSoC 4x2's are local (SPEAR has none), with Real Digital's
  board files in `rfsoc4x2/board_files/`.
- Build only with `make v49` / `make v49-ladder` (Vivado 2021.1 on PATH).
  `v49_build.tcl` sources the design once with V49_DEFINE_ONLY=1 for
  `v49_geometry`, then builds; `verify_rate_variant` refuses a block design
  that disagrees with the geometry table.
- Keep only the bitstream: the flow deletes each Vivado project; keep
  projects only with V49_KEEP_PROJ=1 while debugging, then delete them.
- The converter factor is a block-design parameter on EVERY tile and slice;
  the board-specific rules (MTS, clocking, channel map) are in
  `zcu216/AGENTS.md` and `rfsoc4x2/AGENTS.md`. The ZCU208 is not supported
  (SPEAR's port is not taken).
