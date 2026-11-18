// rx_rate -- the RX low-rate chain's hub: the converter beat -> K FIR
// Compiler ÷2 stages -> the beat of the depth in force (rates below the
// RFDC's F = 40; design docs/superpowers/specs/2026-11-17-low-rate-fir-design.md,
// arithmetic fpga/ip/src/uhd_ip/rate/LANES.md, model sim/check_rate.py).
//
//   s_axis  (aclk) the channel-major converter beat, N_CH x SPC slots
//                  (channel c sample s at slot c*SPC + s, I low, Q high);
//                  the RF-ADC ignores tready (held 1).
//   m_axis  (aclk) the same beat format: DEPTH 0 = s_axis itself
//                  (combinational: today's path), DEPTH k = the samples
//                  decimated by 2^k, one beat per 2^k cycles in steady state
//                  (tvalid; tready ignored, like the RF-ADC's).
//   m_st<i>g<g> / s_st<i>g<g>  stage i (1 = next to the RFDC), FIR
//                  instance g (G instances of 2 N_CH / G paths each): to its
//                  s_axis_data, from its m_axis_data. Lanes are I and Q of
//                  every channel (lane 2c = I, 2c+1 = Q of channel c),
//                  sample-major in tdata (16-bit lanes in, 40-bit full
//                  precision out). Each FIR is the 26-tap odd branch of the
//                  half-band (32 taps) at max(SPC >> i, 1) samples per valid.
//   depth_o, fir_aresetn_o (aclk) for tx_rate and every FIR of both chains.
//   s_axi   (s_axi_aclk) the register file below.
//
// Stage i (polyphase half-band ÷2): the input stream x (max(SPC >> (i-1), 1)
// samples per valid) splits into xe[m] = x[2m] -> the FIR, and xo[m] =
// x[2m+1] -> a CD-sample delay (CD = 16, half the FIR's 32 taps: the
// 63-tap half-band of rate_hb.coe); y[m] = sat16((fir[m] + 65536 xo[m-CD] +
// 2^16) >>> 17). Every stage runs always; DEPTH only picks which one's output
// is packed into m_axis. Change DEPTH only with the chain held in reset
// (CTRL[0] = 1), never while streaming.
//
// Register map (byte offsets; AXI-Lite at 0x8009_0000 in the v49 builds):
//   0x00 ID     RO  0x5A525431 'ZRT1'
//   0x04 CTRL   RW  [0] chain reset (1 = held; reset value 1)
//   0x08 DEPTH  RW  [3:0] 0..K; a write above K is ignored
//   0x0C INFO   RO  [3:0] K, [11:8] log2(SPC), [20:16] N_CH, [25:24] G
//   0x10 STATUS RO  [0] a stage-input stall seen, [1] a centre FIFO overflow
//                   (sticky since the last chain reset; both mean lost samples)
// CTRL and DEPTH cross to aclk on XPM synchronisers (quasi-static).

`timescale 1ns / 1ps
`default_nettype none

