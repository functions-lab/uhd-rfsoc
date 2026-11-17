# board.tcl -- the ZCU111 facts the shared flow (fpga/flow/build.tcl) needs.
# Sourced before the build; every name is board_*. Sources of every fact:
# AGENTS.md here.

# FPGA part and Vivado board part (ships with Vivado: 2021.1, 2022.1, 2024.1)
set board_part       xczu28dr-ffvg1517-2-e
set board_board_part xilinx.com:zcu111:part0:1.4
# vendored Vivado board files, relative to this directory ({} = Vivado's own)
set board_files      {}
# rfsoc/rfsoc_lib/xrfclk/<this>/: the LMX2594 register files that pick the
# clock family of an fs (Protocol §8a)
set board_xrfclk     ZCU111
# converter rate when FS= is not given (MS/s): the ZCU111's top rate
set board_fs_default 4000.0
# clock families: LMX2594 reference (MHz) -> block design (register files
# made in TICS Pro: fpga/boards/zcu111/AGENTS.md). 320: the LMK04208's VCO
# (2880 MHz) / 9 to the LMX2594s, PL_CLK 320, SYSREF 5 (fs 4000); 122.88: its
# VCXO passed through, PL_CLK 122.88, SYSREF 7.68 (fs 3932.16 = 8 x 491.52,
# the 3GPP rates)
set board_families   {320.0 zcu111_uhd_v49_320m 122.88 zcu111_uhd_v49_122m88}
# IP repositories beyond fpga/ip/repo/uhd_ip, relative to fpga/ip/repo: the
# dual RF-ADC I/Q merger (one per channel)
set board_ip_repos   {dual_rf_adc_iq_merger_1.0}
# cmac_100g GT sites (fpga/ip/src/cmac_100g/create_cmac_ip.tcl): the four
# SFP28 cages on GTY quad 128 (X0Y4..X0Y7), the user MGT Si570 (156.25 MHz
# from power-up) on MGTREFCLK1 of quad 129
set board_cmac_lanes sfp128
set board_link       "the SFP28 cages"
# extra top-level outputs held constant: {port value ...}: none (the SFP28
# control lines are jumpers and test points, not FPGA pins)
set board_top_ties   {}
# nets the design XDC constrains by pattern: {pattern CLOCK_DEDICATED_ROUTE ...};
# each must match exactly one net
set board_xdc_nets   {*/MTS_block/BUFG_PL_CLK/U0/BUFG_O* ANY_CMT_COLUMN}
