# AGENTS.md — fpga/boards/zcu208

Design rules and board facts of the ZCU208 builds; the flow rules are in
`../../AGENTS.md`. The ZCU208 is the RFSoC 4x2's die (xczu48dr: Gen3, DUAL
RF-ADC tiles) in another package, with the ZCU216's CLK104 clock card,
8A34001 and zSFP28 cages: the data path follows `../rfsoc4x2/AGENTS.md`, the
clocking and the 100G link `../zcu216/AGENTS.md`. **Built, not yet run on a
board**: every fact below comes from a primary source, none from a board.

## Sources (use these, not UG1410's pin tables)
- Vivado's board files, `xilinx.com:zcu208:part0:2.0` (2021.1, 2022.1 and
  2024.1 alike; `part0_pins.xml`, `preset.xml`), and Vivado's package pin
  functions of `xczu48dr-fsvg1517-2-e`.
- AMD's RFSoC-MTS ZCU208 design (`boards/ZCU208/build_mts/mts.xdc`,
  `zcu208_mts.tcl`) and RFSoC-PYNQ's ZCU208 base overlay (v3.0.0 / v3.1.1:
  `base.tcl`, `tics/`, the BSP device tree).
- UG1437 (CLK104) and UG1410 for topology only: **UG1410 v1.0's pin tables
  are the ZCU216's** (its Y34/Y35, H34/H35, K14-K17 and banks 88/89 do not
  exist as such on this package).

