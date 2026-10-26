# board.tcl -- the RFSoC 4x2 facts the shared flow (fpga/flow/build.tcl) needs.
# Sourced before the build; every name is board_*.

# FPGA part and Vivado board part (Real Digital's, vendored in board_files/)
set board_part       xczu48dr-ffvg1517-2-e
set board_board_part realdigital.org:rfsoc4x2:part0:1.0
# vendored Vivado board files, relative to this directory ({} = Vivado's own)
set board_files      board_files
# rfsoc/rfsoc_lib/xrfclk/<this>/: the LMX2594 register files that pick the
# clock family of an fs (Protocol §8a)
set board_xrfclk     RFSoC4x2
# converter rate when FS= is not given (MS/s): the dual RF-ADC's maximum
set board_fs_default 5000.0
# clock families: LMX2594 reference (MHz) -> block design
set board_families   {250.0 rfsoc4x2_uhd_v49 245.76 rfsoc4x2_uhd_v49_245m76}
# IP repositories beyond fpga/ip/repo/uhd_ip, relative to fpga/ip/repo: the
# dual RF-ADC I/Q joiners (N = 1 merger, N = 2 packer)
set board_ip_repos   {dual_rf_adc_iq_merger_1.0 dual_channel_rf_adc_iq_packer_1.0}
# cmac_100g GT sites (fpga/ip/src/cmac_100g/create_cmac_ip.tcl): the QSFP28
# on GTY quad 128, Si570 refclk
set board_cmac_lanes qsfp128
set board_link       "the QSFP28 cage"
# extra top-level outputs held constant: {port value ...}: the QSFP28 module
# out of reset, full power, selected
set board_top_ties   {qsfp_resetl 1 qsfp_lpmode 0 qsfp_modsell 0}
# nets the design XDC constrains by pattern: {pattern CLOCK_DEDICATED_ROUTE ...};
# each must match exactly one net
set board_xdc_nets   {*/MTS_block/BUFG_PL_CLK/U0/BUFG_O* ANY_CMT_COLUMN}
