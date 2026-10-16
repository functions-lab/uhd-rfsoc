// cmac_100g -- 100GbE (CAUI-4, RS-FEC) on the four ZCU216 zSFP28 cages.
//
// Derived from the Vivado 2021.1 cmac_usplus 3.1 example design (GT in example
// design), retargeted to a split-quad GT: SFP0/1 = GTY X0Y4/X0Y5 (quad 128),
// SFP2/3 = GTY X0Y8/X0Y9 (quad 129), CMACE4_X0Y0, one 156.25 MHz refclk from
// the 8A34001 (Q11) on MGTREFCLK1_128 (Y34/Y35) feeding both QPLL commons.
// The core-support hierarchy below (cmac/cmac_caui4_*.v) is the example's, with
// the split-quad edits proven to place and route.
// With CMAC_ONE_QUAD defined (create_cmac_ip.tcl CMAC_LANES qsfp128: the
// RFSoC 4x2 QSFP28) the four lanes are GTY X0Y4..X0Y7 in quad 128 alone, on
// MGTREFCLK0_128 (its Si570), and only quad 128's QPLL common is built.
//
// What replaces the example's packet generator/monitor:
//   * the CMAC TX/RX 512-bit AXIS on s_axis_tx / m_axis_rx (usr_clk domain,
//     gt_txusrclk2 = 322.265625 MHz; the RX side runs on the same clock),
//   * a bring-up controller doing what the example's does: after reset, RX and
//     RS-FEC on, send RFI until rx aligned, then TX enable (and back to RFI if
//     alignment is lost),
//   * ctl[31:0] in / status[31:0] out for an AXI GPIO (init_clk domain):
//       ctl  [0] GT sys_reset (hold high until the 8A34001 refclk is valid)
//            [1] RS-FEC enable (both directions; must match the NIC)
//            [7:4] rx polarity per lane   [11:8] tx polarity per lane
//            [15:12] rx LPM (1) / DFE (0) per lane   [16] near-end PMA loopback
//       status [0] stat_rx_aligned   [1] stat_rx_status   [2] rsfec lane alignment
//            [6:3] rsfec AM lock 0..3   [10:7] GT power good   [14:11] rx reset done
//            [18:15] tx reset done   [19] usr_tx_reset   [20] usr_rx_reset
//            [21] rx local fault   [22] rx remote fault   [23] rx hi BER
//            [24] tx overflow seen   [25] tx underflow seen   [26] rx misaligned
//            [27] tx enabled   [31:28] 0
//   Lane numbering is SFP0..SFP3; the 100G PCS and RS-FEC re-order lanes, so
//   which breakout leg sits in which cage does not matter. Polarity is NOT
//   auto-corrected.

`timescale 1ps/1ps
`default_nettype wire

