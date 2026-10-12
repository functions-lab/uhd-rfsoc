# AGENTS.md — fpga_board/zcu208

- Design: `block_designs/zcu208_uhd_v49/zcu208_uhd_v49.tcl` (+ `.xdc`), one for
  N = 1, 2; block design name `zcu208_v49_<N>ch_qsfp`. Non-Xilinx IP:
  `../../fpga_ip/ip/uhd_ip` and the two I/Q joiners in
  `../../fpga_ip/ip/iprepo` (dual_rf_adc_iq_merger N = 1,
  dual_channel_rf_adc_iq_packer N = 2).
- The RF-ADC tiles are DUAL: I and Q leave on separate slices with S samples
  per clock. Fabric = fs / F / S; ADC Data_Width = S, DAC Data_Width = 2S. The
  ZCU216 formula is wrong here by 2x.
- Channel map: ch0 DAC s20 / ADC tile 2 (m20 I, m21 Q); ch1 DAC s00 / ADC
  tile 0 (m02 I, m03 Q) (`v49_channel_slices`).
- Built and timing-clean, NOT yet loaded on a ZCU208: every board-level
  assumption (GT refclk from the 8A34001, no SFP TX_DISABLE pins, MTS) is
  unverified until a board run. SPEAR's `hw_design/ZCU208/CLAUDE.md` lists them.