module rx_rate #(
    parameter integer N_CH = 1,        // 1, 2, 4, 8, 16
    parameter integer SPC  = 4,        // samples per channel per beat: 1, 2, 4, 8
    parameter integer K    = 5,        // stages: 1 .. 6
    parameter integer G    = 1         // FIR instances per stage: 1, or 2 when 2 N_CH > 16
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis:m_st1g0:s_st1g0:m_st1g1:s_st1g1:m_st2g0:s_st2g0:m_st2g1:s_st2g1:m_st3g0:s_st3g0:m_st3g1:s_st3g1:m_st4g0:s_st4g0:m_st4g1:s_st4g1:m_st5g0:s_st5g0:m_st5g1:s_st5g1:m_st6g0:s_st6g0:m_st6g1:s_st6g1, ASSOCIATED_RESET aresetn:fir_aresetn_o" *)
    input  wire aclk,
    input  wire aresetn,
    input  wire [N_CH*SPC*32-1:0] s_axis_tdata,
    input  wire s_axis_tvalid,
    output wire s_axis_tready,
    output wire [N_CH*SPC*32-1:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input  wire m_axis_tready,
    // stage 1, FIR instance 0: m_st1g0 -> its s_axis_data, s_st1g0 <- its m_axis_data
    output wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 16-1:0] m_st1g0_tdata,
    output wire m_st1g0_tvalid,
    input  wire m_st1g0_tready,
    input  wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 40-1:0] s_st1g0_tdata,
    input  wire s_st1g0_tvalid,
    output wire s_st1g0_tready,
    // stage 1, FIR instance 1: m_st1g1 -> its s_axis_data, s_st1g1 <- its m_axis_data
    output wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 16-1:0] m_st1g1_tdata,
    output wire m_st1g1_tvalid,
    input  wire m_st1g1_tready,
    input  wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 40-1:0] s_st1g1_tdata,
    input  wire s_st1g1_tvalid,
    output wire s_st1g1_tready,
    // stage 2, FIR instance 0: m_st2g0 -> its s_axis_data, s_st2g0 <- its m_axis_data
    output wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 16-1:0] m_st2g0_tdata,
    output wire m_st2g0_tvalid,
    input  wire m_st2g0_tready,
    input  wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 40-1:0] s_st2g0_tdata,
    input  wire s_st2g0_tvalid,
    output wire s_st2g0_tready,
    // stage 2, FIR instance 1: m_st2g1 -> its s_axis_data, s_st2g1 <- its m_axis_data
    output wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 16-1:0] m_st2g1_tdata,
    output wire m_st2g1_tvalid,
    input  wire m_st2g1_tready,
    input  wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 40-1:0] s_st2g1_tdata,
    input  wire s_st2g1_tvalid,
    output wire s_st2g1_tready,
    // stage 3, FIR instance 0: m_st3g0 -> its s_axis_data, s_st3g0 <- its m_axis_data
    output wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 16-1:0] m_st3g0_tdata,
    output wire m_st3g0_tvalid,
    input  wire m_st3g0_tready,
    input  wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 40-1:0] s_st3g0_tdata,
    input  wire s_st3g0_tvalid,
    output wire s_st3g0_tready,
    // stage 3, FIR instance 1: m_st3g1 -> its s_axis_data, s_st3g1 <- its m_axis_data
    output wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 16-1:0] m_st3g1_tdata,
    output wire m_st3g1_tvalid,
    input  wire m_st3g1_tready,
    input  wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 40-1:0] s_st3g1_tdata,
    input  wire s_st3g1_tvalid,
    output wire s_st3g1_tready,
    // stage 4, FIR instance 0: m_st4g0 -> its s_axis_data, s_st4g0 <- its m_axis_data
    output wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 16-1:0] m_st4g0_tdata,
    output wire m_st4g0_tvalid,
    input  wire m_st4g0_tready,
    input  wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 40-1:0] s_st4g0_tdata,
    input  wire s_st4g0_tvalid,
    output wire s_st4g0_tready,
    // stage 4, FIR instance 1: m_st4g1 -> its s_axis_data, s_st4g1 <- its m_axis_data
    output wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 16-1:0] m_st4g1_tdata,
    output wire m_st4g1_tvalid,
    input  wire m_st4g1_tready,
    input  wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 40-1:0] s_st4g1_tdata,
    input  wire s_st4g1_tvalid,
    output wire s_st4g1_tready,
    // stage 5, FIR instance 0: m_st5g0 -> its s_axis_data, s_st5g0 <- its m_axis_data
    output wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 16-1:0] m_st5g0_tdata,
    output wire m_st5g0_tvalid,
    input  wire m_st5g0_tready,
    input  wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 40-1:0] s_st5g0_tdata,
    input  wire s_st5g0_tvalid,
    output wire s_st5g0_tready,
    // stage 5, FIR instance 1: m_st5g1 -> its s_axis_data, s_st5g1 <- its m_axis_data
    output wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 16-1:0] m_st5g1_tdata,
    output wire m_st5g1_tvalid,
    input  wire m_st5g1_tready,
    input  wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 40-1:0] s_st5g1_tdata,
    input  wire s_st5g1_tvalid,
    output wire s_st5g1_tready,
    // stage 6, FIR instance 0: m_st6g0 -> its s_axis_data, s_st6g0 <- its m_axis_data
    output wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 16-1:0] m_st6g0_tdata,
    output wire m_st6g0_tvalid,
    input  wire m_st6g0_tready,
    input  wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 40-1:0] s_st6g0_tdata,
    input  wire s_st6g0_tvalid,
    output wire s_st6g0_tready,
    // stage 6, FIR instance 1: m_st6g1 -> its s_axis_data, s_st6g1 <- its m_axis_data
    output wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 16-1:0] m_st6g1_tdata,
    output wire m_st6g1_tvalid,
    input  wire m_st6g1_tready,
    input  wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 40-1:0] s_st6g1_tdata,
    input  wire s_st6g1_tvalid,
    output wire s_st6g1_tready,
    output wire [3:0] depth_o,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 fir_aresetn_o RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire fir_aresetn_o,

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

    localparam [31:0]  ID   = 32'h5A525431;            // 'ZRT1'
    localparam integer L    = 2 * N_CH;                // lanes: I, Q of every channel
    localparam integer LG   = L / G;                   // lanes (paths) per FIR instance
    localparam integer BW   = N_CH * SPC * 32;         // beat width
    localparam integer SMAX = SPC * L * 16;            // widest stage stream
    localparam integer LSPC = (SPC == 8) ? 3 : (SPC == 4) ? 2 : (SPC == 2) ? 1 : 0;
    localparam integer CD   = 16;                      // centre delay: xo[m - CD]

    // samples per valid entering stage i, and the FIR vector of stage i
    function integer PIN(input integer i); PIN = ((SPC >> (i - 1)) > 1) ? (SPC >> (i - 1)) : 1; endfunction
    function integer VEC(input integer i); VEC = ((SPC >> i) > 1) ? (SPC >> i) : 1; endfunction
    function integer FIW(input integer i); FIW = VEC(i) * LG * 16; endfunction
    function integer FOW(input integer i); FOW = VEC(i) * LG * 40; endfunction
    localparam integer FIMAX = VEC(1) * LG * 16;
    localparam integer FOMAX = VEC(1) * LG * 40;

    generate
        if ((N_CH != 1 && N_CH != 2 && N_CH != 4 && N_CH != 8 && N_CH != 16) ||
            (SPC != 1 && SPC != 2 && SPC != 4 && SPC != 8) || K < 1 || K > 6 ||
            (G != 1 && G != 2) || LG > 16 || (L % G) != 0) begin : g_bad_param
            rx_rate_bad_parameter u_bad ();
        end
    endgenerate

    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;
    assign s_axis_tready = 1'b1;

    // =========================================================================
    // AXI4-Lite register file (s_axi_aclk)
    // =========================================================================
    reg         r_hold;
    reg  [3:0]  r_depth;
    reg  [7:0]  wr_addr;
    reg  [31:0] wr_data;
    reg         aw_seen, w_seen;
    wire [1:0]  status_s;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0; w_seen <= 1'b0;
            r_hold <= 1'b1; r_depth <= 4'd0;
        end else begin
            if (s_axi_awvalid && !aw_seen) begin
                aw_seen <= 1'b1; wr_addr <= s_axi_awaddr[7:0]; s_axi_awready <= 1'b1;
            end else s_axi_awready <= 1'b0;
            if (s_axi_wvalid && !w_seen) begin
                w_seen <= 1'b1; wr_data <= s_axi_wdata; s_axi_wready <= 1'b1;
            end else s_axi_wready <= 1'b0;
            if (aw_seen && w_seen && !s_axi_bvalid) begin
                aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
                if (wr_addr[7:2] == 6'h01) r_hold <= wr_data[0];
                if (wr_addr[7:2] == 6'h02 && wr_data[31:0] <= K) r_depth <= wr_data[3:0];
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
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
            case (rd_addr[7:2])
                6'h00:   s_axi_rdata <= ID;
                6'h01:   s_axi_rdata <= {31'd0, r_hold};
                6'h02:   s_axi_rdata <= {28'd0, r_depth};
                6'h03:   s_axi_rdata <= {6'd0, G[1:0], 3'd0, N_CH[4:0], 4'd0, LSPC[3:0], 4'd0, K[3:0]};
                6'h04:   s_axi_rdata <= {30'd0, status_s};
                default: s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Crossings
    // =========================================================================
    wire hold_a;
    wire [3:0] depth_x;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1))
    u_hold (.src_clk(s_axi_aclk), .src_in(r_hold), .dest_clk(aclk), .dest_out(hold_a));
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1), .WIDTH(4))
    u_depth (.src_clk(s_axi_aclk), .src_in(r_depth), .dest_clk(aclk), .dest_out(depth_x));

    reg        rst = 1'b1;              // the chain's reset, aclk
    reg  [3:0] depth = 4'd0;
    always @(posedge aclk) begin
        rst <= !aresetn || hold_a;
        if (!aresetn || hold_a) depth <= (depth_x <= K) ? depth_x : 4'd0;
    end
    assign depth_o       = depth;
    assign fir_aresetn_o = !rst;

    // =========================================================================
    // Stage streams: sd[i] / sv[i] = the output of stage i (0: the converter
    // beat), max(SPC >> i, 1) samples per lane per valid, sample-major
    // (sample s, lane a at bits 16*(s*L + a))
    // =========================================================================
    wire [SMAX-1:0]  sd [0:6];
    wire             sv [0:6];
    wire [FIMAX-1:0] fi_d [0:11];
    wire             fi_v [0:11];
    wire             fi_r [0:11];
    wire [FOMAX-1:0] fo_d [0:11];
    wire             fo_v [0:11];
    wire [6:1]       st_stall, st_ovf;
    // FIR Compiler holds s_axis_data_tready low for some cycles after its
    // reset: the stages start (crst low) once every FIR in use is ready, so
    // the first sample of a depth reaches both the FIR and the centre tap
    reg              run = 1'b0;
    wire             crst = !run;
    reg              all_rdy;
    integer          ri;
    always @(*) begin
        all_rdy = 1'b1;
        for (ri = 0; ri < 12; ri = ri + 1)
            if (ri / 2 < K && ri % 2 < G && !fi_r[ri]) all_rdy = 1'b0;
    end
    always @(posedge aclk) run <= !rst && (run || all_rdy);
    reg              stall_a = 1'b0, ovf_a = 1'b0;

    genvar gi, gc, gs, gg;
    generate
        for (gc = 0; gc < N_CH; gc = gc + 1) begin : g_in
            for (gs = 0; gs < SPC; gs = gs + 1) begin : g_s
                assign sd[0][16*(gs*L + 2*gc)     +: 16] = s_axis_tdata[32*(gc*SPC + gs)      +: 16];
                assign sd[0][16*(gs*L + 2*gc + 1) +: 16] = s_axis_tdata[32*(gc*SPC + gs) + 16 +: 16];
            end
        end
        assign sv[0] = s_axis_tvalid;
        for (gi = K + 1; gi <= 6; gi = gi + 1) begin : g_unused
            assign sd[gi] = {SMAX{1'b0}};
            assign sv[gi] = 1'b0;
            assign st_stall[gi] = 1'b0;
            assign st_ovf[gi]   = 1'b0;
        end
        for (gi = 1; gi <= 6; gi = gi + 1) begin : g_unused_fir
            if (gi > K) begin : g_off
                for (gg = 0; gg < 2; gg = gg + 1) begin : g_g
                    assign fi_d[2*(gi-1)+gg] = {FIMAX{1'b0}};
                    assign fi_v[2*(gi-1)+gg] = 1'b0;
                end
            end else if (G == 1) begin : g_off1
                assign fi_d[2*(gi-1)+1] = {FIMAX{1'b0}};
                assign fi_v[2*(gi-1)+1] = 1'b0;
            end
        end

        for (gi = 1; gi <= K; gi = gi + 1) begin : g_stage
            localparam integer P   = PIN(gi);
            localparam integer V   = VEC(gi);
            localparam         SSR = (SPC >> (gi - 1)) >= 2;
            localparam integer VW  = V * L * 16;

            // ---- pairs: pe = x[2m], po = x[2m+1], V of each per lane
            wire [SMAX-1:0] xin = sd[gi-1];
            wire            vin = sv[gi-1];
            reg  [VW-1:0]   pe, po;
            reg             pv;
            reg             ph;
            reg  [L*16-1:0] ev_hold;
            integer j, a;
            always @(*) begin
                for (j = 0; j < V; j = j + 1)
                    for (a = 0; a < L; a = a + 1) begin
                        if (SSR) begin
                            pe[16*(j*L + a) +: 16] = xin[16*((2*j)*L + a)     +: 16];
                            po[16*(j*L + a) +: 16] = xin[16*((2*j + 1)*L + a) +: 16];
                        end else begin
                            pe[16*(j*L + a) +: 16] = ev_hold[16*a +: 16];
                            po[16*(j*L + a) +: 16] = xin[16*a +: 16];
                        end
                    end
                pv = SSR ? vin : (vin && ph);
            end
            always @(posedge aclk) begin
                if (crst) ph <= 1'b0;
                else if (!SSR && vin) begin
                    ph <= !ph;
                    if (!ph) ev_hold <= xin[L*16-1:0];
                end
            end

            // ---- the odd phase: CD samples of history per lane (newest at 0)
            reg  [16*L*CD-1:0] line;
            reg  [VW-1:0]      xod;            // xo[m - CD] for each pair of the vector
            always @(*)
                for (j = 0; j < V; j = j + 1)
                    for (a = 0; a < L; a = a + 1)
                        xod[16*(j*L + a) +: 16] = line[16*((CD - 1 - j)*L + a) +: 16];
            always @(posedge aclk) begin
                if (crst) line <= {16*L*CD{1'b0}};
                else if (pv) begin
                    for (j = 0; j < CD; j = j + 1)
                        for (a = 0; a < L; a = a + 1)
                            line[16*(j*L + a) +: 16] <= (j < V) ? po[16*((V - 1 - j)*L + a) +: 16]
                                                                : line[16*((j - V)*L + a) +: 16];
                end
            end

            // ---- FIR input (registered) and the centre FIFO, pushed together
            reg [VW-1:0] fin;
            reg          fin_v;
            reg [VW-1:0] cmem [0:63];
            reg [5:0]    cwp, crp;
            reg [6:0]    ccnt;
            always @(posedge aclk) begin
                fin_v <= !crst && pv;
                if (pv) fin <= pe;
                if (crst) cwp <= 6'd0;
                else if (pv) begin cmem[cwp] <= xod; cwp <= cwp + 6'd1; end
            end
            for (gg = 0; gg < G; gg = gg + 1) begin : g_fin
                for (gs = 0; gs < V; gs = gs + 1) begin : g_s
                    assign fi_d[2*(gi-1)+gg][16*gs*LG +: 16*LG] = fin[16*(gs*L + gg*LG) +: 16*LG];
                end
                if (FIMAX > V*LG*16) begin : g_pad
                    assign fi_d[2*(gi-1)+gg][FIMAX-1:V*LG*16] = {(FIMAX - V*LG*16){1'b0}};
                end
                assign fi_v[2*(gi-1)+gg] = fin_v;
            end

            // ---- FIR output + centre tap -> round, saturate -> sd[gi]
            wire          fov = fo_v[2*(gi-1)];
            reg  [SMAX-1:0] y;
            reg             yv;
            reg  [VW-1:0]   ctr;
            reg signed [40:0] acc;
            reg signed [23:0] r;
            always @(*) ctr = cmem[crp];
            always @(posedge aclk) begin
                yv <= !crst && fov;
                if (crst) begin crp <= 6'd0; ccnt <= 7'd0; end
                else begin
                    if (fov) crp <= crp + 6'd1;
                    ccnt <= ccnt + (pv ? 7'd1 : 7'd0) - (fov ? 7'd1 : 7'd0);
                end
                if (fov)
                    for (j = 0; j < V; j = j + 1)
                        for (a = 0; a < L; a = a + 1) begin
                            acc = $signed(fo_d[2*(gi-1) + a / LG][40*(j*LG + a % LG) +: 40])
                                + ($signed(ctr[16*(j*L + a) +: 16]) <<< 16) + 41'sd65536;
                            r = acc >>> 17;
                            y[16*(j*L + a) +: 16] <= (r > 24'sd32767) ? 16'h7FFF :
                                                     (r < -24'sd32768) ? 16'h8000 : r[15:0];
                        end
            end
            assign sd[gi] = y;
            assign sv[gi] = yv;
            // lost samples: a FIR that refuses its input, a centre FIFO that overflows
            assign st_stall[gi] = fin_v && !fi_r[2*(gi-1)];
            assign st_ovf[gi]   = ccnt > 7'd60;
        end
    endgenerate

    // =========================================================================
    // Packers: stage k's vectors -> the channel-major beat
    // =========================================================================
    wire [BW-1:0] pk_d [0:6];
    wire          pk_v [0:6];
    assign pk_d[0] = s_axis_tdata;
    assign pk_v[0] = s_axis_tvalid;
    generate
        for (gi = 1; gi <= 6; gi = gi + 1) begin : g_pack
            if (gi > K) begin : g_off
                assign pk_d[gi] = {BW{1'b0}};
                assign pk_v[gi] = 1'b0;
            end else begin : g_on
                localparam integer V  = VEC(gi);
                localparam integer NV = SPC / V;          // vectors per beat
                reg [BW-1:0] acc_b, out_b;
                reg [3:0]    cnt;
                reg          out_v;
                integer j, c, base;
                always @(posedge aclk) begin
                    out_v <= 1'b0;
                    if (crst) cnt <= 4'd0;
                    else if (sv[gi]) begin
                        base = cnt * V;
                        for (j = 0; j < V; j = j + 1)
                            for (c = 0; c < N_CH; c = c + 1) begin
                                acc_b[32*(c*SPC + base + j)      +: 16] = sd[gi][16*(j*L + 2*c)     +: 16];
                                acc_b[32*(c*SPC + base + j) + 16 +: 16] = sd[gi][16*(j*L + 2*c + 1) +: 16];
                            end
                        if (cnt == NV - 1) begin
                            cnt   <= 4'd0;
                            out_b <= acc_b;
                            out_v <= 1'b1;
                        end else cnt <= cnt + 4'd1;
                    end
                end
                assign pk_d[gi] = out_b;
                assign pk_v[gi] = out_v;
            end
        end
    endgenerate

    always @(posedge aclk) begin
        if (crst) begin stall_a <= 1'b0; ovf_a <= 1'b0; end
        else begin
            if (|st_stall) stall_a <= 1'b1;
            if (|st_ovf)   ovf_a   <= 1'b1;
        end
    end

    // DEPTH 0: the input beat itself (one 2:1 mux on the converter path);
    // DEPTH k: stage k's packer, through one register
    reg [BW-1:0] pkr_d;
    reg          pkr_v;
    always @(posedge aclk) begin
        pkr_d <= pk_d[depth];
        pkr_v <= !crst && (depth != 4'd0) && pk_v[depth];
    end
    assign m_axis_tdata  = (depth == 4'd0) ? s_axis_tdata  : pkr_d;
    assign m_axis_tvalid = (depth == 4'd0) ? s_axis_tvalid : pkr_v;

    // status -> s_axi_aclk (sticky flags; a reset clears them)
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1), .WIDTH(2))
    u_status (.src_clk(aclk), .src_in({ovf_a, stall_a}), .dest_clk(s_axi_aclk), .dest_out(status_s));

    // ---- FIR ports
    assign m_st1g0_tdata  = fi_d[0][FIW(1)-1:0];
    assign m_st1g0_tvalid = fi_v[0];
    assign fi_r[0]          = m_st1g0_tready;
    assign fo_d[0]          = {{(FOMAX-FOW(1)){1'b0}}, s_st1g0_tdata};
    assign fo_v[0]          = s_st1g0_tvalid;
    assign s_st1g0_tready = 1'b1;
    assign m_st1g1_tdata  = fi_d[1][FIW(1)-1:0];
    assign m_st1g1_tvalid = fi_v[1];
    assign fi_r[1]          = m_st1g1_tready;
    assign fo_d[1]          = {{(FOMAX-FOW(1)){1'b0}}, s_st1g1_tdata};
    assign fo_v[1]          = s_st1g1_tvalid;
    assign s_st1g1_tready = 1'b1;
    assign m_st2g0_tdata  = fi_d[2][FIW(2)-1:0];
    assign m_st2g0_tvalid = fi_v[2];
    assign fi_r[2]          = m_st2g0_tready;
    assign fo_d[2]          = {{(FOMAX-FOW(2)){1'b0}}, s_st2g0_tdata};
    assign fo_v[2]          = s_st2g0_tvalid;
    assign s_st2g0_tready = 1'b1;
    assign m_st2g1_tdata  = fi_d[3][FIW(2)-1:0];
    assign m_st2g1_tvalid = fi_v[3];
    assign fi_r[3]          = m_st2g1_tready;
    assign fo_d[3]          = {{(FOMAX-FOW(2)){1'b0}}, s_st2g1_tdata};
    assign fo_v[3]          = s_st2g1_tvalid;
    assign s_st2g1_tready = 1'b1;
    assign m_st3g0_tdata  = fi_d[4][FIW(3)-1:0];
    assign m_st3g0_tvalid = fi_v[4];
    assign fi_r[4]          = m_st3g0_tready;
    assign fo_d[4]          = {{(FOMAX-FOW(3)){1'b0}}, s_st3g0_tdata};
    assign fo_v[4]          = s_st3g0_tvalid;
    assign s_st3g0_tready = 1'b1;
    assign m_st3g1_tdata  = fi_d[5][FIW(3)-1:0];
    assign m_st3g1_tvalid = fi_v[5];
    assign fi_r[5]          = m_st3g1_tready;
    assign fo_d[5]          = {{(FOMAX-FOW(3)){1'b0}}, s_st3g1_tdata};
    assign fo_v[5]          = s_st3g1_tvalid;
    assign s_st3g1_tready = 1'b1;
    assign m_st4g0_tdata  = fi_d[6][FIW(4)-1:0];
    assign m_st4g0_tvalid = fi_v[6];
    assign fi_r[6]          = m_st4g0_tready;
    assign fo_d[6]          = {{(FOMAX-FOW(4)){1'b0}}, s_st4g0_tdata};
    assign fo_v[6]          = s_st4g0_tvalid;
    assign s_st4g0_tready = 1'b1;
    assign m_st4g1_tdata  = fi_d[7][FIW(4)-1:0];
    assign m_st4g1_tvalid = fi_v[7];
    assign fi_r[7]          = m_st4g1_tready;
    assign fo_d[7]          = {{(FOMAX-FOW(4)){1'b0}}, s_st4g1_tdata};
    assign fo_v[7]          = s_st4g1_tvalid;
    assign s_st4g1_tready = 1'b1;
    assign m_st5g0_tdata  = fi_d[8][FIW(5)-1:0];
    assign m_st5g0_tvalid = fi_v[8];
    assign fi_r[8]          = m_st5g0_tready;
    assign fo_d[8]          = {{(FOMAX-FOW(5)){1'b0}}, s_st5g0_tdata};
    assign fo_v[8]          = s_st5g0_tvalid;
    assign s_st5g0_tready = 1'b1;
    assign m_st5g1_tdata  = fi_d[9][FIW(5)-1:0];
    assign m_st5g1_tvalid = fi_v[9];
    assign fi_r[9]          = m_st5g1_tready;
    assign fo_d[9]          = {{(FOMAX-FOW(5)){1'b0}}, s_st5g1_tdata};
    assign fo_v[9]          = s_st5g1_tvalid;
    assign s_st5g1_tready = 1'b1;
    assign m_st6g0_tdata  = fi_d[10][FIW(6)-1:0];
    assign m_st6g0_tvalid = fi_v[10];
    assign fi_r[10]          = m_st6g0_tready;
    assign fo_d[10]          = {{(FOMAX-FOW(6)){1'b0}}, s_st6g0_tdata};
    assign fo_v[10]          = s_st6g0_tvalid;
    assign s_st6g0_tready = 1'b1;
    assign m_st6g1_tdata  = fi_d[11][FIW(6)-1:0];
    assign m_st6g1_tvalid = fi_v[11];
    assign fi_r[11]          = m_st6g1_tready;
    assign fo_d[11]          = {{(FOMAX-FOW(6)){1'b0}}, s_st6g1_tdata};
    assign fo_v[11]          = s_st6g1_tvalid;
    assign s_st6g1_tready = 1'b1;

endmodule

`default_nettype wire