## Facts
- Part `xczu48dr-fsvg1517-2-e` (fsvg, not the 4x2's ffvg), board part
  `xilinx.com:zcu208:part0:2.0`, Vivado's own board files. PS: the board
  preset (`apply_board_preset`, the same PS and DDR4 SODIMM as the ZCU216)
  plus HPM0_LPD 128 bit, pl_clk0 100 MHz, one fabric reset, IRQ0/1.
- Converters: 4 dual RF-ADC tiles (224-227, inputs `vin<t>_01` /
  `vin<t>_23`, up to 5 GS/s) and 4 RF-DAC tiles (228-231) with outputs
  `vout<t>0` / `vout<t>2` only (DAC IP slices 0 and 2): 8 + 8. Every
  converter is enabled on every build; channels 0..N-1 stream.
- Channel map (`v49_channel_slices`, `rfsoc/server/boards.py`): channel c is
  ADC tile c % 4 converter c / 4 (IP slices 2(c/4) I, 2(c/4)+1 Q; xrfdc API
  block c / 4) and DAC tile c % 4 slice 2(c/4). Channels 0..3 are the
  `vin<t>_01` / `vout<t>0` PYNQ's base overlay uses. Which XM655 SMA carries
  which converter is NOT confirmed (schematic gated): check with a tone per
  port on first bring-up.
- Tile clocks: the CLK104's two LMX2594s reach the board's `ADC_CLK_225` and
  `DAC_CLK_230` SMAs only (UG1410; PYNQ and AMD use those two). The design
  takes `adc1_clk` and `dac2_clk` and distributes each from its tile
  (`ADC1_Clock_Dist`, `DAC2_Clock_Dist`; Clock_Source 1 / 6 on the others).
  DAC clock pins exist only on tiles 228 and 230.
- MTS: all four ADC and DAC tiles; reference tile = the tile that
  distributes the clock: ADC tile 1, DAC tile 2 (`Board` `mts_adc_ref_tile`
  / `mts_ref_tile`). AMD's own ZCU208 MTS driver uses 2 / 2 with a design
  that does not enable ADC tile 2, so it is no precedent for the ADC; the
  choice here is unconfirmed on a board.
- PL_CLK B8/B7, PL_SYSREF B10/B9 (HDGC pins, HD bank 87, VCC1V8, LVDS_25),
  as AMD's RFSoC-MTS ZCU208 XDC: HDGC reaches a BUFG, not an MMCM, so the
  XDC carries the ZCU216's two CLOCK_DEDICATED_ROUTE settings
  (`board_xdc_nets`). AMD also drives the CLK104 SPI mux select (C11, B12);
  neither this design nor the ZCU216's does, and xrfclk writes the clocks
  without it on both boards (PYNQ's base overlay does not drive it either).
- Clock register files (`rfsoc/rfsoc_lib/xrfclk/ZCU208/`): the CLK104 is the
  ZCU216's, so the LMK04828 files are the ZCU216's unchanged (PYNQ's ZCU208
  LMK04828_245.76 file is byte-identical to ZCU216-PYNQ's and to ours apart
  from eight zero writes). The LMX2594 files are the RFSoC 4x2's for fs 5000,
  4800 and 4915.2 (the same 250 / 245.76 MHz references and VCO plans):
  they drive RFoutA AND RFoutB, so either CLK104 output cabling works (the
  ZCU216's own files drive RFoutB only; PYNQ's ZCU208 files RFoutA only).
- 100 GbE: no QSFP; the 2x2 zSFP28 cage on GTY X0Y4 X0Y5 (quad 128) X0Y8
  X0Y9 (quad 129), CMACE4_X0Y0, refclk 8A34001 Q11 -> MGTREFCLK1_128 = Y31 /
  Y32 on this package: the ZCU216's layout, so `board_cmac_lanes zsfp` and
  `create_cmac_ip.tcl` unchanged. The 8A34001 sits where the ZCU216's does
  (TCA9548A 0x74 channel 4, address 0x5B, per the board's Linux device
  tree): the daemon programs it at bring-up (`gt_refclk "8a34001"`, the
  ZCU216's register file). Its power-up state and crystal are assumed to be
  the ZCU216's: if the APLL does not lock, that is why. The Si570 (quad 131)
  is too far from quad 128 to replace it.
- zSFP28 TX_DISABLE: jumpers J39 / J44 / J32 / J35 (default OFF = TX
  disabled on an optical / active module; a passive DAC cable ignores it).
  No FPGA pin, no `sfp_tx_disable_b` port, `board_top_ties {}`.
- LEDs: `led[7:0]` = GPIO_LED_0..7_LS (AR19 AT17 AR17 AU19 AU20 AW21 AV21
  AV17, LVCMOS12), axi_gpio_led single channel.
- PYNQ images: 3.0.1, 3.1.1 (and 4.0) exist for the ZCU208; there is no
  official 2.7 image: the published sets are PYNQ 3.0 and 3.1 only.
  `pynq_board` / `$BOARD` = `ZCU208`.

## Design
- Designs: `block_designs/zcu208_uhd_v49/` (250 MHz family: PL_CLK 300 MHz,
  SYSREF 10 MHz, fs 5000 and 4800) and `block_designs/zcu208_uhd_v49_245m76/`
  (PL_CLK 122.88 MHz, SYSREF 7.68 MHz, fs 4915.2; Protocol §8a). Non-Xilinx
  IP: `fpga/ip/repo/uhd_ip` and `dual_rf_adc_iq_merger` (`board_ip_repos`).
- Dual tiles as on the 4x2: fabric = fs / F / S, ADC Data_Width = S, DAC
  Data_Width = 2S; the RFDC is created at the build's geometry
  (`v49_rfdc_creation`).
- Geometry rows (`v49_geometry`): 1ch S 8 (256-bit beat), 2ch S 8 (512),
  4ch S 4 (512), 8ch S 2 (512); templates 1/2ch F2, 4ch F4, 8ch F8 (fabric
  312.5 MHz at fs 5000), each retuned at run time to every Gen3 factor above.
- Stream glue: one `dual_rf_adc_iq_merger` per channel
  (`rfdc/iq_merger_<c>`), for N > 1 straight into an N-input
  `axis_combiner`, and an N-output `axis_broadcaster` to the DACs. The ADC
  glue must stay STATELESS (no per-channel buffer), or a pause of one tile's
  stream (bring-up, the run-time factor change's per-tile `SetupFIFO`) skews
  the channels for good: every merger's `m_axis_tready` is tied to 1
  (`rfdc/iq_tready_one`; the merger's tvalid depends on its tready and the
  combiner's tready on all tvalids, a loop otherwise) and the combiner's
  tready is unused, as the ZCU216's RFDC -> combiner path behaves. The same
  holds for the ZCU111 design. `verify_rate_variant` checks the wiring, the
  tie-off, the 16 + 8 enabled slices and the clock distribution.
- Implementation strategy: Performance_ExtraTimingOpt on every template
  (`builds.txt`), as the same die needs on the 4x2.
