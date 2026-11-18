// tx_rate -- the TX low-rate chain's hub: the player's beat -> K FIR
// Compiler ×2 stages -> the DAC beat (rates below the RFDC's F = 40; design
// docs/superpowers/specs/2026-11-17-low-rate-fir-design.md, arithmetic
// fpga/ip/src/uhd_ip/rate/LANES.md, model sim/check_rate.py).
//
//   s_axis  (aclk) the channel-major beat from the player / beamformer,
//                  N_CH x SPC slots (channel c sample s at slot c*SPC + s).
//   m_axis  (aclk) the DAC beat. DEPTH 0: s_axis itself, tready passed
//                  through (combinational: today's path). DEPTH k: the
//                  samples interpolated by 2^k; s_axis takes one beat per
//                  2^k cycles in steady state, m_axis_tvalid is high every
//                  cycle (zero beats until the chain has filled, and on an
//                  underrun, which STATUS-like counters in the testbench
//                  catch: the player always offers a beat).
//   m_st<i>g<g> / s_st<i>g<g>  stage i (1 = next to the RFDC), FIR
//                  instance g: as rx_rate's, the same FIR configuration
//                  (the 32-tap odd branch of the half-band at
//                  max(SPC >> i, 1) samples per valid).
//   depth_i, fir_aresetn_i (aclk) from rx_rate: DEPTH and the chain reset.
//
// Stage i (polyphase half-band ×2, gain 2): its input x (max(SPC >> i, 1)
// samples per handshake) -> the FIR and a (CD - 1)-sample delay;
// y[2m] = sat16((fir[m] + 2^15) >>> 16), y[2m+1] = x[m - (CD - 1)].
// DEPTH k feeds stage k from the beat and stage 1 drives the DAC; stages
// above k idle.

`timescale 1ns / 1ps
`default_nettype none

