//==============================================================================
// Module      : beamformer_channel
// Project     : SPEAR-hw / beamformer_v1_0
//------------------------------------------------------------------------------
// Description :
//   Single-channel complex weight multiplier ("phase shifter") used as the
//   per-antenna processing element of beamformer_v1_0.
//
//   For every accepted input sample the module computes the complex product
//
//       y = (x * w) >> 15
//
//   where x = in_i + j*in_q is the incoming IQ sample and w = weight_i +
//   j*weight_q is the beamforming weight held for this channel.  Both operands
//   are Q1.15 fixed point (signed 16-bit, nominal range [-1, +1)), and the
//   arithmetic right shift by 15 returns the result to the same Q1.15 format.
//
// Data format :
//   A 32-bit lane holds one IQ pair, I in the low half, Q in the high half:
//
//       bits [31:16] = Q (signed 16-bit, Q1.15)
//       bits [15: 0] = I (signed 16-bit, Q1.15)
//
//   AXIS_TDATA_WIDTH may be any multiple of 32; NUM_IQ_PAIRS lanes are then
//   processed in parallel in the same clock cycle, all sharing one weight.
//
// Timing      :
//   Fully pipelined, one register stage.  Latency from an accepted input beat
//   to the corresponding output beat is 1 axis_aclk cycle; throughput is one
//   beat per cycle.
//
// Flow control - FREE RUNNING BY DESIGN, DO NOT "FIX" :
//   s_axis_tready is tied high and this block never stalls its source.  That is
//   deliberate: the interfaces are AXI-Stream in shape only, and the datapath
//   does not implement the AXI-Stream flow-control contract.
//
//   The block sits in a real-time converter datapath clocked by the RFDC.  A
//   sample stream coming from an ADC cannot be back-pressured - the converter
//   produces a sample every cycle whether or not anything is ready for it - so
//   there is nothing useful for a tready to do.  Propagating back-pressure here
//   would add a combinational ready path through the whole array and imply a
//   contract the surrounding design does not honour anyway.
//
//   The consequence, and it is intended: an input beat is only processed when
//   m_axis_tready is also asserted, so a sink that stalls loses samples rather
//   than stalling the source.  Every consumer of this IP therefore keeps its
//   sink continuously ready.  A verification environment must model that too -
//   applying random tready to the outputs tests a contract this IP does not
//   implement, and will report dropped beats that are not defects.
//
// Numerics / known limitations:
//   * Rounding is round-half-up: the result is bits [30:15] of the 32-bit
//     product plus bit [14], the most significant discarded bit.  That is
//     bit-exact with ((product + 2^14) >>> 15) truncated to 16 bits.
//   * There is NO saturation, and this matters well before the corner cases.
//     The [30:15] slice can only represent Q1.15 values in [-1, +1), so the
//     output wraps whenever the true product reaches full scale.  Example:
//     x = 0.9 + 0.9j, w = 0.9 - 0.9j gives Re(x*w) = +1.62, and this block
//     emits -0.38 instead.  The safe operating condition is |x| * |w| <= 1
//     using complex magnitudes, not per-component values - so a unit-magnitude
//     phase weight at 45 degrees is 0x5A82 + 0x5A82j (0.707 each), not
//     0x7FFF + 0x7FFFj, whose magnitude is 1.41 and will wrap on strong input.
//   * The 32-bit accumulator is wide enough for every input pair except the
//     single corner I = Q = W_I = W_Q = 0x8000 (-1.0), where I*W_Q + Q*W_I
//     evaluates to +2^31 and wraps in the 32-bit intermediate itself.
//==============================================================================
`timescale 1 ns / 1 ps

module beamformer_channel #(
    // Width of one AXI-Stream data beat.  Must be a multiple of 32 so that it
    // carries a whole number of 16-bit-I / 16-bit-Q pairs.
    parameter int AXIS_TDATA_WIDTH = 32
) (
    // Clock and Reset ---------------------------------------------------------
    input logic axis_aclk,     // Datapath clock; all logic is synchronous to it
    input logic axis_aresetn,  // Active-low asynchronous reset

    // Beamforming weight for this channel, Q1.15 complex:
    //   [31:16] = W_Q (imaginary), [15:0] = W_I (real)
    // Driven from the parent's weight register, so it is stable between
    // weight updates and needs no handshake of its own.
    input logic [31:0] bfw_weight,

    // AXI-Stream slave: input IQ samples --------------------------------------
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic                        s_axis_tvalid,
    output logic                        s_axis_tready,  // Tied high, see header

    // AXI-Stream master: weighted IQ samples ----------------------------------
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis_tdata,
    output logic                        m_axis_tvalid,
    input  logic                        m_axis_tready
);

  // Number of independent IQ pairs carried in one data beat.  Each pair is
  // multiplied by the same weight, in parallel, within one clock cycle.
  localparam int NUM_IQ_PAIRS = AXIS_TDATA_WIDTH / 32;

  // Weight components, reinterpreted as signed Q1.15 values.
  wire signed [15:0] weight_i = bfw_weight[15:0];   // real part
  wire signed [15:0] weight_q = bfw_weight[31:16];  // imaginary part

  // Single output pipeline stage (data + valid).
  logic [AXIS_TDATA_WIDTH-1:0] output_data_r;
  logic                        output_valid_r;

  // Constant: this block never back-pressures its source.  See the flow
  // control note in the header - this is the intended contract, not an
  // oversight, and must not be turned into a real ready.
  assign s_axis_tready = 1'b1;

  // ---------------------------------------------------------------------------
  // Complex multiply stage
  //
  //   (a + jb) * (c + jd) = (ac - bd) + j(ad + bc)
  //     I_out = I_in*W_I - Q_in*W_Q
  //     Q_out = I_in*W_Q + Q_in*W_I
  //
  // A beat is processed when the source presents one and the sink is ready to
  // take the result in the same cycle.  With a continuously ready sink - the
  // only supported configuration - that is every cycle the source is valid.
  // ---------------------------------------------------------------------------
  always_ff @(posedge axis_aclk or negedge axis_aresetn) begin
    if (!axis_aresetn) begin
      output_data_r  <= '0;
      output_valid_r <= 1'b0;
    end else begin
      if (s_axis_tvalid && s_axis_tready && m_axis_tready) begin
        // Process every IQ pair of the beat in parallel.
        for (int i = 0; i < NUM_IQ_PAIRS; i++) begin
          logic signed [15:0] in_i, in_q;              // Q1.15 operands
          logic signed [31:0] out_i_full, out_q_full;  // Q2.30 raw products
          logic signed [15:0] out_i, out_q;            // Q1.15 results

          // Unpack the lane: I in the low half, Q in the high half.
          in_i = s_axis_tdata[i*32+:16];
          in_q = s_axis_tdata[i*32+16+:16];

          // Raw complex product; both terms are Q2.30 after the 16x16 multiply.
          out_i_full = (in_i * weight_i) - (in_q * weight_q);
          out_q_full = (in_i * weight_q) + (in_q * weight_i);

          // Requantise Q2.30 -> Q1.15: arithmetic shift right by 15 with
          // round-half-up (add the most significant discarded bit, [14]).
          // Wrapping, not saturating - see the numerics note in the header.
          out_i = out_i_full[30:15] + out_i_full[14];
          out_q = out_q_full[30:15] + out_q_full[14];

          // Repack into the same {Q, I} lane layout as the input.
          output_data_r[i*32+:16]    <= out_i;
          output_data_r[i*32+16+:16] <= out_q;
        end
        output_valid_r <= 1'b1;
      end else if (m_axis_tready) begin
        // Sink took the previous beat and no new sample arrived: go empty.
        output_valid_r <= 1'b0;
      end
      // Otherwise (sink not ready) hold the beat.  Any input arriving in that
      // window is lost - see the flow control note in the header.
    end
  end

  // Registered outputs: no combinational path from the slave to master side.
  assign m_axis_tdata  = output_data_r;
  assign m_axis_tvalid = output_valid_r;

endmodule
