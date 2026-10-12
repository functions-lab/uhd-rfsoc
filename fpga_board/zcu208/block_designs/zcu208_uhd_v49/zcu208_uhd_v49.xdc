###########################################################################################################
# zcu208_uhd_v49.xdc -- constraints of zcu208_uhd_v49.tcl (every channel count N): the ZCU208 as a
# UHD device over 100 GbE. Only the pins the design uses; the RF converter pins are dedicated.
###########################################################################################################

# axi_gpio_led: led_g / led_r
set_property PACKAGE_PIN AM8  [ get_ports "led_r[0]" ]
set_property PACKAGE_PIN AR12 [ get_ports "led_r[1]" ]
set_property PACKAGE_PIN AM7  [ get_ports "led_g[0]" ]
set_property PACKAGE_PIN AP8  [ get_ports "led_g[1]" ]

set_property IOSTANDARD LVCMOS18 [ get_ports "led_r[0]" ]
set_property IOSTANDARD LVCMOS18 [ get_ports "led_r[1]" ]
set_property IOSTANDARD LVCMOS18 [ get_ports "led_g[0]" ]
set_property IOSTANDARD LVCMOS18 [ get_ports "led_g[1]" ]

# MTS differential inputs from LMK04828 outputs 8 and 9
set_property PACKAGE_PIN AN11 [get_ports PL_CLK_clk_p]
set_property PACKAGE_PIN AP11 [get_ports PL_CLK_clk_n]
set_property PACKAGE_PIN AP18 [get_ports PL_SYSREF_clk_p]
set_property PACKAGE_PIN AR18 [get_ports PL_SYSREF_clk_n]
set_property IOSTANDARD LVDS [get_ports {PL_CLK_clk_p PL_CLK_clk_n}]
set_property IOSTANDARD LVDS [get_ports {PL_SYSREF_clk_p PL_SYSREF_clk_n}]

# LMK04828 OUT8 is reprogrammed to 300 MHz for the MTS PL clock.
create_clock -name PL_CLK -period 3.333 -waveform {0.000 1.666} [get_ports PL_CLK_clk_p]

# Input delay for PL_SYSREF to meet the MTS requirements (PG269)
set_input_delay -clock [get_clocks PL_CLK] -min -add_delay 2.0 [get_ports PL_SYSREF_clk_p];
set_input_delay -clock [get_clocks PL_CLK] -max -add_delay 2.2 [get_ports PL_SYSREF_clk_p];

# The net is found by its path below the block design instance, so one file serves every design
# name (zcu208_v49_<N>ch_qsfp).
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]

###########################################################################################################
# 100GbE CAUI-4 on the four zSFP28 cages (cmac_100g in the RTL top, ip_design/cmac_100g)
#   GT channel sites are fixed by the cmac_caui4_gt IP (GTYE4 X0Y4 X0Y5 = quad 128 = SFP0/1,
#   X0Y8 X0Y9 = quad 129 = SFP2/3); on the xczu48dr-fsvg1517 their serial pins are
#   SFP0 TX Y35/Y36 RX AA38/AA39, SFP1 V35/V36 W38/W39, SFP2 P35/P36 N38/N39, SFP3 N33/N34 M36/M37
#   (zcu208 board files). Refclk: MGTREFCLK1_128 (Y31/Y32), driven on the ZCU208 by the
#   8A34001 (U409) like MGTREFCLK1_128 on the ZCU216 (Q11, 156.25 MHz once programmed).
#   UNVERIFIED on a board: check eth100g/cmac_freq ch1 reads ~156250 kHz after programming.
#   No zSFP28 TX_DISABLE pins: the ZCU208 board files do not list them (a passive DAC
#   cable ignores TX_DISABLE; an optical module needs them driven high).
###########################################################################################################
set_property PACKAGE_PIN Y31 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN Y32 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# Everything clocked from the GT refclk (QPLL, TX/RX user clocks) is
# asynchronous to the converter and PS clocks: every crossing goes through an
# XPM CDC macro, which carries its own constraints. One group = async to all.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sfp_refclk]
