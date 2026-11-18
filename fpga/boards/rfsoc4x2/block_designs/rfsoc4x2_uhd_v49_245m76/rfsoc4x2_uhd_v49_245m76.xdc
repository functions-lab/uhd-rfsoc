###########################################################################################################
# rfsoc4x2_uhd_v49_245m76.xdc -- constraints of rfsoc4x2_uhd_v49_245m76.tcl (every channel count N,
# the 245.76 MHz clock family): the RFSoC 4x2
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

# LMK04828 OUT8 runs at 122.88 MHz for the MTS PL clock (SYSREF 7.68 MHz).
create_clock -name PL_CLK -period 8.138 -waveform {0.000 4.069} [get_ports PL_CLK_clk_p]

# Input delay for PL_SYSREF to meet the MTS requirements (PG269)
set_input_delay -clock [get_clocks PL_CLK] -min -add_delay 2.0 [get_ports PL_SYSREF_clk_p];
set_input_delay -clock [get_clocks PL_CLK] -max -add_delay 2.2 [get_ports PL_SYSREF_clk_p];

# The net is found by its path below the block design instance, so one file serves every design
# name (rfsoc4x2_v49_<N>ch_qsfp).
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]

###########################################################################################################
# 100GbE CAUI-4 on the QSFP28 cage (cmac_100g in the RTL top, built with CMAC_LANES qsfp128,
# fpga/ip/src/cmac_100g)
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

# ---- the low-rate chains (eth100g/rx_rate, tx_rate and their FIR Compiler
# cells; design docs/superpowers/specs/2026-11-17-low-rate-fir-design.md).
# They run on the converter clock at every factor, but their output is used
# only at the RFDC's F = 40, where that clock is <= 62.5 MHz (<= 1/4 of the
# templates' 300-312.5 MHz it is timed at); the daemon never selects a depth
# > 0 at another factor, and the depth registers change only while the chain
# is held in reset. Paths into and out of the chain therefore have 4 cycles.
# The depth-0 bypass (s_axis -> m_axis of each hub, a 2:1 mux) is not a
# chain cell and keeps its single cycle.
set v49_rate_cells [get_cells -hierarchical -filter {NAME =~ "*/eth100g/rx_fir_*" || NAME =~ "*/eth100g/tx_fir_*" || NAME =~ "*/eth100g/rx_rate/*g_stage*" || NAME =~ "*/eth100g/rx_rate/*g_pack*" || NAME =~ "*/eth100g/rx_rate/*pkr_*" || NAME =~ "*/eth100g/rx_rate/*depth_reg*" || NAME =~ "*/eth100g/rx_rate/*run_reg*" || NAME =~ "*/eth100g/tx_rate/*g_stage*" || NAME =~ "*/eth100g/tx_rate/*ub*" || NAME =~ "*/eth100g/tx_rate/*depth_reg*" || NAME =~ "*/eth100g/tx_rate/*run_reg*"}]
set_multicycle_path -setup 4 -from $v49_rate_cells
set_multicycle_path -hold 3  -from $v49_rate_cells
set_multicycle_path -setup 4 -to   $v49_rate_cells
set_multicycle_path -hold 3  -to   $v49_rate_cells
