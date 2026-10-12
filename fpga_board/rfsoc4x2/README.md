# fpga_board/rfsoc4x2 — not ported

SPEAR has no UHD design for the RFSoC 4x2 (only the pre-UHD `rfsoc4x2_v43`
DRAM design, which this repository does not take), and the daemon's
`rfsoc/server/boards.py` knows only the ZCU216 and ZCU208. A port would add
`block_designs/rfsoc4x2_uhd_v49/` modelled on the ZCU208 design (also dual
RF-ADC tiles), a `boards.py` entry, and the board's LMX/LMK files (already in
`rfsoc/rfsoc_lib/xrfclk/RFSoC4x2`).
