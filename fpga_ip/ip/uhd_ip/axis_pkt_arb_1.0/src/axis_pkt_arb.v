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
// REG_OUT=1 adds a full-throughput two-entry FIFO on the output. Its
// m_axis_tvalid drops only when the selected source itself has no data, so it
// preserves the no-bubble property, and the sources' tready comes straight
// from a flop. The entries are written only from the arbiter side: their
// enables never see m_axis_tready, which moves just the read pointer and the
// count. The CMAC's tready is its hard block's tx_rdy -- late (clock-to-out
// plus a long route) at 322 MHz -- and as the enable of a 578-bit output
// register and a 578-bit skid register (the previous form, kept as
// sim/axis_pkt_arb_skid_ref.v) it missed timing by ~0.2 ns on ~860 endpoints
// depending on placement. Here it reaches three flops through one LUT;
// m_axis_* is entry[rd] through one 2:1 mux (that path has > 1 ns of slack).
// Port behaviour is cycle-for-cycle that of the previous form
// (sim/tb_axis_pkt_arb.sv).

`timescale 1ns / 1ps
`default_nettype none

module axis_pkt_arb #(
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
        reg  [W-1:0] e0, e1;        // the two entries
        reg          wr, rd;        // write / read pointer
        reg  [1:0]   cnt;           // entries held: 0, 1 or 2
        wire         pop = m_axis_tready && cnt != 2'd0;
        assign a_ready       = !cnt[1];        // room for one more
        assign m_bus         = rd ? e1 : e0;
        assign m_axis_tvalid = cnt != 2'd0;
        always @(posedge clk) begin
            // data: written on the arbiter's handshake only (no reset)
            if (a_hs && !wr) e0 <= a_bus;
            if (a_hs &&  wr) e1 <= a_bus;
            if (!aresetn) begin
                wr <= 1'b0; rd <= 1'b0; cnt <= 2'd0;
            end else begin
                if (a_hs) wr <= !wr;
                if (pop)  rd <= !rd;
                cnt <= cnt + {1'b0, a_hs} - {1'b0, pop};
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
