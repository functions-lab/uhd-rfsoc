###########################################################################################################
# zcu216_uhd_v49_245m76.xdc -- constraints of zcu216_uhd_v49_245m76.tcl (every channel count N, the
# 245.76 MHz clock family): the ZCU216 as a
# UHD device over 100 GbE. Only the pins the design uses; the RF converter pins are dedicated and the
# LEDs come from the board flow (axi_gpio_led, led_g_8bits / led_r_8bits). Pin comments from the
# ZCU216 master XDC (10 MAR 2020).
###########################################################################################################

# MTS: PL_CLK (LMK04828, 122.88 MHz) and PL_SYSREF (7.68 MHz) into MTS_block
set_property PACKAGE_PIN D11       [get_ports PL_SYSREF_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L8N_HDGC_AD4N_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_SYSREF_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L8N_HDGC_AD4N_89
set_property PACKAGE_PIN E11       [get_ports PL_SYSREF_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L8P_HDGC_AD4P_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_SYSREF_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L8P_HDGC_AD4P_89
set_property PACKAGE_PIN E9        [get_ports PL_CLK_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L7N_HDGC_AD5N_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_CLK_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L7N_HDGC_AD5N_89
set_property PACKAGE_PIN E10       [get_ports PL_CLK_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L7P_HDGC_AD5P_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_CLK_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L7P_HDGC_AD5P_89

create_clock -period 8.138 -name PL_CLK_clk -waveform {0.000 4.069} [get_ports PL_CLK_clk_p]

# Input delay for PL_SYSREF to meet the MTS requirements (PG269)
set_input_delay -clock [get_clocks PL_CLK_clk] -min -add_delay 2.0 [get_ports PL_SYSREF_clk_p];
set_input_delay -clock [get_clocks PL_CLK_clk] -max -add_delay 2.2 [get_ports PL_SYSREF_clk_p];

# PL_CLK reaches MTS_clk_wiz through a non-dedicated route. The nets are found by their path below
# the block design instance, so one file serves every design name (zcu216_v49_<N>ch_qsfp).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/IBUFDS_PL_CLK/U0/USE_IBUFDS.GEN_IBUFDS*.IBUFDS_I/O"}]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]

###########################################################################################################
# 100GbE CAUI-4 on the four zSFP28 cages (cmac_100g in the RTL top, ip_design/cmac_100g)
#   GT channel sites are fixed by the cmac_caui4_gt IP (X0Y4 X0Y5 X0Y8 X0Y9);
#   the serial pins follow from them. Refclk: 8A34001 Q11 -> MGTREFCLK1_128.
###########################################################################################################
set_property PACKAGE_PIN Y34 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN Y35 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

set_property PACKAGE_PIN K16 [get_ports {sfp_tx_disable_b[0]}]
set_property PACKAGE_PIN K17 [get_ports {sfp_tx_disable_b[1]}]
set_property PACKAGE_PIN K14 [get_ports {sfp_tx_disable_b[2]}]
set_property PACKAGE_PIN K15 [get_ports {sfp_tx_disable_b[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sfp_tx_disable_b[*]}]

# Everything clocked from the GT refclk (QPLL, TX/RX user clocks) is
# asynchronous to the converter and PS clocks: every crossing goes through an
# XPM CDC macro, which carries its own constraints. One group = async to all.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sfp_refclk]
