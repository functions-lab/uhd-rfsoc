// rx_beamformer -- RX beamformer between the RF-ADC (rfdc/M_ADC_AXIS, the
// channel-major beat of all N channels) and the ch_interleave DIR=0 in front
// of udp_streamer, in an N-channel v49 build (rfsoc_lib/uhd/PROTOCOL.md section
// 11 is the contract; section 9 the layout).
//
//   s_axis / m_axis (aclk, the converter AXIS clock)
//       CHANNEL-MAJOR beat: channel k in bits [k*W +: W], W = BEAT_W/N_CH,
//       S = W/32 complex int16 samples per channel per beat (I in [15:0],
//       Q in [31:16] of each 32-bit slot). Same layout in and out.
//   s_axi (s_axi_aclk) AXI4-Lite register file, map below.
//
// Behaviour, chosen per beat (a beat is never split between modes or weight
// sets):
//   CTRL.enable = 0  bit-exact pass-through.
//   CTRL.enable = 1  output channel 0 carries the beam: for every slot s
//                        acc  = sum_c x_c[s] * w[c]            (exact)
//                        y    = sat16((acc + 2^(14+SHIFT)) >>> (15+SHIFT))
//                    per real / imaginary part (round half up, saturated to
//                    [-32768, 32767] -- no wrap-around), with
//                        acc_re = sum_c I_c*wI_c - Q_c*wQ_c
//                        acc_im = sum_c I_c*wQ_c + Q_c*wI_c.
//                    Output channels 1..N-1 carry their input unchanged, so
//                    the host keeps every element (calibration) next to the
//                    beam.
//   With unity weights (0x7FFF) and SHIFT = log2(N) (the reset value), N
//   equal inputs x give y ~= x (gain 32767/32768).
//   The weights are those of the TX beamformer for the same direction: by
//   reciprocity the propagation phase of element c is the same for both, and
//   both apply x * w (no conjugate).
//
// Latency: LAT = 7 + log2(N_CH) aclk cycles from the s_axis handshake to
// m_axis_tvalid, the same in both modes: input register, 3 multiply stages
// (A: x, w and SHIFT registered together; M: four 16x16 products; P: re / im
// differences and sums), log2(N_CH) adder-tree stages, the rounding add, the
// shift, the saturation (into the output register). The pass-through
// channels run through a delay line of the same length.
//
// Flow control: one global clock enable, ce = m_axis_tready || !m_axis_tvalid,
// s_axis_tready = ce (the RF-ADC ignores tready; udp_streamer holds it high).
//
// Register map (byte offsets, 16-bit address, [7:2] decoded):
//   0x00 ID     RO  0x5A523031 'ZR01'
//   0x04 CTRL   RW  [0] enable (reset 0)
//   0x08 NCH    RO  N_CH
//   0x0C LOAD   WO  write with bit 0 set: apply W[0..N_CH-1] AND SHIFT to the
//                   datapath atomically; reads 0 (held while a previous LOAD
//                   is still crossing, like tx_beamformer)
//   0x10 SHIFT  RW  [3:0] extra right shift, reset log2(N_CH); takes effect
//                   on LOAD
//   0x40+4c W[c] RW c < N_CH: int16 real [15:0], int16 imag [31:16], Q1.15.
//                   Reset 0x00007FFF. W[c >= N_CH] reads 0.
// wstrb is ignored (32-bit writes only), like the other v49 register files.
// An s_axi reset sets the defaults and LOADs them; an aclk reset keeps the
// last LOADed set.
//
// Clock crossings (XPM): CTRL.enable xpm_cdc_single; W[] + SHIFT one
// xpm_cdc_handshake launched by LOAD, written to the datapath in one edge.
//
// Verilog-2001, usable as a Vivado block-design module reference. No
// resets on the arithmetic registers, so the products pack into DSP48E2.

`timescale 1ns / 1ps
`default_nettype none

