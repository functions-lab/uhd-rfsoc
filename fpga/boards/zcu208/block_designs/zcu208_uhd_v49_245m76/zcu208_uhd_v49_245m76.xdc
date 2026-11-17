###########################################################################################################
# zcu208_uhd_v49_245m76.xdc -- constraints of zcu208_uhd_v49_245m76.tcl (every channel count N, the
# 245.76 MHz clock family): the ZCU208 as a UHD device over 100 GbE. Only the pins the design uses; the RF converter pins are dedicated.
# Pins from Vivado's ZCU208 board files (board part xilinx.com:zcu208:part0:2.0, part0_pins.xml),
# Vivado's package pin functions of xczu48dr-fsvg1517 and AMD's RFSoC-MTS ZCU208 constraints
# (boards/ZCU208/build_mts/mts.xdc). NOT from UG1410 v1.0: its pin tables are the ZCU216's
# (fpga/boards/zcu208/AGENTS.md).
###########################################################################################################

# axi_gpio_led: the eight user LEDs GPIO_LED_0..7_LS (the board's led_8bits interface, bank 66)
set_property PACKAGE_PIN AR19 [get_ports {led[0]}]
set_property PACKAGE_PIN AT17 [get_ports {led[1]}]
set_property PACKAGE_PIN AR17 [get_ports {led[2]}]
set_property PACKAGE_PIN AU19 [get_ports {led[3]}]
set_property PACKAGE_PIN AU20 [get_ports {led[4]}]
set_property PACKAGE_PIN AW21 [get_ports {led[5]}]
set_property PACKAGE_PIN AV21 [get_ports {led[6]}]
set_property PACKAGE_PIN AV17 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[*]}]

# MTS: PL_CLK (CLK104 LMK04828 DCLKout8, 122.88 MHz) and PL_SYSREF (SDCLKout9, 7.68 MHz) into MTS_block,
# on HDGC pins of HD bank 87 (VCC1V8), as AMD's RFSoC-MTS ZCU208 design places them
set_property PACKAGE_PIN B8        [get_ports PL_CLK_clk_p]    ;# IO_L7P_HDGC_87
set_property PACKAGE_PIN B7        [get_ports PL_CLK_clk_n]    ;# IO_L7N_HDGC_87
set_property PACKAGE_PIN B10       [get_ports PL_SYSREF_clk_p] ;# IO_L8P_HDGC_87
set_property PACKAGE_PIN B9        [get_ports PL_SYSREF_clk_n] ;# IO_L8N_HDGC_87
set_property IOSTANDARD  LVDS_25   [get_ports {PL_CLK_clk_p PL_CLK_clk_n PL_SYSREF_clk_p PL_SYSREF_clk_n}]

create_clock -period 8.138 -name PL_CLK_clk -waveform {0.000 4.069} [get_ports PL_CLK_clk_p]

# Input delay for PL_SYSREF to meet the MTS requirements (PG269)
set_input_delay -clock [get_clocks PL_CLK_clk] -min -add_delay 2.0 [get_ports PL_SYSREF_clk_p];
set_input_delay -clock [get_clocks PL_CLK_clk] -max -add_delay 2.2 [get_ports PL_SYSREF_clk_p];

# PL_CLK reaches MTS_clk_wiz through a non-dedicated route (an HDGC pin drives a BUFG, not an MMCM).
# The nets are found by their path below the block design instance, so one file serves every design
# name (zcu208_v49_<N>ch_qsfp).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/IBUFDS_PL_CLK/U0/USE_IBUFDS.GEN_IBUFDS*.IBUFDS_I/O"}]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]

###########################################################################################################
# 100GbE CAUI-4 on the four zSFP28 cages (cmac_100g in the RTL top, built with CMAC_LANES zsfp, as on
# the ZCU216)
#   GT channel sites are fixed by the cmac_caui4_gt IP (X0Y4 X0Y5 X0Y8 X0Y9 = zSFP0..3);
#   the serial pins follow from them. Refclk: 8A34001 Q11 -> MGTREFCLK1_128, which is Y31/Y32 on
#   this package (the ZCU216's Y34/Y35 are other pins here). The daemon programs the 8A34001.
#   The cages' TX_DISABLE are jumpers (J39 / J44 / J32 / J35, ON = transmitter enabled): no pins.
###########################################################################################################
set_property PACKAGE_PIN Y31 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN Y32 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# Everything clocked from the GT refclk (QPLL, TX/RX user clocks) is
# asynchronous to the converter and PS clocks: every crossing goes through an
# XPM CDC macro, which carries its own constraints. One group = async to all.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sfp_refclk]
