// tx_beamformer -- TX beamformer between udp_player (after ch_interleave
// DIR=1) and the DAC axis_broadcaster of an N-channel v49 build
// (Protocol §11 is the contract; §9 the layout).
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
//   CTRL.enable = 1  channel 0's W-bit slice is fanned out to every channel of
//                    the beamformer and output channel c is ch0 x w[c]
//                    (channels 1..N-1 of the input beat are ignored).
// The arithmetic is the beamformer_1.0 IP's datapath, instantiated unmodified
// (PIPE = 0) (src/beamformer_v1_0.sv + src/beamformer_channel.sv, NUM_CH =
// N_CH, AXIS_TDATA_WIDTH = W): per slot
//   P_re = I*wI - Q*wQ, P_im = I*wQ + Q*wI   (32-bit),
//   out  = P[30:15] + P[14]                 (round half up, WRAPS, no saturation)
// so |x|*|w| must stay <= 1 (complex magnitudes) to avoid wrap-around.
//
// Latency: LAT aclk cycles from the s_axis handshake to m_axis_tvalid, the
// same in BOTH modes: input register, K beamformer stages (bypass: a K-deep
// delay line), output register.
//   PIPE = 0 (default)  the IP itself, K = 1 (its single register): LAT = 3.
//   PIPE = 1            the IP's arithmetic re-pipelined, K = 3: LAT = 5.
//                       Bit-identical to the IP (same checker), for 300 MHz
//                       builds: the IP's 1-cycle multiply-add-round path is
//                       about 3.4 ns after synthesis (weight FF -> 2 DSPs ->
//                       carry chain; the IP's async reset keeps its FFs out of
//                       the DSP registers), so it does not close at 300 MHz.
// Switching enable or loading weights therefore never drops, duplicates or
// reorders a beat: each beat carries the enable value sampled when it was
// accepted, and the weight bank changes in a single clock edge (all N
// weights at once), so a beat sees either the whole old or the whole new
// weight set.
//
// Flow control: a LAT-stage pipeline with one global enable,
//   ce = m_axis_tready || !m_axis_tvalid,  s_axis_tready = ce.
// The RFDC DAC holds tready high, so in practice ce = 1 and the block streams
// one beat per clock; when the sink does stall, every stage (including the
// IP, whose m_axis_tready is driven by ce) holds, so nothing is lost and
// m_axis_tdata/tvalid stay stable until accepted (AXI-Stream compliant).
// s_axis_tready depends combinationally on m_axis_tready.
//
// Register map (byte offsets, 16-bit address, [7:2] decoded):
//   0x00 ID    RO  0x5A423031 'ZB01'
//   0x04 CTRL  RW  [0] enable (reset 0)
//   0x08 NCH   RO  N_CH
//   0x0C LOAD  WO  write with bit 0 set: apply W[0..N_CH-1] to the datapath
//                  atomically; reads 0. A LOAD written while the previous one
//                  is still crossing is held and applies the W registers as
//                  they are when it launches (~10 clock cycles later).
//   0x40+4c W[c] RW  c < N_CH: int16 real [15:0], int16 imag [31:16], Q1.15.
//                  Reset 0x00007FFF. Writing W[c] does not change the
//                  datapath until LOAD. W[c >= N_CH] reads 0.
// wstrb is ignored (32-bit writes only), like the other v49 register files.
//
// Weights in the datapath: always the last LOADed set. An s_axi reset sets
// W[c] to the defaults and issues a LOAD of them; an aclk reset clears the IP
// (its reset zeroes its weight bank) and this wrapper immediately re-applies
// the last LOADed set (the defaults if none crossed yet). The datapath is
// therefore never left with the IP's zero weights.
//
// Clock crossings (XPM, they carry their own timing constraints):
//   CTRL.enable  xpm_cdc_single (quasi-static, sampled per beat in aclk)
//   W[]          xpm_cdc_handshake, N_CH*32 bits, LOAD launches it; the
//                destination pulse writes the IP's weight bank in one edge.
//
// Verilog-2001 top, usable as a Vivado block-design module reference; the
// IP's two .sv files must be in the project's sources.