module rx_beamformer #(
    parameter integer N_CH   = 4,      // 2, 4, 8 or 16
    parameter integer BEAT_W = 128     // 128, 256, 512 or 1024; BEAT_W/N_CH multiple of 32
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire              aclk,
    input  wire              aresetn,
    input  wire [BEAT_W-1:0] s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    output wire [BEAT_W-1:0] m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,
    input  wire [15:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output reg          s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output reg          s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output reg          s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [15:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output reg          s_axi_arready,
    output reg  [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output reg          s_axi_rvalid,
    input  wire         s_axi_rready
);

    localparam [31:0]  ID   = 32'h5A523031;            // 'ZR01'
    localparam integer W    = BEAT_W / N_CH;           // bits per channel per beat
    localparam integer S    = W / 32;                  // samples per channel per beat
    localparam integer L    = (N_CH == 2) ? 1 : (N_CH == 4) ? 2 : (N_CH == 8) ? 3 : 4;  // log2(N_CH)
    localparam integer WW   = N_CH * 32 + 4;           // weight bank + SHIFT
    localparam [31:0]  WDEF = 32'h00007FFF;
    localparam [3:0]   SDEF = L;
    localparam integer LAT  = 7 + L;
    localparam integer AW   = 40;                      // accumulator width (33 + log2(16) bits needed)

    generate
        if ((BEAT_W != 128 && BEAT_W != 256 && BEAT_W != 512 && BEAT_W != 1024) ||
            (N_CH != 2 && N_CH != 4 && N_CH != 8 && N_CH != 16) ||
            (W % 32 != 0) || (W < 32)) begin : g_bad_param
            rx_beamformer_bad_N_CH_or_BEAT_W u_bad ();
        end
    endgenerate

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // =========================================================================
    // AXI4-Lite register file (s_axi_aclk)
    // =========================================================================
    reg  [31:0]   r_w [0:N_CH-1];
    reg  [3:0]    r_shift;
    reg           r_en;
    reg           load_pend;
    reg           hs_send = 1'b0;
    reg  [WW-1:0] hs_data;
    wire          hs_rcv;

    reg  [7:0]    wr_addr;
    reg  [31:0]   wr_data;
    reg           aw_seen, w_seen;
    integer       i;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0; w_seen <= 1'b0;
            r_en <= 1'b0;
            r_shift <= SDEF;
            for (i = 0; i < N_CH; i = i + 1) r_w[i] <= WDEF;
            load_pend <= 1'b1;
        end else begin
            if (s_axi_awvalid && !aw_seen) begin
                aw_seen <= 1'b1; wr_addr <= s_axi_awaddr[7:0]; s_axi_awready <= 1'b1;
            end else s_axi_awready <= 1'b0;
            if (s_axi_wvalid && !w_seen) begin
                w_seen <= 1'b1; wr_data <= s_axi_wdata; s_axi_wready <= 1'b1;
            end else s_axi_wready <= 1'b0;

            if (aw_seen && w_seen && !s_axi_bvalid) begin
                aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
                if (wr_addr[7:2] == 6'h01) r_en <= wr_data[0];
                if (wr_addr[7:2] == 6'h03 && wr_data[0]) load_pend <= 1'b1;
                if (wr_addr[7:2] == 6'h04) r_shift <= wr_data[3:0];
                for (i = 0; i < N_CH; i = i + 1)
                    if (wr_addr[7:2] == 6'h10 + i) r_w[i] <= wr_data;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            if (!hs_send && !hs_rcv && load_pend) begin
                for (i = 0; i < N_CH; i = i + 1) hs_data[32*i +: 32] <= r_w[i];
                hs_data[WW-1 -: 4] <= r_shift;
                hs_send   <= 1'b1;
                load_pend <= 1'b0;
            end else if (hs_send && hs_rcv) begin
                hs_send   <= 1'b0;
            end
        end
    end

    reg [7:0] rd_addr;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0;
        end else if (!s_axi_arready && !s_axi_rvalid && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            rd_addr       <= s_axi_araddr[7:0];
        end else if (s_axi_arready) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b1;
            if (rd_addr[7:6] == 2'b01)
                s_axi_rdata <= (rd_addr[5:2] < N_CH) ? r_w[rd_addr[5:2]] : 32'd0;
            else case (rd_addr[7:2])
                6'h00:   s_axi_rdata <= ID;
                6'h01:   s_axi_rdata <= {31'd0, r_en};
                6'h02:   s_axi_rdata <= N_CH;
                6'h04:   s_axi_rdata <= {28'd0, r_shift};
                default: s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Clock-domain crossings -> aclk
    // =========================================================================
    wire en_a;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_en (.src_clk(s_axi_aclk), .src_in(r_en), .dest_clk(aclk), .dest_out(en_a));

    wire [WW-1:0] hs_out;
    wire          hs_req;
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3),
                        .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .WIDTH(WW))
    u_w (.src_clk(s_axi_aclk), .src_in(hs_data), .src_send(hs_send), .src_rcv(hs_rcv),
         .dest_clk(aclk), .dest_out(hs_out), .dest_req(hs_req), .dest_ack(1'b0));

    // weight bank + shift, written in one edge; defaults until the first set
    // crosses, and kept across an aclk reset (no reset on the bank)
    reg [WW-1:0] bank = {SDEF, {N_CH{WDEF}}};
    always @(posedge aclk)
        if (hs_req) bank <= hs_out;

    // =========================================================================
    // Datapath
    // =========================================================================
    reg              v [1:LAT];
    wire             ce = m_axis_tready || !v[LAT];
    assign s_axis_tready = ce;
    integer k;
    always @(posedge aclk) begin
        if (!aresetn) begin
            for (k = 1; k <= LAT; k = k + 1) v[k] <= 1'b0;
        end else if (ce) begin
            v[1] <= s_axis_tvalid;
            for (k = 2; k <= LAT; k = k + 1) v[k] <= v[k-1];
        end
    end

    // stage 1 input register; pass-through delay line with the enable and the
    // shift of each beat (stages 2..LAT-1). The shift is sampled into stage 2
    // in the same edge as the weights (stage A), so a beat never mixes two
    // LOADed sets.
    reg [BEAT_W-1:0] d1;
    reg              e1;
    reg [BEAT_W-1:0] bd [2:LAT-1];
    reg              be [2:LAT-1];
    reg [3:0]        bs [2:LAT-1];
    always @(posedge aclk) begin
        if (ce) begin
            d1  <= s_axis_tdata;
            e1  <= en_a;
            bd[2] <= d1; be[2] <= e1; bs[2] <= bank[WW-1 -: 4];
            for (k = 3; k <= LAT - 1; k = k + 1) begin
                bd[k] <= bd[k-1]; be[k] <= be[k-1]; bs[k] <= bs[k-1];
            end
        end
    end

    // The weights of a beat: sampled with the beat into stage A (all lanes in
    // the same edge), so a LOAD switches between beats, never inside one.
    genvar gc, gs, gl;
    wire [BEAT_W-1:0] beam_ch0;      // the S output slots of channel 0 (W bits used)
    for (gs = 0; gs < S; gs = gs + 1) begin : g_slot
        // per element: A (x, w), M (4 products), P (re, im) -> sum tree
        wire signed [AW-1:0] pre [0:N_CH-1];
        wire signed [AW-1:0] pim [0:N_CH-1];
        for (gc = 0; gc < N_CH; gc = gc + 1) begin : g_el
            reg signed [15:0] xi, xq, wi, wq;
            reg signed [31:0] mii, mqq, miq, mqi;
            reg signed [32:0] rre, rim;
            always @(posedge aclk) begin
                if (ce) begin
                    xi  <= d1[gc*W + 32*gs +: 16];
                    xq  <= d1[gc*W + 32*gs + 16 +: 16];
                    wi  <= bank[32*gc +: 16];
                    wq  <= bank[32*gc + 16 +: 16];
                    mii <= xi * wi;
                    mqq <= xq * wq;
                    miq <= xi * wq;
                    mqi <= xq * wi;
                    rre <= $signed({mii[31], mii}) - $signed({mqq[31], mqq});
                    rim <= $signed({miq[31], miq}) + $signed({mqi[31], mqi});
                end
            end
            assign pre[gc] = {{(AW-33){rre[32]}}, rre};
            assign pim[gc] = {{(AW-33){rim[32]}}, rim};
        end
        // adder tree, one registered level per stage: level l has N_CH>>l nodes
        reg signed [AW-1:0] tre [1:L][0:N_CH/2-1];
        reg signed [AW-1:0] tim [1:L][0:N_CH/2-1];
        for (gl = 1; gl <= L; gl = gl + 1) begin : g_lvl
            for (gc = 0; gc < (N_CH >> gl); gc = gc + 1) begin : g_node
                if (gl == 1) begin : g_leaf
                    always @(posedge aclk)
                        if (ce) begin
                            tre[1][gc] <= pre[2*gc] + pre[2*gc+1];
                            tim[1][gc] <= pim[2*gc] + pim[2*gc+1];
                        end
                end else begin : g_inner
                    always @(posedge aclk)
                        if (ce) begin
                            tre[gl][gc] <= tre[gl-1][2*gc] + tre[gl-1][2*gc+1];
                            tim[gl][gc] <= tim[gl-1][2*gc] + tim[gl-1][2*gc+1];
                        end
                end
            end
        end
        // rounding add (stage LAT-2: the tree root's beat is at LAT-3), shift
        // (stage LAT-1), saturation into the output register (LAT)
        wire [3:0] sh_r = bs[LAT-3];
        wire [3:0] sh_q = bs[LAT-2];
        reg signed [AW-1:0] rre_, rim_, qre, qim;
        always @(posedge aclk)
            if (ce) begin
                rre_ <= tre[L][0] + ($signed({{(AW-1){1'b0}}, 1'b1}) <<< (14 + sh_r));
                rim_ <= tim[L][0] + ($signed({{(AW-1){1'b0}}, 1'b1}) <<< (14 + sh_r));
                qre  <= rre_ >>> (15 + sh_q);
                qim  <= rim_ >>> (15 + sh_q);
            end
        assign beam_ch0[32*gs +: 16] =
            (qre > 32767) ? 16'h7FFF : (qre < -32768) ? 16'h8000 : qre[15:0];
        assign beam_ch0[32*gs + 16 +: 16] =
            (qim > 32767) ? 16'h7FFF : (qim < -32768) ? 16'h8000 : qim[15:0];
    end
    if (W < BEAT_W) begin : g_hi
        assign beam_ch0[BEAT_W-1:W] = {(BEAT_W-W){1'b0}};
    end

    reg [BEAT_W-1:0] dq;
    always @(posedge aclk)
        if (ce) begin
            dq <= bd[LAT-1];
            if (be[LAT-1]) dq[W-1:0] <= beam_ch0[W-1:0];
        end

    assign m_axis_tdata  = dq;
    assign m_axis_tvalid = v[LAT];

endmodule

`default_nettype wire
