# create_cmac_ip.tcl -- the two IP cores behind rtl-level cmac_100g.v.
#
#   cmac_caui4     cmac_usplus 3.1, CAUI-4 4x25G, RS-FEC, AXIS, GT in example
#                  design (GT_LOCATION 0), CMACE4_X0Y0, no AXI-Lite (the
#                  bring-up lives in cmac_100g.v, control/status on an AXI GPIO)
#   cmac_caui4_gt  gtwizard_ultrascale 1.7 retargeted to the four zSFP28 lanes:
#                  X0Y4 X0Y5 (quad 128) + X0Y8 X0Y9 (quad 129), master X0Y4,
#                  all four on MGTREFCLK1_128 (8A34001 Q11, Y34/Y35).
#
# Both are generated for GLOBAL synthesis (generate_synth_checkpoint 0): IP
# with an out-of-context checkpoint may not sit inside a block-design module
# reference (filemgmt 56-328), and cmac_100g is one.
#
# CMAC_LANES selects the GT sites: zsfp (default; the zSFP28 cages above) or
# qsfp128 (the RFSoC 4x2 QSFP28: X0Y4..X0Y7, one quad, on MGTREFCLK0_128 from
# its Si570 at 156.25 MHz). qsfp128 sets the Verilog define CMAC_ONE_QUAD, which
# makes the wrapper RTL use quad 128's QPLL0 alone.
#
# CMAC_REFCLK selects the refclk the 8A34001 is programmed to. 156.25 needs a
# fractional QPLL0 (SDM 2^23); 161.1328125 is integer. The QPLL common
# settings live in refclk_<f>/cmac_caui4_common_wrapper.v and must match.

set cmac_dir [file dirname [file normalize [info script]]]
if {![info exists CMAC_REFCLK]} { set CMAC_REFCLK 156.25 }
set fracn [expr {$CMAC_REFCLK == 156.25 ? 8388608 : 0}]
if {![info exists CMAC_LANES]} { set CMAC_LANES zsfp }
switch -- $CMAC_LANES {
  zsfp    { set gt_ch {X0Y9 X0Y8 X0Y5 X0Y4}
            set gt_ref {X0Y4 clk1 X0Y5 clk1 X0Y8 clk1-1 X0Y9 clk1-1} }
  qsfp128 { set gt_ch {X0Y7 X0Y6 X0Y5 X0Y4}
            set gt_ref {X0Y4 clk0 X0Y5 clk0 X0Y6 clk0 X0Y7 clk0} }
  default { error "create_cmac_ip: CMAC_LANES $CMAC_LANES (zsfp or qsfp128)" }
}

create_ip -name cmac_usplus -vendor xilinx.com -library ip -version 3.1 -module_name cmac_caui4
set_property -dict [list \
  CONFIG.CMAC_CAUI4_MODE {1} CONFIG.NUM_LANES {4x25} \
  CONFIG.GT_GROUP_SELECT {X0Y4~X0Y7} CONFIG.CMAC_CORE_SELECT {CMACE4_X0Y0} \
  CONFIG.GT_REF_CLK_FREQ $CMAC_REFCLK CONFIG.GT_DRP_CLK {100} \
  CONFIG.INCLUDE_RS_FEC {1} CONFIG.USER_INTERFACE {AXIS} \
  CONFIG.ENABLE_AXI_INTERFACE {0} CONFIG.INCLUDE_STATISTICS_COUNTERS {1} \
  CONFIG.RX_FLOW_CONTROL {0} CONFIG.TX_FLOW_CONTROL {0} \
  CONFIG.RX_MAX_PACKET_LEN {9600} \
  CONFIG.GT_LOCATION {0} \
] [get_ips cmac_caui4]

create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -version 1.7 -module_name cmac_caui4_gt
set gt [get_ips cmac_caui4_gt]
set_property CONFIG.PRESET {GTY-CAUI_4} $gt
set_property -dict [list \
  CONFIG.CHANNEL_ENABLE $gt_ch \
  CONFIG.TX_MASTER_CHANNEL {X0Y4} CONFIG.RX_MASTER_CHANNEL {X0Y4} \
  CONFIG.GT_DIRECTION {BOTH} \
  CONFIG.TX_LINE_RATE {25.78125} CONFIG.RX_LINE_RATE {25.78125} \
  CONFIG.TX_PLL_TYPE {QPLL0} CONFIG.RX_PLL_TYPE {QPLL0} \
  CONFIG.TX_QPLL_FRACN_NUMERATOR $fracn CONFIG.RX_QPLL_FRACN_NUMERATOR $fracn \
  CONFIG.TX_REFCLK_FREQUENCY $CMAC_REFCLK CONFIG.RX_REFCLK_FREQUENCY $CMAC_REFCLK \
  CONFIG.TX_DATA_ENCODING {RAW} CONFIG.RX_DATA_DECODING {RAW} \
  CONFIG.TX_USER_DATA_WIDTH {80} CONFIG.TX_INT_DATA_WIDTH {80} \
  CONFIG.RX_USER_DATA_WIDTH {80} CONFIG.RX_INT_DATA_WIDTH {80} \
  CONFIG.TX_BUFFER_MODE {1} CONFIG.RX_BUFFER_MODE {1} CONFIG.RX_BUFFER_BYPASS_MODE {MULTI} \
  CONFIG.RX_EQ_MODE {AUTO} CONFIG.INS_LOSS_NYQ {12} CONFIG.RX_PPM_OFFSET {200} \
  CONFIG.FREERUN_FREQUENCY {100} \
  CONFIG.LOCATE_COMMON {EXAMPLE_DESIGN} \
  CONFIG.LOCATE_RESET_CONTROLLER {CORE} \
  CONFIG.LOCATE_TX_USER_CLOCKING {EXAMPLE_DESIGN} \
  CONFIG.LOCATE_RX_USER_CLOCKING {EXAMPLE_DESIGN} \
  CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {EXAMPLE_DESIGN} \
  CONFIG.ENABLE_OPTIONAL_PORTS {loopback_in gtwiz_reset_tx_datapath_in gtwiz_reset_rx_datapath_in rxrecclkout_out gtpowergood_out rxdfelpmreset_in rxlpmen_in rxprbscntreset_in rxprbserr_out rxprbssel_in txprbssel_in rxresetdone_out txresetdone_out rxbufstatus_out drpaddr_in drpdi_in drpen_in drpwe_in drpdo_out drprdy_out drpclk_in txpostcursor_in txprecursor_in txdiffctrl_in eyescanreset_in eyescantrigger_in rxcdrhold_in rxdfelfhold_in txprbsforceerr_in txpolarity_in txinhibit_in txpippmen_in txpippmsel_in rxpolarity_in rxrate_in eyescandataerror_out txctrl0_in txctrl1_in rxctrl0_out rxctrl1_out txbufstatus_out} \
] $gt
set_property -dict [list \
  CONFIG.TX_REFCLK_SOURCE $gt_ref \
  CONFIG.RX_REFCLK_SOURCE $gt_ref \
] $gt

foreach x {cmac_caui4 cmac_caui4_gt} {
  set_property generate_synth_checkpoint 0 [get_files $x.xci]
  generate_target all [get_ips $x]
}

add_files -norecurse [glob $cmac_dir/cmac_*.v]
add_files -norecurse $cmac_dir/refclk_$CMAC_REFCLK/cmac_caui4_common_wrapper.v
if {$CMAC_LANES eq "qsfp128"} {
  set_property verilog_define [concat [get_property verilog_define [current_fileset]] CMAC_ONE_QUAD] [current_fileset]
}
update_compile_order -fileset sources_1
