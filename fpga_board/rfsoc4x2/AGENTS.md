# AGENTS.md — fpga_board/rfsoc4x2

- Design: `block_designs/rfsoc4x2_uhd_v49/rfsoc4x2_uhd_v49.tcl` (+ `.xdc`), one
  for N = 1, 2; block design name `rfsoc4x2_v49_<N>ch_qsfp`. Non-Xilinx IP:
  `../../fpga_ip/ip/uhd_ip` and the two I/Q joiners in
  `../../fpga_ip/ip/iprepo` (dual_rf_adc_iq_merger N = 1,
  dual_channel_rf_adc_iq_packer N = 2).
- Part `xczu48dr-ffvg1517-2-e`, board part `realdigital.org:rfsoc4x2:part0:1.0`
  from `board_files/` (`v49_build.tcl` sets `board.repoPaths`). The PS is the
  board preset (`apply_board_preset`) plus the PL side the design uses:
  HPM0_LPD only (128 bit; registers at 0x8000_0000), pl_clk0 100 MHz,
  one fabric reset, IRQ0/1. On PYNQ the boot firmware configures the PS; the
  bitstream's PS settings matter for the .hwh (PL clock) and correctness.
- The RF-ADC tiles are DUAL: I and Q leave on separate slices with S samples
  per clock. Fabric = fs / F / S; ADC Data_Width = S, DAC Data_Width = 2S. The
  ZCU216 formula is wrong here by 2x. fs = 5000 on every build: the LMX2594
  feeds the tiles at fs directly (tile PLLs bypassed;
  `rfsoc/rfsoc_lib/xrfclk/RFSoC4x2/LMX2594_250.0_5000.0.txt`).
- Channel map (the SMA ports PYNQ's base overlay uses): ch0 DAC s20 / ADC
  tile 2 (m20 I, m21 Q); ch1 DAC s00 / ADC tile 0 (m02 I, m03 Q)
  (`v49_channel_slices`; `rfsoc/server/boards.py`).
- 100 GbE: one QSFP28 on GTY quad 128 (X0Y4..X0Y7, CMACE4_X0Y0), cmac_100g
  built with `CMAC_LANES qsfp128` (one QPLL common). Refclk MGTREFCLK0_128
  (AA33/AA34) = the board's Si570 at 156.25 MHz from power-up: nothing
  programs it (`boards.py` gt_refclk "si570"; the ZCU216's 8A34001 path is
  skipped). QSFP28 ResetL (AL21) high, LPMode (AN22) low, ModSelL (AK22) low,
  held by the RTL top. Pins: Real Digital's RFSoC4x2-BSP
  `hw/constraints/4x2_QSFP.xdc` and PYNQ's RFSoC4x2 base overlay `base.xdc`.
- MTS: PL_CLK (AN11/AP11) and PL_SYSREF (AP18/AR18) from the LMK04828; DAC
  and ADC tiles 0 and 2 only (MyMTS tile mask 0b0101, reference tile 2).
