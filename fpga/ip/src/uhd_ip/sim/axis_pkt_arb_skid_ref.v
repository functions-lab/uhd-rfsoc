// axis_pkt_arb_skid_ref -- the previous axis_pkt_arb (REG_OUT=1: output register +
// skid register, both enabled from m_axis_tready), kept unchanged as the
// reference model of sim/tb_axis_pkt_arb.sv: the current axis_pkt_arb must be
// cycle-for-cycle identical at every port.

// axis_pkt_arb -- two-input packet arbiter for the CMAC TX AXIS (512 bit).
//
//   s0_axis  bulk stream (udp_streamer sample frames)
//   s1_axis  short control frames (udp_player ARP replies / status packets);
//            wins when both are waiting at a packet boundary.
//   m_axis   to the CMAC tx_axis.
//
// The grant changes only after a tlast handshake, and within a packet the
// output is valid whenever the granted source is: the arbiter never adds a
// bubble inside a frame (the CMAC forbids TX underrun), and it can pick the
// next packet in the cycle right after a tlast, so back-to-back frames stay
// back-to-back. All in m_axis' clock (tx_clk).
//
// REG_OUT=1 adds a full-throughput register slice (two-entry skid buffer) on
// the output. Its m_axis_tvalid drops only when the selected source itself
// has no data, so it preserves the no-bubble property; m_axis_tready and
// every m_axis output then come straight from flops.

`timescale 1ns / 1ps
`default_nettype none

module axis_pkt_arb_skid_ref #(
    parameter integer REG_OUT = 1
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s0_axis:s1_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire         clk,
    input  wire         aresetn,

    input  wire [511:0] s0_axis_tdata,
    input  wire [63:0]  s0_axis_tkeep,
    input  wire         s0_axis_tvalid,
    input  wire         s0_axis_tlast,
    input  wire         s0_axis_tuser,
    output wire         s0_axis_tready,

    input  wire [511:0] s1_axis_tdata,
    input  wire [63:0]  s1_axis_tkeep,
    input  wire         s1_axis_tvalid,
    input  wire         s1_axis_tlast,
    input  wire         s1_axis_tuser,
    output wire         s1_axis_tready,

    output wire [511:0] m_axis_tdata,
    output wire [63:0]  m_axis_tkeep,
    output wire         m_axis_tvalid,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser,
    input  wire         m_axis_tready
);

    localparam integer W = 512 + 64 + 2;   // {tuser, tlast, tkeep, tdata}

    reg  busy;          // inside a packet
    reg  sel;           // granted input while busy
    // At a boundary the grant is decided combinationally, so the first beat
    // of the next packet can go in the cycle after the previous tlast.
    wire cur     = busy ? sel : s1_axis_tvalid;
    wire a_valid = cur ? s1_axis_tvalid : s0_axis_tvalid;
    wire [W-1:0] a_bus = cur ? {s1_axis_tuser, s1_axis_tlast, s1_axis_tkeep, s1_axis_tdata}
                             : {s0_axis_tuser, s0_axis_tlast, s0_axis_tkeep, s0_axis_tdata};
    wire a_ready;
    wire a_hs    = a_valid && a_ready;

    assign s0_axis_tready = a_ready && !cur;
    assign s1_axis_tready = a_ready &&  cur;

    always @(posedge clk) begin
        if (!aresetn) begin
            busy <= 1'b0; sel <= 1'b0;
        end else if (a_hs) begin
            busy <= !a_bus[W-2];              // tlast ends the grant
            sel  <= cur;
        end
    end

    wire [W-1:0] m_bus;
    generate if (REG_OUT != 0) begin : g_reg
        reg  [W-1:0] m_q, sk_q;
        reg          m_v, sk_v;
        assign a_ready       = !sk_v;
        assign m_bus         = m_q;
        assign m_axis_tvalid = m_v;
        always @(posedge clk) begin
            if (!aresetn) begin
                m_v <= 1'b0; sk_v <= 1'b0;
            end else if (m_axis_tready || !m_v) begin
                // output register free this cycle: refill from skid first
                if (sk_v) begin
                    m_q <= sk_q; m_v <= 1'b1; sk_v <= 1'b0;
                end else begin
                    m_q <= a_bus; m_v <= a_valid;
                end
            end else if (a_hs) begin
                sk_q <= a_bus; sk_v <= 1'b1;   // output stalled: park one beat
            end
        end
    end else begin : g_comb
        assign a_ready       = m_axis_tready;
        assign m_bus         = a_bus;
        assign m_axis_tvalid = a_valid;
    end endgenerate

    assign m_axis_tdata = m_bus[511:0];
    assign m_axis_tkeep = m_bus[575:512];
    assign m_axis_tlast = m_bus[576];
    assign m_axis_tuser = m_bus[577];

endmodule

`default_nettype wire
