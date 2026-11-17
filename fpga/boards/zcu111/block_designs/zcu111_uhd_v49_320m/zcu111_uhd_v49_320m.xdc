###########################################################################################################
# zcu111_uhd_v49_320m.xdc -- constraints of zcu111_uhd_v49_320m.tcl (every channel count N, fs 4000):
# the ZCU111 as a UHD device over 100 GbE. Only the pins the design uses; the RF converter pins (tile
# clocks, analog SYSREF, vin / vout) are dedicated.
# Pins from Vivado's ZCU111 board files (board part xilinx.com:zcu111:part0:1.4, part0_pins.xml), UG1271
# (v1.4) Table 3-17 (clock pins), and Vivado's package pin functions of xczu28dr-ffvg1517
# (fpga/boards/zcu111/AGENTS.md). UNCONFIRMED: the PL_CLK / PL_SYSREF I/O standard and termination
# (the AMD ZCU111 master XDC was not available): see the note below.
###########################################################################################################

# axi_gpio_led: the eight user LEDs GPIO_LED_0..7_LS (the board's led_8bits interface, HP bank 64,
# LVCMOS18, active high)
set_property PACKAGE_PIN AR13 [get_ports {led[0]}]
set_property PACKAGE_PIN AP13 [get_ports {led[1]}]
set_property PACKAGE_PIN AR16 [get_ports {led[2]}]
set_property PACKAGE_PIN AP16 [get_ports {led[3]}]
set_property PACKAGE_PIN AP15 [get_ports {led[4]}]
set_property PACKAGE_PIN AN16 [get_ports {led[5]}]
set_property PACKAGE_PIN AN17 [get_ports {led[6]}]
set_property PACKAGE_PIN AV15 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[*]}]

# MTS: PL_CLK (LMK04208 CLKout2 = FPGA_REFCLK_OUT_C, 320 MHz) and PL_SYSREF (CLKout0 = SYSREF_FPGA_C,
# 5 MHz) into MTS_block, on global-clock pins of HP bank 64 (VCCO 1.8 V: the LEDs share it).
# The LMK04208 drives them LVDS (CLKoutX_TYPE 1 in the register file) through series capacitors
# (UG1271 Table 3-17: "LVPECL, series capacitor coupled"): internal 100 ohm termination and DQS_BIAS
# (the input's own common-mode bias for an AC-coupled pair). UNCONFIRMED against the board schematic:
# if the board already terminates / biases the pairs, DIFF_TERM_ADV and DQS_BIAS can go.
set_property PACKAGE_PIN AL16 [get_ports PL_CLK_clk_p]    ;# IO_L13P_T2L_N0_GC_QBC_64
set_property PACKAGE_PIN AL15 [get_ports PL_CLK_clk_n]    ;# IO_L13N_T2L_N1_GC_QBC_64
set_property PACKAGE_PIN AK17 [get_ports PL_SYSREF_clk_p] ;# IO_L14P_T2L_N2_GC_64
set_property PACKAGE_PIN AK16 [get_ports PL_SYSREF_clk_n] ;# IO_L14N_T2L_N3_GC_64
set_property IOSTANDARD    LVDS     [get_ports {PL_CLK_clk_p PL_CLK_clk_n PL_SYSREF_clk_p PL_SYSREF_clk_n}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {PL_CLK_clk_p PL_CLK_clk_n PL_SYSREF_clk_p PL_SYSREF_clk_n}]
set_property DQS_BIAS      TRUE     [get_ports {PL_CLK_clk_p PL_CLK_clk_n PL_SYSREF_clk_p PL_SYSREF_clk_n}]

create_clock -period 3.125 -name PL_CLK_clk -waveform {0.000 1.5625} [get_ports PL_CLK_clk_p]

# Input delay for PL_SYSREF to meet the MTS requirements (PG269)
set_input_delay -clock [get_clocks PL_CLK_clk] -min -add_delay 2.0 [get_ports PL_SYSREF_clk_p];
set_input_delay -clock [get_clocks PL_CLK_clk] -max -add_delay 2.2 [get_ports PL_SYSREF_clk_p];

# PL_CLK enters on a GC pin and drives MTS_clk_wiz through BUFG_PL_CLK; the MMCM may sit in another
# CMT column. The net is found by its path below the block design instance, so one file serves every
# design name (zcu111_v49_<N>ch_qsfp).
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]

###########################################################################################################
# 100GbE CAUI-4 on the four SFP28 cages (cmac_100g in the RTL top, built with CMAC_LANES sfp128,
# fpga/ip/src/cmac_100g)
#   GT channel sites are fixed by the cmac_caui4_gt IP: GTYE4 X0Y4..X0Y7 = quad 128 lanes 0..3 = SFP0..3
#   (UG1271 Fig 3-29; part0_pins.xml sfp0..3); the serial pins follow from them. A QSFP28 -> 4 x SFP28
#   breakout cable reaches the NIC.
#   Refclk: the user MGT Si570 (U49) on MGTREFCLK1_129 (V31/V32), 156.25 MHz from power-up (UG1271 p.48,
#   board.xml user_mgt_si570_clock); quad 128's QPLL0 takes it from the quad above (clk1+1).
#   The cages' TX_DISABLE are jumpers (UG1271 Table 3-21): no pins.
###########################################################################################################
set_property PACKAGE_PIN V31 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN V32 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# Everything clocked from the GT refclk (QPLL, TX/RX user clocks) is
# asynchronous to the converter and PS clocks: every crossing goes through an
# XPM CDC macro, which carries its own constraints. One group = async to all.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sfp_refclk]