(* DowngradeIPIdentifiedWarnings="yes" *)
module cmac_100g
(
    input  [3 :0]   gt_rxp_in,
    input  [3 :0]   gt_rxn_in,
    output [3 :0]   gt_txp_out,
    output [3 :0]   gt_txn_out,
    input  wire     gt_ref_clk_p,
    input  wire     gt_ref_clk_n,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 init_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 100000000" *)
    input  wire     init_clk,          // free-running 100 MHz (also DRP clock)
    input  wire [31:0] ctl,            // init_clk domain (AXI GPIO)
    output wire [31:0] status,         // init_clk domain (AXI GPIO)
    // Measured clock frequencies in kHz (cycles per 1 ms of init_clk), for
    // checking the 8A34001 refclk after programming: expect 156250 / 322266.
    output reg  [31:0] refclk_khz = 32'd0,
    output reg  [31:0] usrclk_khz = 32'd0,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 usr_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis_tx:m_axis_rx, ASSOCIATED_RESET usr_rstn, FREQ_HZ 322265625" *)
    output wire     usr_clk,           // gt_txusrclk2, 322.265625 MHz
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 usr_rstn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire     usr_rstn,          // !usr_tx_reset, usr_clk domain

    input  wire [511:0] s_axis_tx_tdata,
    input  wire [63:0]  s_axis_tx_tkeep,
    input  wire         s_axis_tx_tvalid,
    input  wire         s_axis_tx_tlast,
    input  wire         s_axis_tx_tuser,
    output wire         s_axis_tx_tready,

    output wire [511:0] m_axis_rx_tdata,
    output wire [63:0]  m_axis_rx_tkeep,
    output wire         m_axis_rx_tvalid,
    output wire         m_axis_rx_tlast,
    output wire         m_axis_rx_tuser
);

  // ctl -> init_clk registers (already in init_clk domain via the GPIO)
  reg  [31:0] ctl_d = 32'h0000_F003;
  always @(posedge init_clk) ctl_d <= ctl;
  wire        sys_reset = ctl_d[0];

  wire [11 :0]    gt_loopback_in;

  //// For other GT loopback options please change the value appropriately
  //// For example, for Near End PMA loopback for 4 Lanes update the gt_loopback_in = {4{3'b010}};
  //// For more information and settings on loopback, refer GT Transceivers user guide

  assign gt_loopback_in  = {4{ctl_d[16] ? 3'b010 : 3'b000}};   // near-end PMA loopback

  wire            gt_ref_clk_out;
  wire            usr_rx_reset;
  wire            rx_axis_tvalid;
  wire [511:0]    rx_axis_tdata;
  wire            rx_axis_tlast;
  wire [63:0]     rx_axis_tkeep;
  wire            rx_axis_tuser;

  wire            tx_axis_tready;
  wire            tx_axis_tvalid;
  wire [511:0]    tx_axis_tdata;
  wire            tx_axis_tlast;
  wire [63:0]     tx_axis_tkeep;
  wire            tx_axis_tuser;
  wire            tx_ovfout;
  wire            tx_unfout;
  wire [55:0]     tx_preamblein;
  wire            usr_tx_reset;
  wire            rxusrclk2;
  wire            stat_rx_aligned;
  wire            stat_rx_aligned_err;
  wire [2:0]      stat_rx_bad_code;
  wire [2:0]      stat_rx_bad_fcs;
  wire            stat_rx_bad_preamble;
  wire            stat_rx_bad_sfd;
  wire            stat_rx_bip_err_0;
  wire            stat_rx_bip_err_1;
  wire            stat_rx_bip_err_10;
  wire            stat_rx_bip_err_11;
  wire            stat_rx_bip_err_12;
  wire            stat_rx_bip_err_13;
  wire            stat_rx_bip_err_14;
  wire            stat_rx_bip_err_15;
  wire            stat_rx_bip_err_16;
  wire            stat_rx_bip_err_17;
  wire            stat_rx_bip_err_18;
  wire            stat_rx_bip_err_19;
  wire            stat_rx_bip_err_2;
  wire            stat_rx_bip_err_3;
  wire            stat_rx_bip_err_4;
  wire            stat_rx_bip_err_5;
  wire            stat_rx_bip_err_6;
  wire            stat_rx_bip_err_7;
  wire            stat_rx_bip_err_8;
  wire            stat_rx_bip_err_9;
  wire [19:0]     stat_rx_block_lock;
  wire            stat_rx_broadcast;
  wire [2:0]      stat_rx_fragment;
  wire [1:0]      stat_rx_framing_err_0;
  wire [1:0]      stat_rx_framing_err_1;
  wire [1:0]      stat_rx_framing_err_10;
  wire [1:0]      stat_rx_framing_err_11;
  wire [1:0]      stat_rx_framing_err_12;
  wire [1:0]      stat_rx_framing_err_13;
  wire [1:0]      stat_rx_framing_err_14;
  wire [1:0]      stat_rx_framing_err_15;
  wire [1:0]      stat_rx_framing_err_16;
  wire [1:0]      stat_rx_framing_err_17;
  wire [1:0]      stat_rx_framing_err_18;
  wire [1:0]      stat_rx_framing_err_19;
  wire [1:0]      stat_rx_framing_err_2;
  wire [1:0]      stat_rx_framing_err_3;
  wire [1:0]      stat_rx_framing_err_4;
  wire [1:0]      stat_rx_framing_err_5;
  wire [1:0]      stat_rx_framing_err_6;
  wire [1:0]      stat_rx_framing_err_7;
  wire [1:0]      stat_rx_framing_err_8;
  wire [1:0]      stat_rx_framing_err_9;
  wire            stat_rx_framing_err_valid_0;
  wire            stat_rx_framing_err_valid_1;
  wire            stat_rx_framing_err_valid_10;
  wire            stat_rx_framing_err_valid_11;
  wire            stat_rx_framing_err_valid_12;
  wire            stat_rx_framing_err_valid_13;
  wire            stat_rx_framing_err_valid_14;
  wire            stat_rx_framing_err_valid_15;
  wire            stat_rx_framing_err_valid_16;
  wire            stat_rx_framing_err_valid_17;
  wire            stat_rx_framing_err_valid_18;
  wire            stat_rx_framing_err_valid_19;
  wire            stat_rx_framing_err_valid_2;
  wire            stat_rx_framing_err_valid_3;
  wire            stat_rx_framing_err_valid_4;
  wire            stat_rx_framing_err_valid_5;
  wire            stat_rx_framing_err_valid_6;
  wire            stat_rx_framing_err_valid_7;
  wire            stat_rx_framing_err_valid_8;
  wire            stat_rx_framing_err_valid_9;
  wire            stat_rx_got_signal_os;
  wire            stat_rx_hi_ber;
  wire            stat_rx_inrangeerr;
  wire            stat_rx_internal_local_fault;
  wire            stat_rx_jabber;
  wire            stat_rx_local_fault;
  wire [19:0]     stat_rx_mf_err;
  wire [19:0]     stat_rx_mf_len_err;
  wire [19:0]     stat_rx_mf_repeat_err;
  wire            stat_rx_misaligned;
  wire            stat_rx_multicast;
  wire            stat_rx_oversize;
  wire            stat_rx_packet_1024_1518_bytes;
  wire            stat_rx_packet_128_255_bytes;
  wire            stat_rx_packet_1519_1522_bytes;
  wire            stat_rx_packet_1523_1548_bytes;
  wire            stat_rx_packet_1549_2047_bytes;
  wire            stat_rx_packet_2048_4095_bytes;
  wire            stat_rx_packet_256_511_bytes;
  wire            stat_rx_packet_4096_8191_bytes;
  wire            stat_rx_packet_512_1023_bytes;
  wire            stat_rx_packet_64_bytes;
  wire            stat_rx_packet_65_127_bytes;
  wire            stat_rx_packet_8192_9215_bytes;
  wire            stat_rx_packet_bad_fcs;
  wire            stat_rx_packet_large;
  wire [2:0]      stat_rx_packet_small;
  wire            stat_rx_received_local_fault;
  wire            stat_rx_remote_fault;
  wire            stat_rx_status;
  wire [2:0]      stat_rx_stomped_fcs;
  wire [19:0]     stat_rx_synced;
  wire [19:0]     stat_rx_synced_err;
  wire [2:0]      stat_rx_test_pattern_mismatch;
  wire            stat_rx_toolong;
  wire [6:0]      stat_rx_total_bytes;
  wire [13:0]     stat_rx_total_good_bytes;
  wire            stat_rx_total_good_packets;
  wire [2:0]      stat_rx_total_packets;
  wire            stat_rx_truncated;
  wire [2:0]      stat_rx_undersize;
  wire            stat_rx_unicast;
  wire            stat_rx_vlan;
  wire [19:0]     stat_rx_pcsl_demuxed;
  wire [4:0]      stat_rx_pcsl_number_0;
  wire [4:0]      stat_rx_pcsl_number_1;
  wire [4:0]      stat_rx_pcsl_number_10;
  wire [4:0]      stat_rx_pcsl_number_11;
  wire [4:0]      stat_rx_pcsl_number_12;
  wire [4:0]      stat_rx_pcsl_number_13;
  wire [4:0]      stat_rx_pcsl_number_14;
  wire [4:0]      stat_rx_pcsl_number_15;
  wire [4:0]      stat_rx_pcsl_number_16;
  wire [4:0]      stat_rx_pcsl_number_17;
  wire [4:0]      stat_rx_pcsl_number_18;
  wire [4:0]      stat_rx_pcsl_number_19;
  wire [4:0]      stat_rx_pcsl_number_2;
  wire [4:0]      stat_rx_pcsl_number_3;
  wire [4:0]      stat_rx_pcsl_number_4;
  wire [4:0]      stat_rx_pcsl_number_5;
  wire [4:0]      stat_rx_pcsl_number_6;
  wire [4:0]      stat_rx_pcsl_number_7;
  wire [4:0]      stat_rx_pcsl_number_8;
  wire [4:0]      stat_rx_pcsl_number_9;
  wire            stat_rx_rsfec_am_lock0;
  wire            stat_rx_rsfec_am_lock1;
  wire            stat_rx_rsfec_am_lock2;
  wire            stat_rx_rsfec_am_lock3;
  wire            stat_rx_rsfec_corrected_cw_inc;
  wire            stat_rx_rsfec_cw_inc;
  wire [2:0]      stat_rx_rsfec_err_count0_inc;
  wire [2:0]      stat_rx_rsfec_err_count1_inc;
  wire [2:0]      stat_rx_rsfec_err_count2_inc;
  wire [2:0]      stat_rx_rsfec_err_count3_inc;
  wire            stat_rx_rsfec_hi_ser;
  wire            stat_rx_rsfec_lane_alignment_status;
  wire [13:0]     stat_rx_rsfec_lane_fill_0;
  wire [13:0]     stat_rx_rsfec_lane_fill_1;
  wire [13:0]     stat_rx_rsfec_lane_fill_2;
  wire [13:0]     stat_rx_rsfec_lane_fill_3;
  wire [7:0]      stat_rx_rsfec_lane_mapping;
  wire            stat_rx_rsfec_uncorrected_cw_inc;
  wire            stat_tx_bad_fcs;
  wire            stat_tx_broadcast;
  wire            stat_tx_frame_error;
  wire            stat_tx_local_fault;
  wire            stat_tx_multicast;
  wire            stat_tx_packet_1024_1518_bytes;
  wire            stat_tx_packet_128_255_bytes;
  wire            stat_tx_packet_1519_1522_bytes;
  wire            stat_tx_packet_1523_1548_bytes;
  wire            stat_tx_packet_1549_2047_bytes;
  wire            stat_tx_packet_2048_4095_bytes;
  wire            stat_tx_packet_256_511_bytes;
  wire            stat_tx_packet_4096_8191_bytes;
  wire            stat_tx_packet_512_1023_bytes;
  wire            stat_tx_packet_64_bytes;
  wire            stat_tx_packet_65_127_bytes;
  wire            stat_tx_packet_8192_9215_bytes;
  wire            stat_tx_packet_large;
  wire            stat_tx_packet_small;
  wire [5:0]      stat_tx_total_bytes;
  wire [13:0]     stat_tx_total_good_bytes;
  wire            stat_tx_total_good_packets;
  wire            stat_tx_total_packets;
  wire            stat_tx_unicast;
  wire            stat_tx_vlan;

  wire [7:0]      rx_otn_bip8_0;
  wire [7:0]      rx_otn_bip8_1;
  wire [7:0]      rx_otn_bip8_2;
  wire [7:0]      rx_otn_bip8_3;
  wire [7:0]      rx_otn_bip8_4;
  wire [65:0]     rx_otn_data_0;
  wire [65:0]     rx_otn_data_1;
  wire [65:0]     rx_otn_data_2;
  wire [65:0]     rx_otn_data_3;
  wire [65:0]     rx_otn_data_4;
  wire            rx_otn_ena;
  wire            rx_otn_lane0;
  wire            rx_otn_vlmarker;
  wire [55:0]     rx_preambleout;


  wire            ctl_rx_enable;
  wire            ctl_rx_force_resync;
  wire            ctl_rx_test_pattern;
  wire            ctl_tx_enable;
  wire            ctl_tx_test_pattern;
  wire            ctl_rsfec_ieee_error_indication_mode;
  wire            ctl_rsfec_ieee_error_indication_mode_int;
  wire            ctl_rx_rsfec_enable;
  wire            ctl_rx_rsfec_enable_int;
  wire            ctl_rx_rsfec_enable_correction;
  wire            ctl_rx_rsfec_enable_correction_int;
  wire            ctl_rx_rsfec_enable_indication;
  wire            ctl_rx_rsfec_enable_indication_int;
  wire            ctl_tx_rsfec_enable;
  wire            ctl_tx_rsfec_enable_int;
  wire            ctl_tx_send_idle;
  wire            ctl_tx_send_rfi;
  wire            ctl_tx_send_lfi;
  wire            rx_reset;
  wire            tx_reset;
  wire [3 :0]     gt_rxrecclkout;
  wire [3 :0]     gt_powergoodout;
  wire            gtwiz_reset_tx_datapath;
  wire            gtwiz_reset_rx_datapath;
  wire            txusrclk2;

  wire [3 :0]     gt_eyescanreset;
  wire [3 :0]     gt_eyescantrigger;
  wire [3 :0]     gt_rxcdrhold;
  wire [3 :0]     gt_rxpolarity;
  wire [11 :0]    gt_rxrate;
  wire [19 :0]    gt_txdiffctrl;
  wire [3 :0]     gt_txpolarity;
  wire [3 :0]     gt_txinhibit;
  wire [3 :0]     gt_txpippmen;
  wire [3 :0]     gt_txpippmsel;
  wire [19 :0]    gt_txpostcursor;
  wire [3 :0]     gt_txprbsforceerr;
  wire [19 :0]    gt_txprecursor;
  wire [3 :0]     gt_eyescandataerror;
  wire [7 :0]    gt_txbufstatus;
  wire [3 :0]     gt_rxdfelpmreset;
  wire [3 :0]     gt_rxlpmen;
  wire [3 :0]     gt_rxprbscntreset;
  wire [3 :0]     gt_rxprbserr;
  wire [15 :0]    gt_rxprbssel;
  wire [3 :0]     gt_rxresetdone;
  wire [15 :0]    gt_txprbssel;
  wire [3 :0]     gt_txresetdone;
  wire [11 :0]    gt_rxbufstatus;
  wire [9:0]      gt0_drpaddr;
  wire            gt0_drpen;
  wire [15:0]     gt0_drpdi;
  wire [15:0]     gt0_drpdo;
  wire            gt0_drprdy;
  wire            gt0_drpwe;
  wire [9:0]      gt1_drpaddr;
  wire            gt1_drpen;
  wire [15:0]     gt1_drpdi;
  wire [15:0]     gt1_drpdo;
  wire            gt1_drprdy;
  wire            gt1_drpwe;
  wire [9:0]      gt2_drpaddr;
  wire            gt2_drpen;
  wire [15:0]     gt2_drpdi;
  wire [15:0]     gt2_drpdo;
  wire            gt2_drprdy;
  wire            gt2_drpwe;
  wire [9:0]      gt3_drpaddr;
  wire            gt3_drpen;
  wire [15:0]     gt3_drpdi;
  wire [15:0]     gt3_drpdo;
  wire            gt3_drprdy;
  wire            gt3_drpwe;
  wire [15:0]     common0_drpaddr;
  wire [15:0]     common0_drpdi;
  wire            common0_drpwe;
  wire            common0_drpen;
  wire            common0_drprdy;
  wire [15:0]     common0_drpdo;

  assign gtwiz_reset_tx_datapath    = 1'b0;
  assign gtwiz_reset_rx_datapath    = 1'b0;


