###########################################################################################################
# rfsoc4x2_uhd_v49.xdc -- constraints of rfsoc4x2_uhd_v49.tcl (every channel count N): the RFSoC 4x2
# as a UHD device over 100 GbE. Only the pins the design uses; the RF converter pins are dedicated.
# Pins from Real Digital's RFSoC4x2-BSP (hw/constraints/4x2_QSFP.xdc, 4x2_LED_PB__SW.xdc) and the
# PYNQ RFSoC4x2 base overlay (boards/RFSoC4x2/base/vivado/constraints/base.xdc, the CMAC refclk).
###########################################################################################################

# axi_gpio_led: led_r / led_g = the red and green of the two RGB LEDs (R_LED_0/1, G_LED_0/1)
set_property PACKAGE_PIN AM8  [ get_ports "led_r[0]" ]
set_property PACKAGE_PIN AR12 [ get_ports "led_r[1]" ]
set_property PACKAGE_PIN AM7  [ get_ports "led_g[0]" ]
set_property PACKAGE_PIN AP8  [ get_ports "led_g[1]" ]

set_property IOSTANDARD LVCMOS18 [ get_ports "led_r[0]" ]
set_property IOSTANDARD LVCMOS18 [ get_ports "led_r[1]" ]
set_property IOSTANDARD LVCMOS18 [ get_ports "led_g[0]" ]
set_property IOSTANDARD LVCMOS18 [ get_ports "led_g[1]" ]

# MTS differential inputs from LMK04828 outputs 8 and 9 (MTS locks with these
# on an RFSoC 4x2)
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
# name (rfsoc4x2_v49_<N>ch_qsfp).
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]

###########################################################################################################
# 100GbE CAUI-4 on the QSFP28 cage (cmac_100g in the RTL top, built with CMAC_LANES qsfp128,
# fpga_ip/ip_design/cmac_100g)
#   GT channel sites are fixed by the cmac_caui4_gt IP: GTYE4 X0Y4..X0Y7 = quad 128, the four QSFP
#   lanes (the RFSoC 4x2 rfsoc_qsfp_offload design: cmac_usplus GT_GROUP_SELECT X0Y4~X0Y7).
#   Refclk: MGTREFCLK0_128 (AA33/AA34), the board's USER_MGT_SI570 at 156.25 MHz (its power-up
#   frequency; nothing programs it).
###########################################################################################################
set_property PACKAGE_PIN AA33 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN AA34 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# Everything clocked from the GT refclk (QPLL, TX/RX user clocks) is
# asynchronous to the converter and PS clocks: every crossing goes through an
# XPM CDC macro, which carries its own constraints. One group = async to all.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sfp_refclk]

# QSFP28 low-speed control, held constant by the RTL top: ResetL high (module out of reset),
# LPMode low (full power), ModSelL low (module selected). A passive DAC cable ignores them; an
# active / optical module needs ResetL high.
set_property PACKAGE_PIN AL21 [get_ports qsfp_resetl]
set_property PACKAGE_PIN AN22 [get_ports qsfp_lpmode]
set_property PACKAGE_PIN AK22 [get_ports qsfp_modsell]
set_property IOSTANDARD LVCMOS18 [get_ports {qsfp_resetl qsfp_lpmode qsfp_modsell}]
