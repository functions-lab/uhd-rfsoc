###########################################################################################################
# zcu216_uhd_v49.xdc -- constraints of zcu216_uhd_v49.tcl (every channel count N): the ZCU216 as a
# UHD device over 100 GbE. Only the pins the design uses; the RF converter pins are dedicated and the
# LEDs come from the board flow (axi_gpio_led, led_g_8bits / led_r_8bits). Pin comments from the
# ZCU216 master XDC (10 MAR 2020).
###########################################################################################################

# MTS: PL_CLK (LMK04828, 300 MHz) and PL_SYSREF (10 MHz) into MTS_block
set_property PACKAGE_PIN D11       [get_ports PL_SYSREF_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L8N_HDGC_AD4N_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_SYSREF_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L8N_HDGC_AD4N_89
set_property PACKAGE_PIN E11       [get_ports PL_SYSREF_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L8P_HDGC_AD4P_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_SYSREF_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L8P_HDGC_AD4P_89
set_property PACKAGE_PIN E9        [get_ports PL_CLK_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L7N_HDGC_AD5N_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_CLK_clk_n] ;# Bank  89 VCCO - VCC1V8   - IO_L7N_HDGC_AD5N_89
set_property PACKAGE_PIN E10       [get_ports PL_CLK_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L7P_HDGC_AD5P_89
set_property IOSTANDARD  LVDS_25   [get_ports PL_CLK_clk_p] ;# Bank  89 VCCO - VCC1V8   - IO_L7P_HDGC_AD5P_89

create_clock -period 3.333 -name PL_CLK_clk -waveform {0.000 1.666} [get_ports PL_CLK_clk_p]

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
