# board.tcl -- the ZCU216 facts the shared flow (fpga/flow/build.tcl) needs.
# Sourced before the build; every name is board_*.

# FPGA part and Vivado board part (ships with Vivado)
set board_part       xczu49dr-ffvf1760-2-e
set board_board_part xilinx.com:zcu216:part0:2.0
# vendored Vivado board files, relative to this directory ({} = Vivado's own)
set board_files      {}
# rfsoc/rfsoc_lib/xrfclk/<this>/: the LMX2594 register files that pick the
# clock family of an fs (Protocol §8a)
set board_xrfclk     ZCU216
# converter rate when FS= is not given (MS/s)
set board_fs_default 2500.0
# clock families: LMX2594 reference (MHz) -> block design
set board_families   {250.0 zcu216_uhd_v49 245.76 zcu216_uhd_v49_245m76}
# IP repositories beyond fpga/ip/repo/uhd_ip, relative to fpga/ip/repo
set board_ip_repos   {}
# cmac_100g GT sites (fpga/ip/src/cmac_100g/create_cmac_ip.tcl): the four
# zSFP28 cages, one lane each (GTY quads 128 + 129), 8A34001 refclk
set board_cmac_lanes zsfp
set board_link       "the zSFP28 cages"
# extra top-level outputs held constant: {port value ...}
set board_top_ties   {}
# nets the design XDC constrains by pattern: {pattern CLOCK_DEDICATED_ROUTE ...};
# each must match exactly one net
set board_xdc_nets   {*/MTS_block/IBUFDS_PL_CLK/U0/USE_IBUFDS.GEN_IBUFDS*.IBUFDS_I/O FALSE
                      */MTS_block/BUFG_PL_CLK/U0/BUFG_O* ANY_CMT_COLUMN}
