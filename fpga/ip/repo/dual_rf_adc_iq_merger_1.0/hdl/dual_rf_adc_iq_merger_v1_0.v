`timescale 1 ns / 1 ps

// Interleave the simultaneous dual RF-ADC I and Q streams while always accepting
// converter output. The ADC cannot be paused; if the capture path stalls,
// samples are deliberately dropped until M_AXIS is ready again.
//
// Each real sample is 16 bits. For N samples per clock:
// S_I_AXIS_TDATA = {I[N-1], ..., I1, I0}
// S_Q_AXIS_TDATA = {Q[N-1], ..., Q1, Q0}
// M_AXIS_TDATA   = {Q[N-1], I[N-1], ..., Q1, I1, Q0, I0}
//
// In this dual-ADC R2C configuration, m20/m21 TVALID are generated together.
// M_AXIS TVALID is qualified with TREADY so changing converter data is never
// advertised as held data during a downstream stall. This boundary is lossy
// by design, matching a continuously-running physical ADC.
module dual_rf_adc_iq_merger_v1_0 #(
    parameter integer C_S_AXIS_TDATA_WIDTH = 64
) (
    input  wire         axis_aclk,
    input  wire         axis_aresetn,

    input  wire [C_S_AXIS_TDATA_WIDTH-1:0] s_i_axis_tdata,
    input  wire         s_i_axis_tvalid,
    output wire         s_i_axis_tready,

    input  wire [C_S_AXIS_TDATA_WIDTH-1:0] s_q_axis_tdata,
    input  wire         s_q_axis_tvalid,
    output wire         s_q_axis_tready,

    output wire [(2*C_S_AXIS_TDATA_WIDTH)-1:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready
);

  // Never backpressure the RFDC converter outputs.
  assign s_i_axis_tready = 1'b1;
  assign s_q_axis_tready = 1'b1;

  // A downstream stall drops converter samples rather than holding or
  // replaying them. Both RFDC valid signals must describe the same cycle.
  assign m_axis_tvalid = s_i_axis_tvalid && s_q_axis_tvalid && m_axis_tready;
  genvar sample_index;
  generate
    for (sample_index = 0;
         sample_index < C_S_AXIS_TDATA_WIDTH / 16;
         sample_index = sample_index + 1) begin : interleave_samples
      assign m_axis_tdata[(2*sample_index)*16 +: 16] =
          s_i_axis_tdata[sample_index*16 +: 16];
      assign m_axis_tdata[(2*sample_index+1)*16 +: 16] =
          s_q_axis_tdata[sample_index*16 +: 16];
    end
  endgenerate

endmodule
