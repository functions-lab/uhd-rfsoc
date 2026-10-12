# AGENTS.md — fpga_board/rfsoc4x2

Not ported (README.md). Do not copy SPEAR's `rfsoc4x2_v43`: it is a DRAM
capture/playback design, not a UHD one. Start from `../zcu208` (dual RF-ADC
tiles) and add the board to `rfsoc/server/boards.py`.
