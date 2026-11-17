# board.tcl -- the ZCU208 facts the shared flow (fpga/flow/build.tcl) needs.
# Sourced before the build; every name is board_*. Sources of every fact:
# AGENTS.md here.

# FPGA part and Vivado board part (ships with Vivado: 2021.1, 2022.1, 2024.1)
set board_part       xczu48dr-fsvg1517-2-e
set board_board_part xilinx.com:zcu208:part0:2.0
# vendored Vivado board files, relative to this directory ({} = Vivado's own)
set board_files      {}
# rfsoc/rfsoc_lib/xrfclk/<this>/: the LMX2594 register files that pick the
# clock family of an fs (Protocol §8a)
set board_xrfclk     ZCU208
# converter rate when FS= is not given (MS/s): the dual RF-ADC's maximum
set board_fs_default 5000.0
# clock families: LMX2594 reference (MHz) -> block design
set board_families   {250.0 zcu208_uhd_v49 245.76 zcu208_uhd_v49_245m76}
# IP repositories beyond fpga/ip/repo/uhd_ip, relative to fpga/ip/repo: the
# dual RF-ADC I/Q merger (one per channel)
set board_ip_repos   {dual_rf_adc_iq_merger_1.0}
# cmac_100g GT sites (fpga/ip/src/cmac_100g/create_cmac_ip.tcl): the four
# zSFP28 cages, one lane each (GTY quads 128 + 129), 8A34001 refclk -- the
# ZCU216's layout
set board_cmac_lanes zsfp
set board_link       "the zSFP28 cages"
# extra top-level outputs held constant: {port value ...}
set board_top_ties   {}
# nets the design XDC constrains by pattern: {pattern CLOCK_DEDICATED_ROUTE ...};
# each must match exactly one net
set board_xdc_nets   {*/MTS_block/IBUFDS_PL_CLK/U0/USE_IBUFDS.GEN_IBUFDS*.IBUFDS_I/O FALSE
                      */MTS_block/BUFG_PL_CLK/U0/BUFG_O* ANY_CMT_COLUMN}
