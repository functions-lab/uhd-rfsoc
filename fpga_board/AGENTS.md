# AGENTS.md — fpga_board

- Per board: `block_designs/<board>_uhd_v49/<board>_uhd_v49.{tcl,xdc}` (from
  SPEAR, renamed by a `sync/manifest` rewrite), `scripts/v49_build.tcl`,
  `scripts/v49_ladder.sh` (from SPEAR), `Makefile` (local).
- Build only with `make v49` / `make v49-ladder` (Vivado 2021.1 on PATH).
  `v49_build.tcl` sources the design once with V49_DEFINE_ONLY=1 for
  `v49_geometry`, then builds; `verify_rate_variant` refuses a block design
  that disagrees with the geometry table.
- Keep only the bitstream: the flow deletes each Vivado project; keep
  projects only with V49_KEEP_PROJ=1 while debugging, then delete them.
- The converter factor is a block-design parameter on EVERY tile and slice;
  the board-specific rules (MTS, clocking, channel map) are in
  `zcu216/AGENTS.md` and `zcu208/AGENTS.md`.