`timescale 1ns / 1ps
`default_nettype none

module tx_beamformer #(
    parameter integer N_CH   = 4,      // 2, 4, 8 or 16
    parameter integer BEAT_W = 128,    // 128, 256, 512 or 1024; BEAT_W/N_CH multiple of 32
    parameter integer PIPE   = 0       // 0: beamformer_v1_0 IP (1-cycle multiply), latency 3
                                       // 1: same math re-pipelined for 300 MHz, latency 5
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
    input  wire [15:0]  s_axi_awaddr,     // only [7:0] decoded
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

    localparam [31:0]  ID   = 32'h5A423031;            // 'ZB01'
    localparam integer W    = BEAT_W / N_CH;           // bits per channel per beat
    localparam integer WW   = N_CH * 32;               // weight bank width
    localparam [31:0]  WDEF = 32'h00007FFF;            // reset weight (0.99997 + 0j)
    localparam integer K    = (PIPE == 0) ? 1 : 3;     // beamformer core register stages
    localparam integer LAT  = K + 2;                   // s_axis -> m_axis, cycles

    // Elaboration-time check: an unsupported combination instantiates a
    // module that does not exist, so the build fails loudly.
    generate
        if ((BEAT_W != 128 && BEAT_W != 256 && BEAT_W != 512 && BEAT_W != 1024) ||
            (N_CH != 2 && N_CH != 4 && N_CH != 8 && N_CH != 16) ||
            (W % 32 != 0) || (W < 32) || (PIPE != 0 && PIPE != 1)) begin : g_bad_param
            tx_beamformer_bad_N_CH_or_BEAT_W u_bad ();
        end
    endgenerate

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // =========================================================================
    // AXI4-Lite register file (s_axi_aclk)
    // =========================================================================
    reg  [31:0]   r_w [0:N_CH-1];
    reg           r_en;
    reg           load_pend;        // LOAD requested, not yet launched
    reg           hs_send = 1'b0;   // xpm_cdc_handshake src_send (not reset: a
                                    // crossing in flight completes across a reset)
    reg  [WW-1:0] hs_data;          // snapshot of W[] held for the crossing
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
            for (i = 0; i < N_CH; i = i + 1) r_w[i] <= WDEF;
            load_pend <= 1'b1;           // push the defaults into the datapath
        end else begin
            // Accept address and data independently, act once both are held.
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
                for (i = 0; i < N_CH; i = i + 1)
                    if (wr_addr[7:2] == 6'h10 + i) r_w[i] <= wr_data;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            // LOAD launcher: snapshot W[] and run one handshake at a time
            // (xpm_cdc_handshake: hold send until rcv, then wait for !rcv).
            if (!hs_send && !hs_rcv && load_pend) begin
                for (i = 0; i < N_CH; i = i + 1) hs_data[32*i +: 32] <= r_w[i];
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
            s_axi_arready <= 1'b1;            // address handshake completes next edge
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
    wire          hs_req;           // one-cycle pulse, hs_out valid and held
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3),
                        .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .WIDTH(WW))
    u_w (.src_clk(s_axi_aclk), .src_in(hs_data), .src_send(hs_send), .src_rcv(hs_rcv),
         .dest_clk(aclk), .dest_out(hs_out), .dest_req(hs_req), .dest_ack(1'b0));

    // Weight-bank write into the IP. After an aclk reset the IP's bank is
    // zero; re-apply the last delivered set (defaults before the first one).
    reg  hs_seen = 1'b0;            // a handshake has delivered weights (no reset)
    reg  reload = 1'b1;             // write the bank on the first cycle out of reset
    always @(posedge aclk) begin
        if (hs_req) hs_seen <= 1'b1;
        if (!aresetn) reload <= 1'b1;
        else          reload <= 1'b0;
    end
    wire [WW-1:0] bfw_tdata  = (hs_req || hs_seen) ? hs_out : {N_CH{WDEF}};
    wire          bfw_tvalid = hs_req || reload;

    // =========================================================================
    // Datapath (aclk): stage 1 input register (d1), the beamformer core
    // (K = 1 register stage for the IP, 3 for PIPE = 1) with a matching
    // K-stage bypass delay line, then the output register. One clock enable.
    // =========================================================================
    reg              v [1:LAT];      // beat valid per stage
    reg [BEAT_W-1:0] d1, dq;
    reg              e1;
    reg [BEAT_W-1:0] bd [1:K];       // bypass delay line (data)
    reg              be [1:K];       //                   (enable of that beat)
    wire [BEAT_W-1:0] core_out;      // channel c at [c*W +: W], K cycles after d1
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

    always @(posedge aclk) begin
        if (ce) begin
            d1 <= s_axis_tdata;
            e1 <= en_a;
            bd[1] <= d1;
            be[1] <= e1;
            for (k = 2; k <= K; k = k + 1) begin
                bd[k] <= bd[k-1];
                be[k] <= be[k-1];
            end
            dq <= be[K] ? core_out : bd[K];
        end
    end

    assign m_axis_tdata  = dq;
    assign m_axis_tvalid = v[LAT];

    wire [W-1:0] fan = d1[W-1:0];    // channel 0's slice, fanned out to all channels

    generate if (PIPE == 0) begin : g_ip

    // The IP: every input is channel 0's slice of the stage-1 beat; the IP's
    // own output register is the single core stage. Its m_axis_tready is the
    // pipeline's clock enable, so it holds exactly when the rest of the
    // pipeline holds. Ports of channels >= N_CH are disabled inside the IP
    // (out of range of its NUM_CH arrays); their outputs are never used.
    wire [16*W-1:0] ip_out;
    assign core_out = ip_out[BEAT_W-1:0];

    beamformer_v1_0 #(.NUM_CH(N_CH), .AXIS_TDATA_WIDTH(W)) u_bf (
        .axis_aclk(aclk), .axis_aresetn(aresetn),
        .s_axis_bfw_tdata(bfw_tdata), .s_axis_bfw_tvalid(bfw_tvalid), .s_axis_bfw_tready(),
        .s_axis0_tdata (fan), .s_axis0_tvalid (v[1]), .s_axis0_tready (),
        .s_axis1_tdata (fan), .s_axis1_tvalid (v[1]), .s_axis1_tready (),
        .s_axis2_tdata (fan), .s_axis2_tvalid (v[1]), .s_axis2_tready (),
        .s_axis3_tdata (fan), .s_axis3_tvalid (v[1]), .s_axis3_tready (),
        .s_axis4_tdata (fan), .s_axis4_tvalid (v[1]), .s_axis4_tready (),
        .s_axis5_tdata (fan), .s_axis5_tvalid (v[1]), .s_axis5_tready (),
        .s_axis6_tdata (fan), .s_axis6_tvalid (v[1]), .s_axis6_tready (),
        .s_axis7_tdata (fan), .s_axis7_tvalid (v[1]), .s_axis7_tready (),
        .s_axis8_tdata (fan), .s_axis8_tvalid (v[1]), .s_axis8_tready (),
        .s_axis9_tdata (fan), .s_axis9_tvalid (v[1]), .s_axis9_tready (),
        .s_axis10_tdata(fan), .s_axis10_tvalid(v[1]), .s_axis10_tready(),
        .s_axis11_tdata(fan), .s_axis11_tvalid(v[1]), .s_axis11_tready(),
        .s_axis12_tdata(fan), .s_axis12_tvalid(v[1]), .s_axis12_tready(),
        .s_axis13_tdata(fan), .s_axis13_tvalid(v[1]), .s_axis13_tready(),
        .s_axis14_tdata(fan), .s_axis14_tvalid(v[1]), .s_axis14_tready(),
        .s_axis15_tdata(fan), .s_axis15_tvalid(v[1]), .s_axis15_tready(),
        .m_axis0_tdata (ip_out[ 0*W +: W]), .m_axis0_tvalid (), .m_axis0_tready (ce),
        .m_axis1_tdata (ip_out[ 1*W +: W]), .m_axis1_tvalid (), .m_axis1_tready (ce),
        .m_axis2_tdata (ip_out[ 2*W +: W]), .m_axis2_tvalid (), .m_axis2_tready (ce),
        .m_axis3_tdata (ip_out[ 3*W +: W]), .m_axis3_tvalid (), .m_axis3_tready (ce),
        .m_axis4_tdata (ip_out[ 4*W +: W]), .m_axis4_tvalid (), .m_axis4_tready (ce),
        .m_axis5_tdata (ip_out[ 5*W +: W]), .m_axis5_tvalid (), .m_axis5_tready (ce),
        .m_axis6_tdata (ip_out[ 6*W +: W]), .m_axis6_tvalid (), .m_axis6_tready (ce),
        .m_axis7_tdata (ip_out[ 7*W +: W]), .m_axis7_tvalid (), .m_axis7_tready (ce),
        .m_axis8_tdata (ip_out[ 8*W +: W]), .m_axis8_tvalid (), .m_axis8_tready (ce),
        .m_axis9_tdata (ip_out[ 9*W +: W]), .m_axis9_tvalid (), .m_axis9_tready (ce),
        .m_axis10_tdata(ip_out[10*W +: W]), .m_axis10_tvalid(), .m_axis10_tready(ce),
        .m_axis11_tdata(ip_out[11*W +: W]), .m_axis11_tvalid(), .m_axis11_tready(ce),
        .m_axis12_tdata(ip_out[12*W +: W]), .m_axis12_tvalid(), .m_axis12_tready(ce),
        .m_axis13_tdata(ip_out[13*W +: W]), .m_axis13_tvalid(), .m_axis13_tready(ce),
        .m_axis14_tdata(ip_out[14*W +: W]), .m_axis14_tvalid(), .m_axis14_tready(ce),
        .m_axis15_tdata(ip_out[15*W +: W]), .m_axis15_tvalid(), .m_axis15_tready(ce)
    );

    end else begin : g_pipe

    // PIPE = 1: the IP's arithmetic re-pipelined for 300 MHz, bit-identical
    // (sim/check_bf.py checks both against the same model). Per lane:
    //   stage A  x, w registered            (DSP AREG/BREG)
    //   stage M  I*wI, Q*wQ, I*wQ, Q*wI     (MREG, 16x16 signed -> 32)
    //   stage P  re = I*wI - Q*wQ + 2^14, im = I*wQ + Q*wI + 2^14  (PREG, 32-bit wrap)
    //   out      re[30:15], im[30:15]
    // (P + 2^14)[30:15] == P[30:15] + P[14] (mod 2^16), the IP's rounding.
    // No resets on these registers, so they pack into the DSP48E2.
    // The weight bank is written in one edge, like the IP's.
    reg [WW-1:0] wbank;
    always @(posedge aclk)
        if (bfw_tvalid) wbank <= bfw_tdata;

    genvar gc, gs;
    for (gc = 0; gc < N_CH; gc = gc + 1) begin : g_ch
        for (gs = 0; gs < W / 32; gs = gs + 1) begin : g_slot
            reg signed [15:0] xi, xq, wi, wq;
            reg signed [31:0] mii, mqq, miq, mqi;
            reg signed [31:0] pre, pim;
            always @(posedge aclk) begin
                if (ce) begin
                    xi  <= fan[32*gs +: 16];
                    xq  <= fan[32*gs + 16 +: 16];
                    wi  <= wbank[32*gc +: 16];
                    wq  <= wbank[32*gc + 16 +: 16];
                    mii <= xi * wi;
                    mqq <= xq * wq;
                    miq <= xi * wq;
                    mqi <= xq * wi;
                    pre <= mii - mqq + 32'sd16384;
                    pim <= miq + mqi + 32'sd16384;
                end
            end
            assign core_out[gc*W + 32*gs +: 32] = {pim[30:15], pre[30:15]};
        end
    end

    end endgenerate

endmodule

`default_nettype wire
