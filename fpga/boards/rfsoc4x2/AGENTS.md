# AGENTS.md — fpga/boards/rfsoc4x2

Design rules and board facts of the RFSoC 4x2 builds; the flow rules are in
`../../AGENTS.md`. What differs from the ZCU216 (`../zcu216/AGENTS.md`):

- Designs: `block_designs/rfsoc4x2_uhd_v49/` (250 MHz family, fs 5000 and 4800:
  `rfsoc/rfsoc_lib/xrfclk/RFSoC4x2/LMX2594_250.0_{5000,4800}.0.txt`) and
  `block_designs/rfsoc4x2_uhd_v49_245m76/` (245.76 MHz family, fs 4915.2,
  PL_CLK 122.88 MHz, SYSREF 7.68 MHz; Protocol §8a). Non-Xilinx IP:
  `fpga/ip/repo/uhd_ip` and the two I/Q joiners in `fpga/ip/repo`
  (`dual_rf_adc_iq_merger` for N = 1, `dual_channel_rf_adc_iq_packer` for
  N = 2; `board_ip_repos`).
- Part `xczu48dr-ffvg1517-2-e`, board part `realdigital.org:rfsoc4x2:part0:1.0`
  from `board_files/` (`board_files` in `board.tcl`). The PS is the board
  preset (`apply_board_preset`) plus what the design uses: HPM0_LPD only
  (128 bit; registers at 0x8000_0000), pl_clk0 100 MHz, one fabric reset,
  IRQ0/1. On PYNQ the boot firmware configures the PS; the bitstream's PS
  settings matter for the `.hwh` (PL clock) and correctness.
- The RF-ADC tiles are DUAL: I and Q leave on separate slices with S samples
  per clock. Fabric = fs / F / S; ADC Data_Width = S, DAC Data_Width = 2S
  (the ZCU216 formula is off by 2x here). `v49_rfdc_creation` creates the
  RFDC at the build's geometry (Outclk fs/128, written to 3 decimals rounded
  half up, as the IP lists it), `apply_geometry` / `verify_rate_variant`
  as on the ZCU216.
- Geometry rows (`v49_geometry`): 1ch S = 8 (256-bit beat), 2ch S = 4
  (256-bit) with the 2ch F2 row at S = 8 (512-bit beat, 2 x 2500 MS/s, sc8
  only); the 245.76 MHz design's 2ch rows are all S = 8 (512-bit beat).
- Channel map (the SMA ports PYNQ's base overlay uses): ch0 DAC s20 / ADC
  tile 2 (m20 I, m21 Q); ch1 DAC s00 / ADC tile 0 (m02 I, m03 Q)
  (`v49_channel_slices`; `rfsoc/server/boards.py`).
- 100 GbE: one QSFP28 on GTY quad 128 (X0Y4..X0Y7, CMACE4_X0Y0), cmac_100g
  built with `CMAC_LANES qsfp128` (one QPLL common). Refclk MGTREFCLK0_128
  (AA33/AA34) = the board's Si570 at 156.25 MHz from power-up: nothing
  programs it (`boards.py` gt_refclk "si570"). QSFP28 ResetL (AL21) high,
  LPMode (AN22) low, ModSelL (AK22) low, held by the generated RTL top
  (`board_top_ties`). Pins: Real Digital's RFSoC4x2-BSP constraints and
  PYNQ's RFSoC4x2 base overlay.
- MTS: PL_CLK (AN11/AP11) and PL_SYSREF (AP18/AR18) from the LMK04828; DAC
  and ADC tiles 0 and 2 only (MyMTS tile mask 0b0101, reference tile 2).
- Implementation strategy per build: `builds.txt` (routing-dominated paths
  in the 322 MHz CMAC domain need Performance_ExtraTimingOpt on this part;
  2ch F16 Performance_Explore).