cmac_caui4_core_support i_cmac_caui4_core_support
(
    .gt_rxp_in                            (gt_rxp_in),
    .gt_rxn_in                            (gt_rxn_in),
    .gt_txp_out                           (gt_txp_out),
    .gt_txn_out                           (gt_txn_out),
    .gt_txusrclk2                         (txusrclk2),
    .gt_loopback_in                       (gt_loopback_in),
    .gt_rxrecclkout                       (gt_rxrecclkout),
    .gt_powergoodout                      (gt_powergoodout),
    .gtwiz_reset_tx_datapath              (gtwiz_reset_tx_datapath),
    .gtwiz_reset_rx_datapath              (gtwiz_reset_rx_datapath),
    .gt_eyescanreset                      (gt_eyescanreset),
    .gt_eyescantrigger                    (gt_eyescantrigger),
    .gt_rxcdrhold                         (gt_rxcdrhold),
    .gt_rxpolarity                        (gt_rxpolarity),
    .gt_rxrate                            (gt_rxrate),
    .gt_txdiffctrl                        (gt_txdiffctrl),
    .gt_txpolarity                        (gt_txpolarity),
    .gt_txinhibit                         (gt_txinhibit),
    .gt_txpippmen                         (gt_txpippmen),
    .gt_txpippmsel                        (gt_txpippmsel),
    .gt_txpostcursor                      (gt_txpostcursor),
    .gt_txprbsforceerr                    (gt_txprbsforceerr),
    .gt_txprecursor                       (gt_txprecursor),
    .gt_eyescandataerror                  (gt_eyescandataerror),
    .gt_txbufstatus                       (gt_txbufstatus),
    .gt_rxdfelpmreset                     (gt_rxdfelpmreset),
    .gt_rxlpmen                           (gt_rxlpmen),
    .gt_rxprbscntreset                    (gt_rxprbscntreset),
    .gt_rxprbserr                         (gt_rxprbserr),
    .gt_rxprbssel                         (gt_rxprbssel),
    .gt_rxresetdone                       (gt_rxresetdone),
    .gt_txprbssel                         (gt_txprbssel),
    .gt_txresetdone                       (gt_txresetdone),
    .gt_rxbufstatus                       (gt_rxbufstatus),
    .gt0_drpdo                            (gt0_drpdo),
    .gt0_drprdy                           (gt0_drprdy),
    .gt0_drpen                            (gt0_drpen),
    .gt0_drpwe                            (gt0_drpwe),
    .gt0_drpaddr                          (gt0_drpaddr),
    .gt0_drpdi                            (gt0_drpdi),
    .gt1_drpdo                            (gt1_drpdo),
    .gt1_drprdy                           (gt1_drprdy),
    .gt1_drpen                            (gt1_drpen),
    .gt1_drpwe                            (gt1_drpwe),
    .gt1_drpaddr                          (gt1_drpaddr),
    .gt1_drpdi                            (gt1_drpdi),
    .gt2_drpdo                            (gt2_drpdo),
    .gt2_drprdy                           (gt2_drprdy),
    .gt2_drpen                            (gt2_drpen),
    .gt2_drpwe                            (gt2_drpwe),
    .gt2_drpaddr                          (gt2_drpaddr),
    .gt2_drpdi                            (gt2_drpdi),
    .gt3_drpdo                            (gt3_drpdo),
    .gt3_drprdy                           (gt3_drprdy),
    .gt3_drpen                            (gt3_drpen),
    .gt3_drpwe                            (gt3_drpwe),
    .gt3_drpaddr                          (gt3_drpaddr),
    .gt3_drpdi                            (gt3_drpdi),
    .common0_drpaddr                      (common0_drpaddr),
    .common0_drpdi                        (common0_drpdi),
    .common0_drpwe                        (common0_drpwe),
    .common0_drpen                        (common0_drpen),
    .common0_drprdy                       (common0_drprdy),
    .common0_drpdo                        (common0_drpdo),
    .sys_reset                            (sys_reset),
    .gt_ref_clk_p                         (gt_ref_clk_p),
    .gt_ref_clk_n                         (gt_ref_clk_n),
    .init_clk                             (init_clk),
    .gt_ref_clk_out                       (gt_ref_clk_out),

    .rx_axis_tvalid                       (rx_axis_tvalid),
    .rx_axis_tdata                        (rx_axis_tdata),
    .rx_axis_tkeep                        (rx_axis_tkeep),
    .rx_axis_tlast                        (rx_axis_tlast),
    .rx_axis_tuser                        (rx_axis_tuser),
    .rx_otn_bip8_0                        (rx_otn_bip8_0),
    .rx_otn_bip8_1                        (rx_otn_bip8_1),
    .rx_otn_bip8_2                        (rx_otn_bip8_2),
    .rx_otn_bip8_3                        (rx_otn_bip8_3),
    .rx_otn_bip8_4                        (rx_otn_bip8_4),
    .rx_otn_data_0                        (rx_otn_data_0),
    .rx_otn_data_1                        (rx_otn_data_1),
    .rx_otn_data_2                        (rx_otn_data_2),
    .rx_otn_data_3                        (rx_otn_data_3),
    .rx_otn_data_4                        (rx_otn_data_4),
    .rx_otn_ena                           (rx_otn_ena),
    .rx_otn_lane0                         (rx_otn_lane0),
    .rx_otn_vlmarker                      (rx_otn_vlmarker),
    .rx_preambleout                       (rx_preambleout),
    .usr_rx_reset                         (usr_rx_reset),
    .gt_rxusrclk2                         (rxusrclk2),
    .stat_rx_aligned                      (stat_rx_aligned),
    .stat_rx_aligned_err                  (stat_rx_aligned_err),
    .stat_rx_bad_code                     (stat_rx_bad_code),
    .stat_rx_bad_fcs                      (stat_rx_bad_fcs),
    .stat_rx_bad_preamble                 (stat_rx_bad_preamble),
    .stat_rx_bad_sfd                      (stat_rx_bad_sfd),
    .stat_rx_bip_err_0                    (stat_rx_bip_err_0),
    .stat_rx_bip_err_1                    (stat_rx_bip_err_1),
    .stat_rx_bip_err_10                   (stat_rx_bip_err_10),
    .stat_rx_bip_err_11                   (stat_rx_bip_err_11),
    .stat_rx_bip_err_12                   (stat_rx_bip_err_12),
    .stat_rx_bip_err_13                   (stat_rx_bip_err_13),
    .stat_rx_bip_err_14                   (stat_rx_bip_err_14),
    .stat_rx_bip_err_15                   (stat_rx_bip_err_15),
    .stat_rx_bip_err_16                   (stat_rx_bip_err_16),
    .stat_rx_bip_err_17                   (stat_rx_bip_err_17),
    .stat_rx_bip_err_18                   (stat_rx_bip_err_18),
    .stat_rx_bip_err_19                   (stat_rx_bip_err_19),
    .stat_rx_bip_err_2                    (stat_rx_bip_err_2),
    .stat_rx_bip_err_3                    (stat_rx_bip_err_3),
    .stat_rx_bip_err_4                    (stat_rx_bip_err_4),
    .stat_rx_bip_err_5                    (stat_rx_bip_err_5),
    .stat_rx_bip_err_6                    (stat_rx_bip_err_6),
    .stat_rx_bip_err_7                    (stat_rx_bip_err_7),
    .stat_rx_bip_err_8                    (stat_rx_bip_err_8),
    .stat_rx_bip_err_9                    (stat_rx_bip_err_9),
    .stat_rx_block_lock                   (stat_rx_block_lock),
    .stat_rx_broadcast                    (stat_rx_broadcast),
    .stat_rx_fragment                     (stat_rx_fragment),
    .stat_rx_framing_err_0                (stat_rx_framing_err_0),
    .stat_rx_framing_err_1                (stat_rx_framing_err_1),
    .stat_rx_framing_err_10               (stat_rx_framing_err_10),
    .stat_rx_framing_err_11               (stat_rx_framing_err_11),
    .stat_rx_framing_err_12               (stat_rx_framing_err_12),
    .stat_rx_framing_err_13               (stat_rx_framing_err_13),
    .stat_rx_framing_err_14               (stat_rx_framing_err_14),
    .stat_rx_framing_err_15               (stat_rx_framing_err_15),
    .stat_rx_framing_err_16               (stat_rx_framing_err_16),
    .stat_rx_framing_err_17               (stat_rx_framing_err_17),
    .stat_rx_framing_err_18               (stat_rx_framing_err_18),
    .stat_rx_framing_err_19               (stat_rx_framing_err_19),
    .stat_rx_framing_err_2                (stat_rx_framing_err_2),
    .stat_rx_framing_err_3                (stat_rx_framing_err_3),
    .stat_rx_framing_err_4                (stat_rx_framing_err_4),
    .stat_rx_framing_err_5                (stat_rx_framing_err_5),
    .stat_rx_framing_err_6                (stat_rx_framing_err_6),
    .stat_rx_framing_err_7                (stat_rx_framing_err_7),
    .stat_rx_framing_err_8                (stat_rx_framing_err_8),
    .stat_rx_framing_err_9                (stat_rx_framing_err_9),
    .stat_rx_framing_err_valid_0          (stat_rx_framing_err_valid_0),
    .stat_rx_framing_err_valid_1          (stat_rx_framing_err_valid_1),
    .stat_rx_framing_err_valid_10         (stat_rx_framing_err_valid_10),
    .stat_rx_framing_err_valid_11         (stat_rx_framing_err_valid_11),
    .stat_rx_framing_err_valid_12         (stat_rx_framing_err_valid_12),
    .stat_rx_framing_err_valid_13         (stat_rx_framing_err_valid_13),
    .stat_rx_framing_err_valid_14         (stat_rx_framing_err_valid_14),
    .stat_rx_framing_err_valid_15         (stat_rx_framing_err_valid_15),
    .stat_rx_framing_err_valid_16         (stat_rx_framing_err_valid_16),
    .stat_rx_framing_err_valid_17         (stat_rx_framing_err_valid_17),
    .stat_rx_framing_err_valid_18         (stat_rx_framing_err_valid_18),
    .stat_rx_framing_err_valid_19         (stat_rx_framing_err_valid_19),
    .stat_rx_framing_err_valid_2          (stat_rx_framing_err_valid_2),
    .stat_rx_framing_err_valid_3          (stat_rx_framing_err_valid_3),
    .stat_rx_framing_err_valid_4          (stat_rx_framing_err_valid_4),
    .stat_rx_framing_err_valid_5          (stat_rx_framing_err_valid_5),
    .stat_rx_framing_err_valid_6          (stat_rx_framing_err_valid_6),
    .stat_rx_framing_err_valid_7          (stat_rx_framing_err_valid_7),
    .stat_rx_framing_err_valid_8          (stat_rx_framing_err_valid_8),
    .stat_rx_framing_err_valid_9          (stat_rx_framing_err_valid_9),
    .stat_rx_got_signal_os                (stat_rx_got_signal_os),
    .stat_rx_hi_ber                       (stat_rx_hi_ber),
    .stat_rx_inrangeerr                   (stat_rx_inrangeerr),
    .stat_rx_internal_local_fault         (stat_rx_internal_local_fault),
    .stat_rx_jabber                       (stat_rx_jabber),
    .stat_rx_local_fault                  (stat_rx_local_fault),
    .stat_rx_mf_err                       (stat_rx_mf_err),
    .stat_rx_mf_len_err                   (stat_rx_mf_len_err),
    .stat_rx_mf_repeat_err                (stat_rx_mf_repeat_err),
    .stat_rx_misaligned                   (stat_rx_misaligned),
    .stat_rx_multicast                    (stat_rx_multicast),
    .stat_rx_oversize                     (stat_rx_oversize),
    .stat_rx_packet_1024_1518_bytes       (stat_rx_packet_1024_1518_bytes),
    .stat_rx_packet_128_255_bytes         (stat_rx_packet_128_255_bytes),
    .stat_rx_packet_1519_1522_bytes       (stat_rx_packet_1519_1522_bytes),
    .stat_rx_packet_1523_1548_bytes       (stat_rx_packet_1523_1548_bytes),
    .stat_rx_packet_1549_2047_bytes       (stat_rx_packet_1549_2047_bytes),
    .stat_rx_packet_2048_4095_bytes       (stat_rx_packet_2048_4095_bytes),
    .stat_rx_packet_256_511_bytes         (stat_rx_packet_256_511_bytes),
    .stat_rx_packet_4096_8191_bytes       (stat_rx_packet_4096_8191_bytes),
    .stat_rx_packet_512_1023_bytes        (stat_rx_packet_512_1023_bytes),
    .stat_rx_packet_64_bytes              (stat_rx_packet_64_bytes),
    .stat_rx_packet_65_127_bytes          (stat_rx_packet_65_127_bytes),
    .stat_rx_packet_8192_9215_bytes       (stat_rx_packet_8192_9215_bytes),
    .stat_rx_packet_bad_fcs               (stat_rx_packet_bad_fcs),
    .stat_rx_packet_large                 (stat_rx_packet_large),
    .stat_rx_packet_small                 (stat_rx_packet_small),
    .ctl_rx_enable                        (ctl_rx_enable),
    .ctl_rx_force_resync                  (ctl_rx_force_resync),
    .ctl_rx_test_pattern                  (ctl_rx_test_pattern),
    .ctl_rsfec_ieee_error_indication_mode (ctl_rsfec_ieee_error_indication_mode_int),
    .ctl_rx_rsfec_enable                  (ctl_rx_rsfec_enable_int),
    .ctl_rx_rsfec_enable_correction       (ctl_rx_rsfec_enable_correction_int),
    .ctl_rx_rsfec_enable_indication       (ctl_rx_rsfec_enable_indication_int),
    .core_rx_reset                        (1'b0),
    .rx_clk                               (txusrclk2),
    .stat_rx_received_local_fault         (stat_rx_received_local_fault),
    .stat_rx_remote_fault                 (stat_rx_remote_fault),
    .stat_rx_status                       (stat_rx_status),
    .stat_rx_stomped_fcs                  (stat_rx_stomped_fcs),
    .stat_rx_synced                       (stat_rx_synced),
    .stat_rx_synced_err                   (stat_rx_synced_err),
    .stat_rx_test_pattern_mismatch        (stat_rx_test_pattern_mismatch),
    .stat_rx_toolong                      (stat_rx_toolong),
    .stat_rx_total_bytes                  (stat_rx_total_bytes),
    .stat_rx_total_good_bytes             (stat_rx_total_good_bytes),
    .stat_rx_total_good_packets           (stat_rx_total_good_packets),
    .stat_rx_total_packets                (stat_rx_total_packets),
    .stat_rx_truncated                    (stat_rx_truncated),
    .stat_rx_undersize                    (stat_rx_undersize),
    .stat_rx_unicast                      (stat_rx_unicast),
    .stat_rx_vlan                         (stat_rx_vlan),
    .stat_rx_pcsl_demuxed                 (stat_rx_pcsl_demuxed),
    .stat_rx_pcsl_number_0                (stat_rx_pcsl_number_0),
    .stat_rx_pcsl_number_1                (stat_rx_pcsl_number_1),
    .stat_rx_pcsl_number_10               (stat_rx_pcsl_number_10),
    .stat_rx_pcsl_number_11               (stat_rx_pcsl_number_11),
    .stat_rx_pcsl_number_12               (stat_rx_pcsl_number_12),
    .stat_rx_pcsl_number_13               (stat_rx_pcsl_number_13),
    .stat_rx_pcsl_number_14               (stat_rx_pcsl_number_14),
    .stat_rx_pcsl_number_15               (stat_rx_pcsl_number_15),
    .stat_rx_pcsl_number_16               (stat_rx_pcsl_number_16),
    .stat_rx_pcsl_number_17               (stat_rx_pcsl_number_17),
    .stat_rx_pcsl_number_18               (stat_rx_pcsl_number_18),
    .stat_rx_pcsl_number_19               (stat_rx_pcsl_number_19),
    .stat_rx_pcsl_number_2                (stat_rx_pcsl_number_2),
    .stat_rx_pcsl_number_3                (stat_rx_pcsl_number_3),
    .stat_rx_pcsl_number_4                (stat_rx_pcsl_number_4),
    .stat_rx_pcsl_number_5                (stat_rx_pcsl_number_5),
    .stat_rx_pcsl_number_6                (stat_rx_pcsl_number_6),
    .stat_rx_pcsl_number_7                (stat_rx_pcsl_number_7),
    .stat_rx_pcsl_number_8                (stat_rx_pcsl_number_8),
    .stat_rx_pcsl_number_9                (stat_rx_pcsl_number_9),
    .stat_rx_rsfec_am_lock0               (stat_rx_rsfec_am_lock0),
    .stat_rx_rsfec_am_lock1               (stat_rx_rsfec_am_lock1),
    .stat_rx_rsfec_am_lock2               (stat_rx_rsfec_am_lock2),
    .stat_rx_rsfec_am_lock3               (stat_rx_rsfec_am_lock3),
    .stat_rx_rsfec_corrected_cw_inc       (stat_rx_rsfec_corrected_cw_inc),
    .stat_rx_rsfec_cw_inc                 (stat_rx_rsfec_cw_inc),
    .stat_rx_rsfec_err_count0_inc         (stat_rx_rsfec_err_count0_inc),
    .stat_rx_rsfec_err_count1_inc         (stat_rx_rsfec_err_count1_inc),
    .stat_rx_rsfec_err_count2_inc         (stat_rx_rsfec_err_count2_inc),
    .stat_rx_rsfec_err_count3_inc         (stat_rx_rsfec_err_count3_inc),
    .stat_rx_rsfec_hi_ser                 (stat_rx_rsfec_hi_ser),
    .stat_rx_rsfec_lane_alignment_status  (stat_rx_rsfec_lane_alignment_status),
    .stat_rx_rsfec_lane_fill_0            (stat_rx_rsfec_lane_fill_0),
    .stat_rx_rsfec_lane_fill_1            (stat_rx_rsfec_lane_fill_1),
    .stat_rx_rsfec_lane_fill_2            (stat_rx_rsfec_lane_fill_2),
    .stat_rx_rsfec_lane_fill_3            (stat_rx_rsfec_lane_fill_3),
    .stat_rx_rsfec_lane_mapping           (stat_rx_rsfec_lane_mapping),
    .stat_rx_rsfec_uncorrected_cw_inc     (stat_rx_rsfec_uncorrected_cw_inc),
    .stat_tx_bad_fcs                      (stat_tx_bad_fcs),
    .stat_tx_broadcast                    (stat_tx_broadcast),
    .stat_tx_frame_error                  (stat_tx_frame_error),
    .stat_tx_local_fault                  (stat_tx_local_fault),
    .stat_tx_multicast                    (stat_tx_multicast),
    .stat_tx_packet_1024_1518_bytes       (stat_tx_packet_1024_1518_bytes),
    .stat_tx_packet_128_255_bytes         (stat_tx_packet_128_255_bytes),
    .stat_tx_packet_1519_1522_bytes       (stat_tx_packet_1519_1522_bytes),
    .stat_tx_packet_1523_1548_bytes       (stat_tx_packet_1523_1548_bytes),
    .stat_tx_packet_1549_2047_bytes       (stat_tx_packet_1549_2047_bytes),
    .stat_tx_packet_2048_4095_bytes       (stat_tx_packet_2048_4095_bytes),
    .stat_tx_packet_256_511_bytes         (stat_tx_packet_256_511_bytes),
    .stat_tx_packet_4096_8191_bytes       (stat_tx_packet_4096_8191_bytes),
    .stat_tx_packet_512_1023_bytes        (stat_tx_packet_512_1023_bytes),
    .stat_tx_packet_64_bytes              (stat_tx_packet_64_bytes),
    .stat_tx_packet_65_127_bytes          (stat_tx_packet_65_127_bytes),
    .stat_tx_packet_8192_9215_bytes       (stat_tx_packet_8192_9215_bytes),
    .stat_tx_packet_large                 (stat_tx_packet_large),
    .stat_tx_packet_small                 (stat_tx_packet_small),
    .stat_tx_total_bytes                  (stat_tx_total_bytes),
    .stat_tx_total_good_bytes             (stat_tx_total_good_bytes),
    .stat_tx_total_good_packets           (stat_tx_total_good_packets),
    .stat_tx_total_packets                (stat_tx_total_packets),
    .stat_tx_unicast                      (stat_tx_unicast),
    .stat_tx_vlan                         (stat_tx_vlan),


    .ctl_tx_enable                        (ctl_tx_enable),
    .ctl_tx_test_pattern                  (ctl_tx_test_pattern),
    .ctl_tx_rsfec_enable                  (ctl_tx_rsfec_enable_int),
    .ctl_tx_send_idle                     (ctl_tx_send_idle),
    .ctl_tx_send_rfi                      (ctl_tx_send_rfi),
    .ctl_tx_send_lfi                      (ctl_tx_send_lfi),
    .core_tx_reset                        (1'b0),
    .tx_axis_tready                       (tx_axis_tready),
    .tx_axis_tvalid                       (tx_axis_tvalid),
    .tx_axis_tdata                        (tx_axis_tdata),
    .tx_axis_tkeep                        (tx_axis_tkeep),
    .tx_axis_tlast                        (tx_axis_tlast),
    .tx_axis_tuser                        (tx_axis_tuser),
    .tx_ovfout                            (tx_ovfout),
    .tx_unfout                            (tx_unfout),
    .tx_preamblein                        (tx_preamblein),
    .usr_tx_reset                         (usr_tx_reset),


    .core_drp_reset                       (1'b0),
    .drp_clk                              (1'b0),
    .drp_addr                             (10'b0),
    .drp_di                               (16'b0),
    .drp_en                               (1'b0),
    .drp_do                               (),
    .drp_rdy                              (),
    .drp_we                               (1'b0)
);



  // ---------------------------------------------------------------------
  // User data path
  // ---------------------------------------------------------------------
  assign usr_clk          = txusrclk2;
  assign usr_rstn         = ~usr_tx_reset;
  assign tx_axis_tdata    = s_axis_tx_tdata;
  assign tx_axis_tkeep    = s_axis_tx_tkeep;
  assign tx_axis_tvalid   = s_axis_tx_tvalid;
  assign tx_axis_tlast    = s_axis_tx_tlast;
  assign tx_axis_tuser    = s_axis_tx_tuser;
  assign s_axis_tx_tready = tx_axis_tready;
  assign m_axis_rx_tdata  = rx_axis_tdata;
  assign m_axis_rx_tkeep  = rx_axis_tkeep;
  assign m_axis_rx_tvalid = rx_axis_tvalid;
  assign m_axis_rx_tlast  = rx_axis_tlast;
  assign m_axis_rx_tuser  = rx_axis_tuser;
  assign tx_preamblein    = 56'd0;

  // ---------------------------------------------------------------------
  // GT settings (defaults are the example's trans_debug values)
  // ---------------------------------------------------------------------
  assign gt_txpostcursor   = 20'd0;
  assign gt_txprecursor    = 20'd0;
  assign gt_txdiffctrl     = 20'hC6318;
  assign gt_rxlpmen        = ctl_d[15:12];
  assign gt_rxpolarity     = ctl_d[7:4];
  assign gt_txpolarity     = ctl_d[11:8];
  assign gt_eyescanreset   = 4'd0;
  assign gt_eyescantrigger = 4'd0;
  assign gt_rxcdrhold      = 4'd0;
  assign gt_rxrate         = 12'd0;
  assign gt_txinhibit      = 4'd0;
  assign gt_txpippmen      = 4'd0;
  assign gt_txpippmsel     = 4'hF;
  assign gt_txprbsforceerr = 4'd0;
  assign gt_rxdfelpmreset  = 4'd0;
  assign gt_rxprbscntreset = 4'd0;
  assign gt_rxprbssel      = 16'd0;
  assign gt_txprbssel      = 16'd0;
  assign {gt0_drpaddr, gt1_drpaddr, gt2_drpaddr, gt3_drpaddr} = 40'd0;
  assign {gt0_drpdi, gt1_drpdi, gt2_drpdi, gt3_drpdi}         = 64'd0;
  assign {gt0_drpen, gt1_drpen, gt2_drpen, gt3_drpen}         = 4'd0;
  assign {gt0_drpwe, gt1_drpwe, gt2_drpwe, gt3_drpwe}         = 4'd0;
  assign common0_drpaddr = 16'd0;
  assign common0_drpdi   = 16'd0;
  assign common0_drpen   = 1'b0;
  assign common0_drpwe   = 1'b0;

  // ---------------------------------------------------------------------
  // Bring-up controller (usr_clk). Same sequence as the example's
  // cmac_caui4_axis_pkt_gen state machine, without the traffic test.
  // ---------------------------------------------------------------------
  wire rsfec_en_u;
  xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0))
  u_rsfec (.src_clk(init_clk), .src_in(ctl_d[1]), .dest_clk(txusrclk2), .dest_out(rsfec_en_u));

  reg aligned_q, tx_en_q, rfi_q, rx_en_q;
  always @(posedge txusrclk2) begin
    if (usr_tx_reset || usr_rx_reset) begin
      aligned_q <= 1'b0; tx_en_q <= 1'b0; rfi_q <= 1'b0; rx_en_q <= 1'b0;
    end else begin
      aligned_q <= stat_rx_aligned;
      rx_en_q   <= 1'b1;
      // Only remote fault is sent while the link is down (IEEE 802.3 cl.82).
      tx_en_q   <= aligned_q;
      rfi_q     <= ~aligned_q;
    end
  end
  assign ctl_rx_enable                       = rx_en_q;
  assign ctl_rx_force_resync                 = 1'b0;
  assign ctl_rx_test_pattern                 = 1'b0;
  assign ctl_tx_test_pattern                 = 1'b0;
  assign ctl_tx_enable                       = tx_en_q;
  assign ctl_tx_send_rfi                     = rfi_q;
  assign ctl_tx_send_lfi                     = 1'b0;
  assign ctl_tx_send_idle                    = 1'b0;
  assign ctl_tx_rsfec_enable                 = rsfec_en_u;
  assign ctl_rx_rsfec_enable                 = rsfec_en_u;
  assign ctl_rx_rsfec_enable_correction      = rsfec_en_u;
  assign ctl_rx_rsfec_enable_indication      = rsfec_en_u;
  assign ctl_rsfec_ieee_error_indication_mode = rsfec_en_u;
  assign ctl_tx_rsfec_enable_int              = ctl_tx_rsfec_enable;
  assign ctl_rsfec_ieee_error_indication_mode_int = ctl_rsfec_ieee_error_indication_mode;
  assign ctl_rx_rsfec_enable_int              = ctl_rx_rsfec_enable;
  assign ctl_rx_rsfec_enable_correction_int   = ctl_rx_rsfec_enable_correction;
  assign ctl_rx_rsfec_enable_indication_int   = ctl_rx_rsfec_enable_indication;

  // Sticky TX over/underflow: the CMAC flags a frame that stalled mid-packet.
  reg ovf_seen, unf_seen;
  always @(posedge txusrclk2) begin
    if (usr_tx_reset) begin ovf_seen <= 1'b0; unf_seen <= 1'b0; end
    else begin
      if (tx_ovfout) ovf_seen <= 1'b1;
      if (tx_unfout) unf_seen <= 1'b1;
    end
  end

  wire [31:0] status_async = {
      4'd0, tx_en_q, stat_rx_misaligned, unf_seen, ovf_seen,
      stat_rx_hi_ber, stat_rx_remote_fault, stat_rx_local_fault,
      usr_rx_reset, usr_tx_reset, gt_txresetdone, gt_rxresetdone, gt_powergoodout,
      stat_rx_rsfec_am_lock3, stat_rx_rsfec_am_lock2, stat_rx_rsfec_am_lock1, stat_rx_rsfec_am_lock0,
      stat_rx_rsfec_lane_alignment_status, stat_rx_status, stat_rx_aligned};
  xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0), .WIDTH(32))
  u_status (.src_clk(txusrclk2), .src_in(status_async), .dest_clk(init_clk), .dest_out(status));


  // ---------------------------------------------------------------------
  // Frequency counters: free-running binary counters in the measured
  // domains, Gray-crossed to init_clk, differenced every 100000 init_clk
  // cycles (1 ms at 100 MHz). A clock that is absent reads 0.
  // ---------------------------------------------------------------------
  reg  [31:0] refclk_cnt = 32'd0, usrclk_cnt = 32'd0;
  always @(posedge gt_ref_clk_out) refclk_cnt <= refclk_cnt + 32'd1;
  always @(posedge txusrclk2)      usrclk_cnt <= usrclk_cnt + 32'd1;
  wire [31:0] refclk_cnt_i, usrclk_cnt_i;
  xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
  u_fref (.src_clk(gt_ref_clk_out), .src_in_bin(refclk_cnt), .dest_clk(init_clk), .dest_out_bin(refclk_cnt_i));
  xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
  u_fusr (.src_clk(txusrclk2), .src_in_bin(usrclk_cnt), .dest_clk(init_clk), .dest_out_bin(usrclk_cnt_i));
  reg [16:0] gate = 17'd0;
  reg [31:0] refclk_last = 32'd0, usrclk_last = 32'd0;
  always @(posedge init_clk) begin
    if (gate == 17'd99999) begin
      gate        <= 17'd0;
      refclk_khz  <= refclk_cnt_i - refclk_last;
      usrclk_khz  <= usrclk_cnt_i - usrclk_last;
      refclk_last <= refclk_cnt_i;
      usrclk_last <= usrclk_cnt_i;
    end else begin
      gate <= gate + 17'd1;
    end
  end

endmodule
