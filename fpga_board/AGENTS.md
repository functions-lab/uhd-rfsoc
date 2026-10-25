# AGENTS.md — fpga_board

Rules and map of the FPGA build flow. `README.md` has the commands; the
board directories' `AGENTS.md` have the design rules and board facts.

## Map (per board)
| file | role |
|---|---|
| `block_designs/<board>_uhd_v49/<board>_uhd_v49.{tcl,xdc}` | the 250 MHz clock family's design, every N |
| `block_designs/<board>_uhd_v49_245m76/<board>_uhd_v49_245m76.{tcl,xdc}` | the 245.76 MHz family's (Protocol §8a) |
| `scripts/v49_build.tcl` | one build: project, CMAC IP, block design, generated RTL top, bitstream, outputs |
| `scripts/v49_ladder.sh` | the build list (`BUILDS`), the implementation strategy per build (`strategy_of`), parallel runs |
| `Makefile` | `v49`, `v49-ladder`, `v49-templates`, `v49-templates-245m76`, `v49-package` |
| `rfsoc4x2/board_files/` | Real Digital's Vivado board files (vendored, Apache-2.0): do not edit |

## Rules
- A block design is ONE self-contained `.tcl` + `.xdc` per board and clock
  family, parameterised by `V49_NCH` / `V49_FACTOR` / `V49_FS`; never derive
  one from another (no sourcing between them). The two families differ only
  in the clock tree (MTS_clk_wiz input 300 / 122.88 MHz, the PL_CLK /
  PL_SYSREF frequencies and the XDC PL_CLK period, the geometry rows, the
  default fs): a data-path change is made in both. A block-design directory
  holds nothing else.
- Build only through the Makefile targets (Vivado 2021.1 on PATH).
  `v49_build.tcl` picks the design from fs: the family whose LMX2594
  reference has a register file for fs in `rfsoc/rfsoc_lib/xrfclk/<board>/`
  (`LMX2594_250.0_<fs>.0.txt` or `LMX2594_245.76_<fs>.txt`; the board needs
  the same file to run the build). It sources the design once with
  `V49_DEFINE_ONLY=1` for `v49_geometry`, then builds; `verify_rate_variant`
  refuses a block design that disagrees with the geometry table.
- The converter factor and Data_Width are block-design parameters on EVERY
  tile and slice (`v49_geometry` is the single table); the daemon's
  template retune is the only run-time factor change (Protocol §8).
- The PS address map is fixed (daemon and `rfsoc_lib` depend on it):
  MTS_clk_wiz 0x8020_0000, axi_gpio_led 0x8023_0000, axi_intc 0x8024_0000,
  RFDC 0x8028_0000, eth100g 0x8002_0000 .. 0x8007_0000 (Protocol §11,
  `rfsoc/server/eth100g.py`). `verify_rate_variant` checks it.
- Keep only the bitstream: the flow deletes each Vivado project
  (`V49_KEEP_PROJ=1` keeps it while debugging). Bitstreams are never
  committed (release assets).
- Only the ZCU216 and the RFSoC 4x2 are supported. The CMAC and its GT
  wizard live in the generated RTL top, not in the block design
  (`fpga_ip/ip_design/cmac_100g/AGENTS.md`); the port names the design
  exports for it are mapped by `v49_gen_top` in `v49_build.tcl`.
