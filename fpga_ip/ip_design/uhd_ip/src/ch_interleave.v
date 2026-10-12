// ch_interleave -- re-order the 32-bit slots of one AXIS beat between the
// block design's per-channel layout and the sample-major layout of the UDP
// data plane (rfsoc_lib/uhd/PROTOCOL.md section 9).
//
// A slot is one complex int16 sample (I in [15:0], Q in [31:16]). With
// S = BEAT_W / (32*N_CH) samples of each channel per beat:
//
//   channel-major  (axis_combiner / axis_broadcaster layout)
//       channel k occupies bits [k*W +: W], W = BEAT_W/N_CH, holding S
//       consecutive samples of channel k: slot k*S + s = channel k, sample s.
//   sample-major   (udp_streamer / udp_player layout, the wire order)
//       slot i = channel i % N_CH, sample i / N_CH:
//       slot s*N_CH + k = channel k, sample s.
//
//   DIR = 0  channel-major -> sample-major. ADC side, between the axis_combiner
//            and udp_streamer.s_axis.
//   DIR = 1  sample-major -> channel-major. DAC side, between
//            udp_player.m_axis_dac and the axis_broadcaster.
//
// DIR 0 followed by DIR 1 (same N_CH, BEAT_W) is the identity. When
// N_CH*32 == BEAT_W (S = 1) the two layouts coincide and the block is a
// pass-through. N_CH*32 must not exceed BEAT_W.
//
// REG = 0 (default): pure wiring, no logic; tready passed straight through.
// REG = 1: one register stage (AXIS pipeline register without bubbles:
//          s_axis_tready = m_axis_tready || !m_axis_tvalid).
//
// Verilog-2001, usable as a block-design module reference.

`timescale 1ns / 1ps
`default_nettype none

module ch_interleave #(
    parameter integer N_CH   = 1,      // 1, 2, 4, 8 or 16
    parameter integer BEAT_W = 128,    // 128, 256, 512 or 1024
    parameter integer DIR    = 0,      // 0 channel-major -> sample-major, 1 the reverse
    parameter integer REG    = 0       // 1 = register the output
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis" *)
    input  wire              aclk,
    input  wire [BEAT_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    output wire [BEAT_W-1:0] m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready
);

    localparam integer SLOTS = BEAT_W / 32;          // slots per beat
    localparam integer S     = SLOTS / N_CH;         // samples per channel per beat

    // Elaboration-time check: an unsupported combination instantiates a
    // module that does not exist, so the build fails loudly.
    generate
        if ((BEAT_W != 128 && BEAT_W != 256 && BEAT_W != 512 && BEAT_W != 1024) ||
            (N_CH != 1 && N_CH != 2 && N_CH != 4 && N_CH != 8 && N_CH != 16) ||
            (N_CH * 32 > BEAT_W) || (DIR != 0 && DIR != 1)) begin : g_bad_param
            ch_interleave_bad_N_CH_BEAT_W_or_DIR u_bad ();
        end
    endgenerate

    // Slot permutation. For output slot i:
    //   DIR 0: i = s*N_CH + k  <-  input slot k*S + s
    //   DIR 1: i = k*S + s     <-  input slot s*N_CH + k
    wire [BEAT_W-1:0] perm;
    genvar gi;
    generate
        for (gi = 0; gi < SLOTS; gi = gi + 1) begin : g_slot
            if (DIR == 0) begin : g_c2s
                assign perm[32*gi +: 32] = s_axis_tdata[32*((gi % N_CH) * S + gi / N_CH) +: 32];
            end else begin : g_s2c
                assign perm[32*gi +: 32] = s_axis_tdata[32*((gi % S) * N_CH + gi / S) +: 32];
            end
        end
    endgenerate

    generate
        if (REG == 0) begin : g_comb
            assign m_axis_tdata  = perm;
            assign m_axis_tvalid = s_axis_tvalid;
            assign s_axis_tready = m_axis_tready;
        end else begin : g_reg
            reg [BEAT_W-1:0] q_data  = {BEAT_W{1'b0}};
            reg              q_valid = 1'b0;
            assign s_axis_tready = m_axis_tready || !q_valid;
            always @(posedge aclk) begin
                if (s_axis_tready) begin
                    q_data  <= perm;
                    q_valid <= s_axis_tvalid;
                end
            end
            assign m_axis_tdata  = q_data;
            assign m_axis_tvalid = q_valid;
        end
    endgenerate

endmodule

`default_nettype wire
