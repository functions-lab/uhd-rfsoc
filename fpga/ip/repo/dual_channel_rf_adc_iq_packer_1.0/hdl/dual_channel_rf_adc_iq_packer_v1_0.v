`timescale 1 ns / 1 ps

// Statelessly reshuffle two dual RF-ADC I/Q stream pairs into one DMA beat.
// The RFDC outputs run continuously at the full configured fabric rate, so
// this block deliberately ignores every AXIS handshake input: all RFDC slave
// TREADY outputs and the DMA-side master TVALID output are tied high.
//
// Each real sample is 16 bits. For N samples per clock:
//   CHx_I_TDATA = {Ix[N-1], ..., Ix[0]}
//   CHx_Q_TDATA = {Qx[N-1], ..., Qx[0]}
//   CHx_COMPLEX = {Qx[N-1], Ix[N-1], ..., Qx[0], Ix[0]}
//   M_AXIS_TDATA = {CH1_COMPLEX, CH0_COMPLEX}
//
// With the 32-bit RFDC inputs used by the 2-channel design, little-endian CPU
// int16 order is CH0 I0,Q0,I1,Q1 followed by CH1 I0,Q0,I1,Q1.
module dual_channel_rf_adc_iq_packer_v1_0 #(
    parameter integer C_S_AXIS_TDATA_WIDTH = 32
) (
    input  wire axis_aclk,
    input  wire axis_aresetn,

    input  wire [C_S_AXIS_TDATA_WIDTH-1:0] s_ch0_i_axis_tdata,
    input  wire s_ch0_i_axis_tvalid,
    output wire s_ch0_i_axis_tready,

    input  wire [C_S_AXIS_TDATA_WIDTH-1:0] s_ch0_q_axis_tdata,
    input  wire s_ch0_q_axis_tvalid,
    output wire s_ch0_q_axis_tready,

    input  wire [C_S_AXIS_TDATA_WIDTH-1:0] s_ch1_i_axis_tdata,
    input  wire s_ch1_i_axis_tvalid,
    output wire s_ch1_i_axis_tready,

    input  wire [C_S_AXIS_TDATA_WIDTH-1:0] s_ch1_q_axis_tdata,
    input  wire s_ch1_q_axis_tvalid,
    output wire s_ch1_q_axis_tready,

    output wire [(4*C_S_AXIS_TDATA_WIDTH)-1:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input  wire m_axis_tready
);

  // These ports remain on the packaged AXIS interfaces, but none of them
  // controls data movement in this full-rate, continuously-valid datapath.
  assign s_ch0_i_axis_tready = 1'b1;
  assign s_ch0_q_axis_tready = 1'b1;
  assign s_ch1_i_axis_tready = 1'b1;
  assign s_ch1_q_axis_tready = 1'b1;
  assign m_axis_tvalid = 1'b1;

  genvar sample_index;
  generate
    for (sample_index = 0;
         sample_index < C_S_AXIS_TDATA_WIDTH / 16;
         sample_index = sample_index + 1) begin : interleave_samples
      assign m_axis_tdata[(2*sample_index)*16 +: 16] =
          s_ch0_i_axis_tdata[sample_index*16 +: 16];
      assign m_axis_tdata[(2*sample_index+1)*16 +: 16] =
          s_ch0_q_axis_tdata[sample_index*16 +: 16];
      assign m_axis_tdata[2*C_S_AXIS_TDATA_WIDTH +
                          (2*sample_index)*16 +: 16] =
          s_ch1_i_axis_tdata[sample_index*16 +: 16];
      assign m_axis_tdata[2*C_S_AXIS_TDATA_WIDTH +
                          (2*sample_index+1)*16 +: 16] =
          s_ch1_q_axis_tdata[sample_index*16 +: 16];
    end
  endgenerate

endmodule
