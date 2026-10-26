//==============================================================================
// Module      : beamformer_v1_0
// Project     : uhd-rfsoc / fpga/ip/src/uhd_ip
//------------------------------------------------------------------------------
// Description :
//   Digital beamforming front end for up to 16 antenna channels (NUM_CH, see
//   the parameter note below - the packaged IP is used at 2, 4 and 8).  Each
//   antenna channel carries its
//   own AXI-Stream of IQ samples and is multiplied by a per-channel complex
//   beamforming weight (BFW), producing a phase-shifted / amplitude-scaled
//   stream on the matching output interface:
//
//       m_axis<n> = (s_axis<n> * W<n>) >> 15        for n = 0 .. NUM_CH-1
//
//   The module itself contains no summation network: it applies the weights
//   and leaves the combining (or per-element DAC drive, in a transmit array) to
//   downstream logic.  All NUM_CH channels are independent and run in lockstep
//   off a single clock.
//
// Structure   :
//                    s_axis_bfw (NUM_CH*32b)
//                          |
//                   +--------------+
//                   | bfw_weights  |  register bank, one 32b weight / channel
//                   +--------------+
//                          |  bfw_weights[ch]
//   s_axis<ch> ----> [ beamformer_channel #(AXIS_TDATA_WIDTH) ] ----> m_axis<ch>
//                          (x NUM_CH, generated)
//
//   The flat per-channel ports are fanned into packed arrays so the channel
//   instances can be produced by a single generate loop.  The ports are kept
//   flat (rather than one wide bus) because Vivado IP packager and IP Integrator
//   infer one AXI-Stream interface per s_axis<n>/m_axis<n> name group.
//
// Data format :
//   Every 32-bit lane - sample or weight - is one complex value in Q1.15:
//       bits [31:16] = Q (signed 16-bit)
//       bits [15: 0] = I (signed 16-bit)
//   s_axis_bfw_tdata packs the NUM_CH weights little-endian by channel:
//       [31:0] = W0, [63:32] = W1, ... [NUM_CH*32-1 : (NUM_CH-1)*32] = W15.
//
// Weight update:
//   s_axis_bfw_tready is tied high, so a single beat on S_AXIS_BFW updates all
//   NUM_CH weights on the next clock edge.  Weights are not double-buffered
//   against the sample stream: a weight beat applied mid-burst takes effect on
//   whichever sample is being processed at that cycle.  Quiesce the sample
//   streams (or accept one boundary sample) when a glitch-free switch matters.
//   Reset clears all weights to zero, which mutes every output.
//
// Timing      :
//   1 axis_aclk cycle of latency, one beat/cycle throughput per channel.
//   Free running: every s_axis<n>_tready is tied high and the array never
//   stalls its sources.  This is deliberate - the block sits in a real-time
//   RFDC datapath where the sample stream cannot be back-pressured - and it
//   means a sink that stalls loses samples.  Keep every sink continuously
//   ready.  See beamformer_channel.sv for the full note, plus the arithmetic,
//   rounding and overflow behaviour.
//
// Verification:
//   Inside tx_beamformer: sim/run_sim_bf.sh (`make sim-bf`) checks every beat
//   bit-exactly against check_bf.py's model of this arithmetic, for every
//   v49 (N_CH, BEAT_W) geometry.
//==============================================================================
`timescale 1 ns / 1 ps

module beamformer_v1_0 #(
    // Number of active antenna channels, 1 to 16.  The flat port list below is
    // always written out for all 16; the IP-XACT package hides the unused ones
    // with per-interface enablement expressions ($NUM_CH >= n), and the array
    // mapping for indices >= NUM_CH becomes an out-of-range packed-array access,
    // which SystemVerilog discards (writes) or reads as X on ports the package
    // leaves unconnected.
    // Note the packaged IP defaults to NUM_CH = 2, not the 16 defaulted here -
    // every block design sets CONFIG.NUM_CH explicitly (2, 4 or 8 in tree).
    // Simulated at NUM_CH = 16 (480/480 beats) and NUM_CH = 4 (120/120).
    parameter int NUM_CH = 16,
    // Width of one sample beat, per channel.  Must be a multiple of 32
    // (one 16-bit I + 16-bit Q pair per 32 bits).
    parameter int AXIS_TDATA_WIDTH = 32
) (
    // Clock and Reset ---------------------------------------------------------
    input logic axis_aclk,     // All interfaces are synchronous to this clock
    input logic axis_aresetn,  // Active-low asynchronous reset

    // AXI-Stream slave: beamforming weights (S_AXIS_BFW) -----------------------
    // NUM_CH*32 = 512 bits: one Q1.15 complex weight per channel, channel 0 in
    // the least significant 32 bits.  tready is tied high; one beat rewrites
    // the whole weight bank.
    input  logic [NUM_CH*32-1:0] s_axis_bfw_tdata,
    input  logic                 s_axis_bfw_tvalid,
    output logic                 s_axis_bfw_tready,

    // AXI-Stream slaves: input IQ samples, one interface per channel ----------
    // tready is tied high on all of them - the array is free running.
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis0_tdata,
    input  logic                        s_axis0_tvalid,
    output logic                        s_axis0_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis1_tdata,
    input  logic                        s_axis1_tvalid,
    output logic                        s_axis1_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis2_tdata,
    input  logic                        s_axis2_tvalid,
    output logic                        s_axis2_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis3_tdata,
    input  logic                        s_axis3_tvalid,
    output logic                        s_axis3_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis4_tdata,
    input  logic                        s_axis4_tvalid,
    output logic                        s_axis4_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis5_tdata,
    input  logic                        s_axis5_tvalid,
    output logic                        s_axis5_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis6_tdata,
    input  logic                        s_axis6_tvalid,
    output logic                        s_axis6_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis7_tdata,
    input  logic                        s_axis7_tvalid,
    output logic                        s_axis7_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis8_tdata,
    input  logic                        s_axis8_tvalid,
    output logic                        s_axis8_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis9_tdata,
    input  logic                        s_axis9_tvalid,
    output logic                        s_axis9_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis10_tdata,
    input  logic                        s_axis10_tvalid,
    output logic                        s_axis10_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis11_tdata,
    input  logic                        s_axis11_tvalid,
    output logic                        s_axis11_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis12_tdata,
    input  logic                        s_axis12_tvalid,
    output logic                        s_axis12_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis13_tdata,
    input  logic                        s_axis13_tvalid,
    output logic                        s_axis13_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis14_tdata,
    input  logic                        s_axis14_tvalid,
    output logic                        s_axis14_tready,
    input  logic [AXIS_TDATA_WIDTH-1:0] s_axis15_tdata,
    input  logic                        s_axis15_tvalid,
    output logic                        s_axis15_tready,

    // AXI-Stream masters: weighted IQ samples, one interface per channel ------
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis0_tdata,
    output logic                        m_axis0_tvalid,
    input  logic                        m_axis0_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis1_tdata,
    output logic                        m_axis1_tvalid,
    input  logic                        m_axis1_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis2_tdata,
    output logic                        m_axis2_tvalid,
    input  logic                        m_axis2_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis3_tdata,
    output logic                        m_axis3_tvalid,
    input  logic                        m_axis3_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis4_tdata,
    output logic                        m_axis4_tvalid,
    input  logic                        m_axis4_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis5_tdata,
    output logic                        m_axis5_tvalid,
    input  logic                        m_axis5_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis6_tdata,
    output logic                        m_axis6_tvalid,
    input  logic                        m_axis6_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis7_tdata,
    output logic                        m_axis7_tvalid,
    input  logic                        m_axis7_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis8_tdata,
    output logic                        m_axis8_tvalid,
    input  logic                        m_axis8_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis9_tdata,
    output logic                        m_axis9_tvalid,
    input  logic                        m_axis9_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis10_tdata,
    output logic                        m_axis10_tvalid,
    input  logic                        m_axis10_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis11_tdata,
    output logic                        m_axis11_tvalid,
    input  logic                        m_axis11_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis12_tdata,
    output logic                        m_axis12_tvalid,
    input  logic                        m_axis12_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis13_tdata,
    output logic                        m_axis13_tvalid,
    input  logic                        m_axis13_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis14_tdata,
    output logic                        m_axis14_tvalid,
    input  logic                        m_axis14_tready,
    output logic [AXIS_TDATA_WIDTH-1:0] m_axis15_tdata,
    output logic                        m_axis15_tvalid,
    input  logic                        m_axis15_tready
);

  // Weight register bank: bfw_weights[ch] feeds channel instance ch.
  logic [NUM_CH-1:0][31:0] bfw_weights;

  // Packed views of the flat per-channel ports, so that the channel instances
  // can be created by one generate loop below.
  logic [NUM_CH-1:0][AXIS_TDATA_WIDTH-1:0] s_axis_tdata_array;
  logic [NUM_CH-1:0] s_axis_tvalid_array;
  logic [NUM_CH-1:0] s_axis_tready_array;
  logic [NUM_CH-1:0][AXIS_TDATA_WIDTH-1:0] m_axis_tdata_array;
  logic [NUM_CH-1:0] m_axis_tvalid_array;
  logic [NUM_CH-1:0] m_axis_tready_array;

  // --------------------------------------------------------------------------
  // Port <-> array mapping (pure wiring, no logic).
  // Written out per channel because Vivado's IP packager derives an AXI-Stream
  // interface from each s_axis<n>_* / m_axis<n>_* port name group.
  // --------------------------------------------------------------------------
  // Inputs: flat ports -> arrays
  assign s_axis_tdata_array[0] = s_axis0_tdata;
  assign s_axis_tvalid_array[0] = s_axis0_tvalid;
  assign s_axis0_tready = s_axis_tready_array[0];
  assign s_axis_tdata_array[1] = s_axis1_tdata;
  assign s_axis_tvalid_array[1] = s_axis1_tvalid;
  assign s_axis1_tready = s_axis_tready_array[1];
  assign s_axis_tdata_array[2] = s_axis2_tdata;
  assign s_axis_tvalid_array[2] = s_axis2_tvalid;
  assign s_axis2_tready = s_axis_tready_array[2];
  assign s_axis_tdata_array[3] = s_axis3_tdata;
  assign s_axis_tvalid_array[3] = s_axis3_tvalid;
  assign s_axis3_tready = s_axis_tready_array[3];
  assign s_axis_tdata_array[4] = s_axis4_tdata;
  assign s_axis_tvalid_array[4] = s_axis4_tvalid;
  assign s_axis4_tready = s_axis_tready_array[4];
  assign s_axis_tdata_array[5] = s_axis5_tdata;
  assign s_axis_tvalid_array[5] = s_axis5_tvalid;
  assign s_axis5_tready = s_axis_tready_array[5];
  assign s_axis_tdata_array[6] = s_axis6_tdata;
  assign s_axis_tvalid_array[6] = s_axis6_tvalid;
  assign s_axis6_tready = s_axis_tready_array[6];
  assign s_axis_tdata_array[7] = s_axis7_tdata;
  assign s_axis_tvalid_array[7] = s_axis7_tvalid;
  assign s_axis7_tready = s_axis_tready_array[7];
  assign s_axis_tdata_array[8] = s_axis8_tdata;
  assign s_axis_tvalid_array[8] = s_axis8_tvalid;
  assign s_axis8_tready = s_axis_tready_array[8];
  assign s_axis_tdata_array[9] = s_axis9_tdata;
  assign s_axis_tvalid_array[9] = s_axis9_tvalid;
  assign s_axis9_tready = s_axis_tready_array[9];
  assign s_axis_tdata_array[10] = s_axis10_tdata;
  assign s_axis_tvalid_array[10] = s_axis10_tvalid;
  assign s_axis10_tready = s_axis_tready_array[10];
  assign s_axis_tdata_array[11] = s_axis11_tdata;
  assign s_axis_tvalid_array[11] = s_axis11_tvalid;
  assign s_axis11_tready = s_axis_tready_array[11];
  assign s_axis_tdata_array[12] = s_axis12_tdata;
  assign s_axis_tvalid_array[12] = s_axis12_tvalid;
  assign s_axis12_tready = s_axis_tready_array[12];
  assign s_axis_tdata_array[13] = s_axis13_tdata;
  assign s_axis_tvalid_array[13] = s_axis13_tvalid;
  assign s_axis13_tready = s_axis_tready_array[13];
  assign s_axis_tdata_array[14] = s_axis14_tdata;
  assign s_axis_tvalid_array[14] = s_axis14_tvalid;
  assign s_axis14_tready = s_axis_tready_array[14];
  assign s_axis_tdata_array[15] = s_axis15_tdata;
  assign s_axis_tvalid_array[15] = s_axis15_tvalid;
  assign s_axis15_tready = s_axis_tready_array[15];

  // Outputs: arrays -> flat ports
  assign m_axis0_tdata = m_axis_tdata_array[0];
  assign m_axis0_tvalid = m_axis_tvalid_array[0];
  assign m_axis_tready_array[0] = m_axis0_tready;
  assign m_axis1_tdata = m_axis_tdata_array[1];
  assign m_axis1_tvalid = m_axis_tvalid_array[1];
  assign m_axis_tready_array[1] = m_axis1_tready;
  assign m_axis2_tdata = m_axis_tdata_array[2];
  assign m_axis2_tvalid = m_axis_tvalid_array[2];
  assign m_axis_tready_array[2] = m_axis2_tready;
  assign m_axis3_tdata = m_axis_tdata_array[3];
  assign m_axis3_tvalid = m_axis_tvalid_array[3];
  assign m_axis_tready_array[3] = m_axis3_tready;
  assign m_axis4_tdata = m_axis_tdata_array[4];
  assign m_axis4_tvalid = m_axis_tvalid_array[4];
  assign m_axis_tready_array[4] = m_axis4_tready;
  assign m_axis5_tdata = m_axis_tdata_array[5];
  assign m_axis5_tvalid = m_axis_tvalid_array[5];
  assign m_axis_tready_array[5] = m_axis5_tready;
  assign m_axis6_tdata = m_axis_tdata_array[6];
  assign m_axis6_tvalid = m_axis_tvalid_array[6];
  assign m_axis_tready_array[6] = m_axis6_tready;
  assign m_axis7_tdata = m_axis_tdata_array[7];
  assign m_axis7_tvalid = m_axis_tvalid_array[7];
  assign m_axis_tready_array[7] = m_axis7_tready;
  assign m_axis8_tdata = m_axis_tdata_array[8];
  assign m_axis8_tvalid = m_axis_tvalid_array[8];
  assign m_axis_tready_array[8] = m_axis8_tready;
  assign m_axis9_tdata = m_axis_tdata_array[9];
  assign m_axis9_tvalid = m_axis_tvalid_array[9];
  assign m_axis_tready_array[9] = m_axis9_tready;
  assign m_axis10_tdata = m_axis_tdata_array[10];
  assign m_axis10_tvalid = m_axis_tvalid_array[10];
  assign m_axis_tready_array[10] = m_axis10_tready;
  assign m_axis11_tdata = m_axis_tdata_array[11];
  assign m_axis11_tvalid = m_axis_tvalid_array[11];
  assign m_axis_tready_array[11] = m_axis11_tready;
  assign m_axis12_tdata = m_axis_tdata_array[12];
  assign m_axis12_tvalid = m_axis_tvalid_array[12];
  assign m_axis_tready_array[12] = m_axis12_tready;
  assign m_axis13_tdata = m_axis_tdata_array[13];
  assign m_axis13_tvalid = m_axis_tvalid_array[13];
  assign m_axis_tready_array[13] = m_axis13_tready;
  assign m_axis14_tdata = m_axis_tdata_array[14];
  assign m_axis14_tvalid = m_axis_tvalid_array[14];
  assign m_axis_tready_array[14] = m_axis14_tready;
  assign m_axis15_tdata = m_axis_tdata_array[15];
  assign m_axis15_tvalid = m_axis_tvalid_array[15];
  assign m_axis_tready_array[15] = m_axis15_tready;

  // --------------------------------------------------------------------------
  // Weight capture: one accepted S_AXIS_BFW beat updates all NUM_CH weights.
  // Reset zeroes the bank, which mutes every output until weights are loaded.
  // --------------------------------------------------------------------------
  always_ff @(posedge axis_aclk or negedge axis_aresetn) begin
    if (!axis_aresetn) begin
      bfw_weights <= '0;
    end else begin
      if (s_axis_bfw_tvalid && s_axis_bfw_tready) begin
        // tdata is packed by channel: [31:0]=W0, [63:32]=W1, ... [511:480]=W15,
        // each word being {Q[31:16], I[15:0]} in Q1.15 format.
        for (int i = 0; i < NUM_CH; i++) begin
          bfw_weights[i] <= s_axis_bfw_tdata[i*32+:32];
        end
      end
    end
  end

  // The weight bank can absorb a beat every cycle, so never back-pressure.
  assign s_axis_bfw_tready = 1'b1;

  // --------------------------------------------------------------------------
  // Per-channel complex multipliers.  All instances are identical and share the
  // clock, reset and pipeline timing; they differ only in the weight and the
  // stream they are wired to.
  // --------------------------------------------------------------------------
  genvar ch;
  generate
    for (ch = 0; ch < NUM_CH; ch++) begin : gen_beamformer_ch
      beamformer_channel #(
          .AXIS_TDATA_WIDTH(AXIS_TDATA_WIDTH)
      ) u_beamformer_ch (
          .axis_aclk    (axis_aclk),
          .axis_aresetn (axis_aresetn),
          // This channel's Q1.15 complex weight, held between BFW updates
          .bfw_weight   (bfw_weights[ch]),
          // Input IQ samples
          .s_axis_tdata (s_axis_tdata_array[ch]),
          .s_axis_tvalid(s_axis_tvalid_array[ch]),
          .s_axis_tready(s_axis_tready_array[ch]),
          // Weighted IQ samples
          .m_axis_tdata (m_axis_tdata_array[ch]),
          .m_axis_tvalid(m_axis_tvalid_array[ch]),
          .m_axis_tready(m_axis_tready_array[ch])
      );
    end
  endgenerate

endmodule