module tx_rate #(
    parameter integer N_CH = 1,        // 1, 2, 4, 8, 16
    parameter integer SPC  = 4,        // samples per channel per beat: 1, 2, 4, 8
    parameter integer K    = 5,        // stages: 1 .. 6
    parameter integer G    = 1         // FIR instances per stage: 1, or 2 when 2 N_CH > 16
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis:m_st1g0:s_st1g0:m_st1g1:s_st1g1:m_st2g0:s_st2g0:m_st2g1:s_st2g1:m_st3g0:s_st3g0:m_st3g1:s_st3g1:m_st4g0:s_st4g0:m_st4g1:s_st4g1:m_st5g0:s_st5g0:m_st5g1:s_st5g1:m_st6g0:s_st6g0:m_st6g1:s_st6g1, ASSOCIATED_RESET aresetn:fir_aresetn_i" *)
    input  wire aclk,
    input  wire aresetn,
    input  wire [N_CH*SPC*32-1:0] s_axis_tdata,
    input  wire s_axis_tvalid,
    output wire s_axis_tready,
    output wire [N_CH*SPC*32-1:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input  wire m_axis_tready,
    output wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 16-1:0] m_st1g0_tdata,
    output wire m_st1g0_tvalid,
    input  wire m_st1g0_tready,
    input  wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 40-1:0] s_st1g0_tdata,
    input  wire s_st1g0_tvalid,
    output wire s_st1g0_tready,
    output wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 16-1:0] m_st1g1_tdata,
    output wire m_st1g1_tvalid,
    input  wire m_st1g1_tready,
    input  wire [((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 40-1:0] s_st1g1_tdata,
    input  wire s_st1g1_tvalid,
    output wire s_st1g1_tready,
    output wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 16-1:0] m_st2g0_tdata,
    output wire m_st2g0_tvalid,
    input  wire m_st2g0_tready,
    input  wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 40-1:0] s_st2g0_tdata,
    input  wire s_st2g0_tvalid,
    output wire s_st2g0_tready,
    output wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 16-1:0] m_st2g1_tdata,
    output wire m_st2g1_tvalid,
    input  wire m_st2g1_tready,
    input  wire [((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 40-1:0] s_st2g1_tdata,
    input  wire s_st2g1_tvalid,
    output wire s_st2g1_tready,
    output wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 16-1:0] m_st3g0_tdata,
    output wire m_st3g0_tvalid,
    input  wire m_st3g0_tready,
    input  wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 40-1:0] s_st3g0_tdata,
    input  wire s_st3g0_tvalid,
    output wire s_st3g0_tready,
    output wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 16-1:0] m_st3g1_tdata,
    output wire m_st3g1_tvalid,
    input  wire m_st3g1_tready,
    input  wire [((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 40-1:0] s_st3g1_tdata,
    input  wire s_st3g1_tvalid,
    output wire s_st3g1_tready,
    output wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 16-1:0] m_st4g0_tdata,
    output wire m_st4g0_tvalid,
    input  wire m_st4g0_tready,
    input  wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 40-1:0] s_st4g0_tdata,
    input  wire s_st4g0_tvalid,
    output wire s_st4g0_tready,
    output wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 16-1:0] m_st4g1_tdata,
    output wire m_st4g1_tvalid,
    input  wire m_st4g1_tready,
    input  wire [((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 40-1:0] s_st4g1_tdata,
    input  wire s_st4g1_tvalid,
    output wire s_st4g1_tready,
    output wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 16-1:0] m_st5g0_tdata,
    output wire m_st5g0_tvalid,
    input  wire m_st5g0_tready,
    input  wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 40-1:0] s_st5g0_tdata,
    input  wire s_st5g0_tvalid,
    output wire s_st5g0_tready,
    output wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 16-1:0] m_st5g1_tdata,
    output wire m_st5g1_tvalid,
    input  wire m_st5g1_tready,
    input  wire [((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 40-1:0] s_st5g1_tdata,
    input  wire s_st5g1_tvalid,
    output wire s_st5g1_tready,
    output wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 16-1:0] m_st6g0_tdata,
    output wire m_st6g0_tvalid,
    input  wire m_st6g0_tready,
    input  wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 40-1:0] s_st6g0_tdata,
    input  wire s_st6g0_tvalid,
    output wire s_st6g0_tready,
    output wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 16-1:0] m_st6g1_tdata,
    output wire m_st6g1_tvalid,
    input  wire m_st6g1_tready,
    input  wire [((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 40-1:0] s_st6g1_tdata,
    input  wire s_st6g1_tvalid,
    output wire s_st6g1_tready,
    input  wire [3:0] depth_i,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 fir_aresetn_i RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire fir_aresetn_i
);

    localparam integer L     = 2 * N_CH;
    localparam integer LG    = L / G;
    localparam integer BW    = N_CH * SPC * 32;
    localparam integer CD    = 16;                     // RX centre delay; TX uses CD - 1
    function integer VEC(input integer i); VEC = ((SPC >> i) > 1) ? (SPC >> i) : 1; endfunction
    // samples per handshake the consumer of stage i's output takes
    function integer WNX(input integer i); WNX = (i == 1) ? SPC : VEC(i - 1); endfunction
    function integer FIW(input integer i); FIW = VEC(i) * LG * 16; endfunction
    function integer FOW(input integer i); FOW = VEC(i) * LG * 40; endfunction
    localparam integer FIMAX = VEC(1) * LG * 16;
    localparam integer FOMAX = VEC(1) * LG * 40;
    localparam integer SMAX  = SPC * L * 16;           // widest vector (a whole beat)

    generate
        if ((N_CH != 1 && N_CH != 2 && N_CH != 4 && N_CH != 8 && N_CH != 16) ||
            (SPC != 1 && SPC != 2 && SPC != 4 && SPC != 8) || K < 1 || K > 6 ||
            (G != 1 && G != 2) || LG > 16 || (L % G) != 0) begin : g_bad_param
            tx_rate_bad_parameter u_bad ();
        end
    endgenerate

    reg        rst = 1'b1;
    reg  [3:0] depth = 4'd0;
    always @(posedge aclk) begin
        rst <= !aresetn || !fir_aresetn_i;
        if (!aresetn || !fir_aresetn_i) depth <= (depth_i <= K) ? depth_i : 4'd0;
    end

    wire [FIMAX-1:0] fi_d [0:11];
    wire             fi_v [0:11];
    wire             fi_r [0:11];
    wire [FOMAX-1:0] fo_d [0:11];
    wire             fo_v [0:11];
    wire             fo_r [0:11];

    // stages start once every FIR in use is ready (FIR Compiler holds
    // s_axis_data_tready low after its reset)
    reg      run = 1'b0;
    wire     crst = !run;
    reg      all_rdy;
    integer  ri;
    always @(*) begin
        all_rdy = 1'b1;
        for (ri = 0; ri < 12; ri = ri + 1)
            if (ri / 2 < K && ri % 2 < G && !fi_r[ri]) all_rdy = 1'b0;
    end
    always @(posedge aclk) run <= !rst && (run || all_rdy);

    // ---- per stage input (vectors of VEC(i) samples, sample-major lanes)
    // in_d[i]/in_v[i] -> stage i, in_r[i] <- stage i; out_d[i]/out_v[i] =
    // stage i's output sub-vector (WNX(i) samples), out_r[i] its consumer
    wire [SMAX-1:0] in_d  [0:7];
    wire            in_v  [0:7];
    wire            in_r  [0:7];
    wire [SMAX-1:0] out_d [0:7];
    wire            out_v [0:7];
    wire            out_r [0:7];

    // ---- the unpacker: the beat -> VEC(depth) samples per handshake
    reg  [SMAX-1:0] ub;                 // the beat, sample-major
    reg  [3:0]      ub_n;               // sub-vectors left
    reg  [3:0]      ub_i;
    wire [3:0]      ub_w  = (depth == 4'd0) ? 4'd1 : SPC / VEC(depth);   // sub-vectors per beat
    wire            ub_ov = (ub_n != 4'd0);
    wire            ub_or;              // the entry stage takes one
    reg  [SMAX-1:0] ub_od;
    reg  [SMAX-1:0] beat_sm;
    integer j, a, c, s;
    always @(*) begin
        for (s = 0; s < SPC; s = s + 1)
            for (c = 0; c < N_CH; c = c + 1) begin
                beat_sm[16*(s*L + 2*c)     +: 16] = s_axis_tdata[32*(c*SPC + s)      +: 16];
                beat_sm[16*(s*L + 2*c + 1) +: 16] = s_axis_tdata[32*(c*SPC + s) + 16 +: 16];
            end
        ub_od = ub >> (16 * L * VEC(depth) * ub_i);
    end
    wire ub_take = (depth != 4'd0) && !crst && s_axis_tvalid && (!ub_ov || (ub_n == 4'd1 && ub_or));
    always @(posedge aclk) begin
        if (crst) begin ub_n <= 4'd0; ub_i <= 4'd0; end
        else if (ub_take) begin ub <= beat_sm; ub_n <= ub_w; ub_i <= 4'd0; end
        else if (ub_ov && ub_or) begin ub_n <= ub_n - 4'd1; ub_i <= ub_i + 4'd1; end
    end
    assign s_axis_tready = (depth == 4'd0) ? m_axis_tready : ub_take;

    genvar gi, gg, gs;
    generate
        for (gi = 1; gi <= 6; gi = gi + 1) begin : g_route
            if (gi > K) begin : g_off
                assign in_d[gi] = {SMAX{1'b0}};
                assign in_v[gi] = 1'b0;
                assign out_d[gi] = {SMAX{1'b0}};
                assign out_v[gi] = 1'b0;
                assign in_r[gi]  = 1'b1;
                for (gg = 0; gg < 2; gg = gg + 1) begin : g_g
                    assign fi_d[2*(gi-1)+gg] = {FIMAX{1'b0}};
                    assign fi_v[2*(gi-1)+gg] = 1'b0;
                    assign fo_r[2*(gi-1)+gg] = 1'b1;
                end
            end else begin : g_on
                // stage gi's input: the unpacker at the entry stage, else stage gi+1's output
                assign in_d[gi] = (gi == depth) ? ub_od : out_d[gi + 1];
                assign in_v[gi] = (gi == depth) ? ub_ov : (gi < depth) ? out_v[gi + 1] : 1'b0;
                if (G == 1) begin : g_g1
                    assign fi_d[2*(gi-1)+1] = {FIMAX{1'b0}};
                    assign fi_v[2*(gi-1)+1] = 1'b0;
                    assign fo_r[2*(gi-1)+1] = 1'b1;
                end
            end
        end
        assign out_d[7] = {SMAX{1'b0}};
        assign out_v[7] = 1'b0;
        // the consumer of stage gi's output: stage gi-1's input (gi >= 2), the DAC (gi = 1)
        for (gi = 2; gi <= 7; gi = gi + 1) begin : g_ready
            assign out_r[gi] = (gi - 1 < depth) ? in_r[gi - 1] : 1'b1;
        end
        assign ub_or = (depth >= 4'd1 && depth <= K) ? in_r[depth] : 1'b1;

        for (gi = 1; gi <= K; gi = gi + 1) begin : g_stage
            localparam integer V   = VEC(gi);
            localparam integer VW  = V * L * 16;
            localparam integer W   = WNX(gi);           // samples per output handshake
            localparam integer NS  = 2 * V / W;         // output handshakes per FIR output (1 or 2)

            // ---- input handshake: the FIR and the centre line take x together
            wire hs = in_v[gi] && fi_r[2*(gi-1)] && !crst;
            assign in_r[gi] = fi_r[2*(gi-1)] && !crst;
            for (gg = 0; gg < G; gg = gg + 1) begin : g_fin
                for (gs = 0; gs < V; gs = gs + 1) begin : g_s
                    assign fi_d[2*(gi-1)+gg][16*gs*LG +: 16*LG] = in_d[gi][16*(gs*L + gg*LG) +: 16*LG];
                end
                if (FIMAX > V*LG*16) begin : g_pad
                    assign fi_d[2*(gi-1)+gg][FIMAX-1:V*LG*16] = {(FIMAX - V*LG*16){1'b0}};
                end
                assign fi_v[2*(gi-1)+gg] = in_v[gi] && !crst;
            end

            // ---- centre: x[m - (CD - 1)] per input sample
            reg  [16*L*(CD-1)-1:0] line;
            reg  [VW-1:0]          xod;
            reg  [VW-1:0]          cmem [0:63];
            reg  [5:0]             cwp, crp;
            reg  [6:0]             ccnt;
            integer jj, aa;
            always @(*)
                for (jj = 0; jj < V; jj = jj + 1)
                    for (aa = 0; aa < L; aa = aa + 1)
                        xod[16*(jj*L + aa) +: 16] = line[16*((CD - 2 - jj)*L + aa) +: 16];
            always @(posedge aclk) begin
                if (crst) begin line <= {16*L*(CD-1){1'b0}}; cwp <= 6'd0; end
                else if (hs) begin
                    for (jj = 0; jj < CD - 1; jj = jj + 1)
                        for (aa = 0; aa < L; aa = aa + 1)
                            line[16*(jj*L + aa) +: 16] <= (jj < V) ? in_d[gi][16*((V - 1 - jj)*L + aa) +: 16]
                                                                  : line[16*((jj - V)*L + aa) +: 16];
                    cmem[cwp] <= xod;
                    cwp <= cwp + 6'd1;
                end
            end

            // ---- FIR output + centre -> the 2V output samples, sent W at a time
            reg  [2*VW-1:0] ob;                // y[2m], y[2m+1], ... sample-major
            reg  [1:0]      ob_n;              // output handshakes left
            reg             ob_i;
            wire            ob_ov = (ob_n != 2'd0);
            wire            fo_take = !crst && fo_v[2*(gi-1)] && (!ob_ov || (ob_n == 2'd1 && out_r[gi]));
            for (gg = 0; gg < G; gg = gg + 1) begin : g_for
                assign fo_r[2*(gi-1)+gg] = !crst && (!ob_ov || (ob_n == 2'd1 && out_r[gi]));
            end
            wire [VW-1:0]   ctr = cmem[crp];
            reg  [2*VW-1:0] yv;
            reg signed [40:0] acc;
            reg signed [24:0] r;
            always @(*)
                for (jj = 0; jj < V; jj = jj + 1)
                    for (aa = 0; aa < L; aa = aa + 1) begin
                        acc = $signed(fo_d[2*(gi-1) + aa / LG][40*(jj*LG + aa % LG) +: 40]) + 41'sd32768;
                        r = acc >>> 16;
                        yv[16*((2*jj)*L + aa) +: 16]     = (r > 25'sd32767) ? 16'h7FFF :
                                                           (r < -25'sd32768) ? 16'h8000 : r[15:0];
                        yv[16*((2*jj + 1)*L + aa) +: 16] = ctr[16*(jj*L + aa) +: 16];
                    end
            always @(posedge aclk) begin
                if (crst) begin ob_n <= 2'd0; ob_i <= 1'b0; crp <= 6'd0; ccnt <= 7'd0; end
                else begin
                    if (fo_take) begin ob <= yv; ob_n <= NS; ob_i <= 1'b0; crp <= crp + 6'd1; end
                    else if (ob_ov && out_r[gi]) begin ob_n <= ob_n - 2'd1; ob_i <= 1'b1; end
                    ccnt <= ccnt + (hs ? 7'd1 : 7'd0) - (fo_take ? 7'd1 : 7'd0);
                end
            end
            assign out_d[gi] = (NS == 2 && ob_i) ? (ob >> (16 * L * W)) : ob;
            assign out_v[gi] = ob_ov;
        end
    endgenerate

    // ---- the DAC beat: stage 1's output (SPC samples per handshake)
    reg  [BW-1:0] dac_b;
    integer c2, s2;
    always @(*)
        for (s2 = 0; s2 < SPC; s2 = s2 + 1)
            for (c2 = 0; c2 < N_CH; c2 = c2 + 1) begin
                dac_b[32*(c2*SPC + s2)      +: 16] = out_v[1] ? out_d[1][16*(s2*L + 2*c2)     +: 16] : 16'd0;
                dac_b[32*(c2*SPC + s2) + 16 +: 16] = out_v[1] ? out_d[1][16*(s2*L + 2*c2 + 1) +: 16] : 16'd0;
            end
    assign out_r[1] = m_axis_tready;
    assign m_axis_tdata  = (depth == 4'd0) ? s_axis_tdata  : dac_b;
    assign m_axis_tvalid = (depth == 4'd0) ? s_axis_tvalid : 1'b1;

    // ---- FIR ports
    assign m_st1g0_tdata  = fi_d[0][FIW(1)-1:0];
    assign m_st1g0_tvalid = fi_v[0];
    assign fi_r[0]          = m_st1g0_tready;
    assign fo_d[0]          = {{(FOMAX-FOW(1)){1'b0}}, s_st1g0_tdata};
    assign fo_v[0]          = s_st1g0_tvalid;
    assign s_st1g0_tready = fo_r[0];
    assign m_st1g1_tdata  = fi_d[1][FIW(1)-1:0];
    assign m_st1g1_tvalid = fi_v[1];
    assign fi_r[1]          = m_st1g1_tready;
    assign fo_d[1]          = {{(FOMAX-FOW(1)){1'b0}}, s_st1g1_tdata};
    assign fo_v[1]          = s_st1g1_tvalid;
    assign s_st1g1_tready = fo_r[1];
    assign m_st2g0_tdata  = fi_d[2][FIW(2)-1:0];
    assign m_st2g0_tvalid = fi_v[2];
    assign fi_r[2]          = m_st2g0_tready;
    assign fo_d[2]          = {{(FOMAX-FOW(2)){1'b0}}, s_st2g0_tdata};
    assign fo_v[2]          = s_st2g0_tvalid;
    assign s_st2g0_tready = fo_r[2];
    assign m_st2g1_tdata  = fi_d[3][FIW(2)-1:0];
    assign m_st2g1_tvalid = fi_v[3];
    assign fi_r[3]          = m_st2g1_tready;
    assign fo_d[3]          = {{(FOMAX-FOW(2)){1'b0}}, s_st2g1_tdata};
    assign fo_v[3]          = s_st2g1_tvalid;
    assign s_st2g1_tready = fo_r[3];
    assign m_st3g0_tdata  = fi_d[4][FIW(3)-1:0];
    assign m_st3g0_tvalid = fi_v[4];
    assign fi_r[4]          = m_st3g0_tready;
    assign fo_d[4]          = {{(FOMAX-FOW(3)){1'b0}}, s_st3g0_tdata};
    assign fo_v[4]          = s_st3g0_tvalid;
    assign s_st3g0_tready = fo_r[4];
    assign m_st3g1_tdata  = fi_d[5][FIW(3)-1:0];
    assign m_st3g1_tvalid = fi_v[5];
    assign fi_r[5]          = m_st3g1_tready;
    assign fo_d[5]          = {{(FOMAX-FOW(3)){1'b0}}, s_st3g1_tdata};
    assign fo_v[5]          = s_st3g1_tvalid;
    assign s_st3g1_tready = fo_r[5];
    assign m_st4g0_tdata  = fi_d[6][FIW(4)-1:0];
    assign m_st4g0_tvalid = fi_v[6];
    assign fi_r[6]          = m_st4g0_tready;
    assign fo_d[6]          = {{(FOMAX-FOW(4)){1'b0}}, s_st4g0_tdata};
    assign fo_v[6]          = s_st4g0_tvalid;
    assign s_st4g0_tready = fo_r[6];
    assign m_st4g1_tdata  = fi_d[7][FIW(4)-1:0];
    assign m_st4g1_tvalid = fi_v[7];
    assign fi_r[7]          = m_st4g1_tready;
    assign fo_d[7]          = {{(FOMAX-FOW(4)){1'b0}}, s_st4g1_tdata};
    assign fo_v[7]          = s_st4g1_tvalid;
    assign s_st4g1_tready = fo_r[7];
    assign m_st5g0_tdata  = fi_d[8][FIW(5)-1:0];
    assign m_st5g0_tvalid = fi_v[8];
    assign fi_r[8]          = m_st5g0_tready;
    assign fo_d[8]          = {{(FOMAX-FOW(5)){1'b0}}, s_st5g0_tdata};
    assign fo_v[8]          = s_st5g0_tvalid;
    assign s_st5g0_tready = fo_r[8];
    assign m_st5g1_tdata  = fi_d[9][FIW(5)-1:0];
    assign m_st5g1_tvalid = fi_v[9];
    assign fi_r[9]          = m_st5g1_tready;
    assign fo_d[9]          = {{(FOMAX-FOW(5)){1'b0}}, s_st5g1_tdata};
    assign fo_v[9]          = s_st5g1_tvalid;
    assign s_st5g1_tready = fo_r[9];
    assign m_st6g0_tdata  = fi_d[10][FIW(6)-1:0];
    assign m_st6g0_tvalid = fi_v[10];
    assign fi_r[10]          = m_st6g0_tready;
    assign fo_d[10]          = {{(FOMAX-FOW(6)){1'b0}}, s_st6g0_tdata};
    assign fo_v[10]          = s_st6g0_tvalid;
    assign s_st6g0_tready = fo_r[10];
    assign m_st6g1_tdata  = fi_d[11][FIW(6)-1:0];
    assign m_st6g1_tvalid = fi_v[11];
    assign fi_r[11]          = m_st6g1_tready;
    assign fo_d[11]          = {{(FOMAX-FOW(6)){1'b0}}, s_st6g1_tdata};
    assign fo_v[11]          = s_st6g1_tvalid;
    assign s_st6g1_tready = fo_r[11];

endmodule

`default_nettype wire
