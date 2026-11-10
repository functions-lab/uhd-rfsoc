// tx_dpd -- TX digital predistortion, the last block before the DACs of every
// v49 build (Protocol §12 is the contract; §9 the layout).
//
//   s_axis / m_axis (aclk, the converter AXIS clock)
//       CHANNEL-MAJOR beat: channel c in bits [c*W +: W], W = BEAT_W/N_CH,
//       SSR = W/32 complex int16 samples per channel per beat (I in [15:0],
//       Q in [31:16] of each 32-bit slot, slot 0 earliest). Same layout out.
//   s_axi (s_axi_aclk) AXI4-Lite register file, map below.
//
// Datapath: one dpd_mpl_core (src/dpd_mpl_core.sv and its sub-modules) per
// channel, the MPL-4x4 model applied to each channel on its own:
//     z(n)   = sum_{m=0..3} G_m(n) x(n-m)
//     G_m(n) = a_m0 + sum_{j=1..3} a_mj eps(n-m)^j
//              + [m<=1] sum_{j=1..2} b_mj eps(n-m-1)^j,   eps = (I^2+Q^2)/2
// 20 complex Q6.21 coefficients per channel (a_mj at index 4m+j, b_mj at
// 16+2m+j-1), output saturated to int16. Bit-exact to dpd_fx() of
// rfsoc/rfsoc_lib/dsp/dpd.py. Latency 32 aclk cycles from s_axis to m_axis,
// the same in bypass and with predistortion, on every channel.
//
// No backpressure: s_axis_tready is 1 and m_axis_tready is not used (the
// RFDC DAC takes a beat every cycle). A beat with tvalid = 0 leaves as zeros
// with tvalid = 0 (what the DAC plays between bursts anyway).
//
// Register map (byte offsets, 16-bit address): channel c (c < N_CH) owns the
// block at 0x400*c, [15:14] = 0; any other address reads 0, writes are
// ignored. wstrb is ignored (32-bit writes only), like the other v49 cores.
//   0x000 CTRL     RW  [0] BYPASS (reset 1; written by every CTRL write)
//                      [1] COMMIT: deliver SHADOW to the datapath, together
//                          with BYPASS, atomically (one beat sees either the
//                          whole old or the whole new set and bypass state)
//                      [2] CLR_STATS  [3] SHADOW_IDENTITY (SHADOW <- the
//                          identity set, after a COMMIT of the same write took
//                          its snapshot). [3:1] read 0.
//   0x004 STATUS   RO  [0] bypass in the datapath  [1] COMMIT not yet applied
//                      [2] a CTRL / COMMIT / CLR_STATS not yet delivered (queued
//                          or crossing)
//                      [3] the datapath was reset since the last COMMIT (it
//                          runs bypass + identity)  [15:8] COMMITs applied mod 256
//   0x008 ID       RO  0x5A443031 'ZD01'
//   0x00C CONFIG   RO  0x20142244: [3:0] taps 4, [7:4] powers 4, [11:8] lag
//                      taps 2, [15:12] lag powers 2, [23:16] coefficients 20,
//                      [31:24] latency 32
//   0x010 SAT_OUT  RO  output rails saturated since CLR_STATS (saturating count)
//   0x014 SAT_GAIN RO  gains G_m saturated since CLR_STATS
//   0x018 PEAK     RO  [15:0] max |I|,|Q| in, [31:16] out, since CLR_STATS
//   0x01C TOPO     RO  [7:0] N_CH, [15:8] SSR, [23:16] channel c
//   0x100 + 8i     RW  SHADOW coefficient i real, Q6.21 in [26:0] (reads sign-extended)
//   0x104 + 8i     RW  SHADOW coefficient i imaginary, i = 0..19; reset identity
//                      (word 0 = 0x00200000, all others 0)
//   0x200 + 8i/+4  RO  ACTIVE: the set the last applied COMMIT delivered
// STATUS [0], [3] and the statistics are snapshots the datapath sends back
// continuously (each a few us old); SAT_* / PEAK keep their last value while
// aclk is stopped. Every register answers while aclk is stopped or held in
// reset (a template retune, Protocol §8): an AXI access never waits on aclk.
//
// Clock crossings (XPM, they carry their own timing constraints):
//   s_axi -> aclk  xpm_cdc_handshake, 547 bits, acknowledged by the aclk side
//                  once the message is applied: one message at a time, CTRL
//                  (bypass), COMMIT as two halves of the 1080-bit set (the
//                  second applies it with the bypass bit), CLR_STATS. The
//                  shadow is snapshotted when the COMMIT launches; software
//                  waits for STATUS[1] = 0 before writing SHADOW again.
//   aclk -> s_axi  xpm_cdc_handshake, 102 bits: the statistics, bypass and
//                  reset flag of one channel, round-robin.
// An aclk reset returns every channel to bypass + identity (the s_axi
// registers keep their values; STATUS[3] says so). An s_axi reset sets every
// register to its reset value and COMMITs the identity set with bypass to
// every channel (STATUS[15:8] then counts that COMMIT).
//
// Verilog-2001 top; the dpd_*.sv datapath files are packaged with it.

`timescale 1ns / 1ps
`default_nettype none

module tx_dpd #(
    parameter integer N_CH   = 1,      // 1, 2, 4, 8 or 16
    parameter integer BEAT_W = 128     // 128, 256 or 512; SSR = BEAT_W/N_CH/32 in 1, 2, 4, 8
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

    localparam [31:0]   ID     = 32'h5A443031;          // 'ZD01'
    localparam [31:0]   CONFIG = 32'h20142244;
    localparam integer  W      = BEAT_W / N_CH;         // bits per channel per beat
    localparam integer  SSR    = W / 32;
    localparam integer  CW     = 1080;                  // 40 words x 27 bits
    localparam integer  HW     = CW / 2;                // one COMMIT half
    localparam integer  MW     = 4 + 2 + 1 + HW;        // message: ch, kind, bypass, half
    localparam integer  SW     = 4 + 32 + 32 + 32 + 1 + 1;  // snapshot
    localparam [CW-1:0] IDENT  = {{(CW-22){1'b0}}, 1'b1, 21'd0};  // a_00 = 1.0
    localparam [7:0]    SSR8   = SSR;
    localparam [7:0]    NCH8   = N_CH;
    localparam [1:0]    K_CTRL = 2'd0, K_LO = 2'd1, K_HI = 2'd2, K_CLR = 2'd3;

    // Elaboration-time check: an unsupported combination instantiates a
    // module that does not exist, so the build fails loudly.
    generate
        if ((BEAT_W != 128 && BEAT_W != 256 && BEAT_W != 512) ||
            (N_CH != 1 && N_CH != 2 && N_CH != 4 && N_CH != 8 && N_CH != 16) ||
            (W % 32 != 0) || (SSR != 1 && SSR != 2 && SSR != 4 && SSR != 8)) begin : g_bad_param
            tx_dpd_bad_N_CH_or_BEAT_W u_bad ();
        end
    endgenerate

    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;
    assign s_axis_tready = 1'b1;

    // =========================================================================
    // AXI4-Lite register file (s_axi_aclk)
    // =========================================================================
    reg  [CW-1:0]   r_sh  [0:N_CH-1];       // SHADOW
    reg  [CW-1:0]   r_act [0:N_CH-1];       // ACTIVE (mirror of the last applied COMMIT)
    reg  [N_CH-1:0] r_byp;
    reg  [N_CH-1:0] p_ctrl, p_commit, p_clr, p_ident;
    reg  [N_CH-1:0] c_fly;                  // COMMIT launched, not yet applied
    reg  [7:0]      r_ccnt [0:N_CH-1];
    reg  [31:0]     st_so  [0:N_CH-1];
    reg  [31:0]     st_sg  [0:N_CH-1];
    reg  [31:0]     st_pk  [0:N_CH-1];
    reg  [N_CH-1:0] st_byp, st_rst;

    // the s_axi -> aclk message handshake
    reg           hs_send = 1'b0;           // not reset: a crossing in flight completes
    reg  [MW-1:0] hs_data;
    wire          hs_rcv;
    reg  [CW-1:0] hs_coef;                  // the COMMIT snapshot (both halves)
    reg  [3:0]    hs_ch;
    reg  [1:0]    hs_kind;
    reg           hi_due;                   // the HI half of hs_ch's COMMIT is next

    reg  [15:0]   wr_addr;
    reg  [31:0]   wr_data;
    reg           aw_seen, w_seen;
    wire          wr_fire = aw_seen && w_seen && !s_axi_bvalid;
    wire [3:0]    wr_ch   = wr_addr[13:10];
    wire [7:0]    wr_w    = wr_addr[9:2];
    wire          wr_ok   = (wr_addr[15:14] == 2'b00) && (wr_ch < N_CH);
    wire [7:0]    wr_sw   = wr_w - 8'd64;   // SHADOW word index

    // the lowest channel with a message to send
    reg  [3:0]    nx_ch;
    reg           nx_any;
    integer       i;
    always @(*) begin
        nx_ch = 4'd0; nx_any = 1'b0;
        for (i = N_CH - 1; i >= 0; i = i - 1)
            if (p_ctrl[i] || p_commit[i] || p_clr[i]) begin nx_ch = i; nx_any = 1'b1; end
    end

    // stats snapshot from aclk
    wire [SW-1:0] sn_out;
    wire          sn_req;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0; w_seen <= 1'b0;
            r_byp    <= {N_CH{1'b1}};
            p_ctrl   <= {N_CH{1'b0}};
            p_commit <= {N_CH{1'b1}};        // identity + bypass into the datapath
            p_clr    <= {N_CH{1'b0}};
            p_ident  <= {N_CH{1'b0}};
            c_fly    <= {N_CH{1'b0}};
            hi_due   <= 1'b0;
            for (i = 0; i < N_CH; i = i + 1) begin
                r_sh[i] <= IDENT; r_act[i] <= IDENT; r_ccnt[i] <= 8'd0;
            end
        end else begin
            // Message launcher, one handshake at a time (hold send until rcv,
            // then wait for !rcv). A COMMIT is LO then HI back to back; the HI
            // half carries the bypass bit as it is then, so it supersedes a
            // pending CTRL of that channel. It comes before the AXI write below,
            // so a write in the same cycle re-raises the flag it cleared.
            if (!hs_send && !hs_rcv) begin
                if (hi_due) begin
                    hs_data <= {hs_ch, K_HI, r_byp[hs_ch], hs_coef[CW-1:HW]};
                    hs_kind <= K_HI; hs_send <= 1'b1; hi_due <= 1'b0;
                    p_ctrl[hs_ch] <= 1'b0;
                end else if (nx_any) begin
                    hs_ch <= nx_ch; hs_send <= 1'b1;
                    if (p_commit[nx_ch]) begin
                        hs_coef <= r_sh[nx_ch];
                        hs_data <= {nx_ch, K_LO, r_byp[nx_ch], r_sh[nx_ch][HW-1:0]};
                        hs_kind <= K_LO; hi_due <= 1'b1;
                        p_commit[nx_ch] <= 1'b0; c_fly[nx_ch] <= 1'b1;
                    end else if (p_ctrl[nx_ch]) begin
                        hs_data <= {nx_ch, K_CTRL, r_byp[nx_ch], {HW{1'b0}}};
                        hs_kind <= K_CTRL; p_ctrl[nx_ch] <= 1'b0;
                    end else begin
                        hs_data <= {nx_ch, K_CLR, r_byp[nx_ch], {HW{1'b0}}};
                        hs_kind <= K_CLR; p_clr[nx_ch] <= 1'b0;
                    end
                end
            end else if (hs_send && hs_rcv) begin
                hs_send <= 1'b0;
                if (hs_kind == K_HI) begin
                    r_act[hs_ch]  <= hs_coef;
                    r_ccnt[hs_ch] <= r_ccnt[hs_ch] + 8'd1;
                    c_fly[hs_ch]  <= 1'b0;
                end
            end

            // Accept address and data independently, act once both are held.
            if (s_axi_awvalid && !aw_seen) begin
                aw_seen <= 1'b1; wr_addr <= s_axi_awaddr; s_axi_awready <= 1'b1;
            end else s_axi_awready <= 1'b0;
            if (s_axi_wvalid && !w_seen) begin
                w_seen <= 1'b1; wr_data <= s_axi_wdata; s_axi_wready <= 1'b1;
            end else s_axi_wready <= 1'b0;

            if (wr_fire) begin
                aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
                if (wr_ok && wr_w == 8'd0) begin
                    r_byp[wr_ch]  <= wr_data[0];
                    p_ctrl[wr_ch] <= 1'b1;
                    if (wr_data[1]) p_commit[wr_ch] <= 1'b1;
                    if (wr_data[2]) p_clr[wr_ch]    <= 1'b1;
                    if (wr_data[3]) p_ident[wr_ch]  <= 1'b1;
                end
                if (wr_ok && wr_w >= 8'd64 && wr_w < 8'd104)
                    r_sh[wr_ch][27*wr_sw[5:0] +: 27] <= wr_data[26:0];
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            // SHADOW_IDENTITY once no COMMIT of that channel waits for its snapshot
            for (i = 0; i < N_CH; i = i + 1)
                if (p_ident[i] && !p_commit[i] && !(wr_fire && wr_ok && wr_ch == i && wr_w == 8'd0)) begin
                    r_sh[i] <= IDENT; p_ident[i] <= 1'b0;
                end

        end
    end

    // stats snapshot store (not reset: the values are the datapath's)
    always @(posedge s_axi_aclk) begin
        if (sn_req && sn_out[SW-1 -: 4] < N_CH) begin
            st_so [sn_out[SW-1 -: 4]] <= sn_out[97:66];
            st_sg [sn_out[SW-1 -: 4]] <= sn_out[65:34];
            st_pk [sn_out[SW-1 -: 4]] <= sn_out[33:2];
            st_byp[sn_out[SW-1 -: 4]] <= sn_out[1];
            st_rst[sn_out[SW-1 -: 4]] <= sn_out[0];
        end
    end
    initial begin
        for (i = 0; i < N_CH; i = i + 1) begin
            st_so[i] = 32'd0; st_sg[i] = 32'd0; st_pk[i] = 32'd0;
        end
        st_byp = {N_CH{1'b1}}; st_rst = {N_CH{1'b0}};
    end

    // read channel
    reg  [15:0] rd_addr;
    wire [3:0]  rd_ch = rd_addr[13:10];
    wire [7:0]  rd_w  = rd_addr[9:2];
    wire [7:0]  rd_sw = rd_w - 8'd64;
    wire [7:0]  rd_aw = rd_w - 8'd128;
    reg  [26:0] rd_word;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0;
        end else if (!s_axi_arready && !s_axi_rvalid && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;            // address handshake completes next edge
            rd_addr       <= s_axi_araddr;
        end else if (s_axi_arready) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b1;
            s_axi_rdata   <= 32'd0;
            if (rd_addr[15:14] == 2'b00 && rd_ch < N_CH) begin
                if (rd_w >= 8'd64 && rd_w < 8'd104) begin
                    rd_word = r_sh[rd_ch][27*rd_sw[5:0] +: 27];
                    s_axi_rdata <= {{5{rd_word[26]}}, rd_word};
                end else if (rd_w >= 8'd128 && rd_w < 8'd168) begin
                    rd_word = r_act[rd_ch][27*rd_aw[5:0] +: 27];
                    s_axi_rdata <= {{5{rd_word[26]}}, rd_word};
                end else case (rd_w)
                    8'd0: s_axi_rdata <= {31'd0, r_byp[rd_ch]};
                    8'd1: s_axi_rdata <= {16'd0, r_ccnt[rd_ch], 4'd0, st_rst[rd_ch],
                                          p_ctrl[rd_ch] | p_commit[rd_ch] | p_clr[rd_ch] | c_fly[rd_ch] |
                                          ((hs_send || hi_due) && hs_ch == rd_ch),
                                          p_commit[rd_ch] | c_fly[rd_ch], st_byp[rd_ch]};
                    8'd2: s_axi_rdata <= ID;
                    8'd3: s_axi_rdata <= CONFIG;
                    8'd4: s_axi_rdata <= st_so[rd_ch];
                    8'd5: s_axi_rdata <= st_sg[rd_ch];
                    8'd6: s_axi_rdata <= st_pk[rd_ch];
                    8'd7: s_axi_rdata <= {8'd0, 4'd0, rd_ch, SSR8, NCH8};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Clock-domain crossings
    // =========================================================================
    // DEST_EXT_HSK: the aclk side acknowledges a message only once it has
    // reached the cores (hs_ack below), so src_rcv -- and STATUS -- mean
    // "applied", whatever the two clocks' ratio.
    wire [MW-1:0] hs_out;
    wire          hs_req;           // level, hs_out valid while it is high
    reg           hs_ack = 1'b0;
    xpm_cdc_handshake #(.DEST_EXT_HSK(1), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3),
                        .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .WIDTH(MW))
    u_msg (.src_clk(s_axi_aclk), .src_in(hs_data), .src_send(hs_send), .src_rcv(hs_rcv),
           .dest_clk(aclk), .dest_out(hs_out), .dest_req(hs_req), .dest_ack(hs_ack));

    reg  [SW-1:0] sn_data;
    reg           sn_send = 1'b0;   // not reset, like hs_send
    wire          sn_rcv;
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3),
                        .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .WIDTH(SW))
    u_stat (.src_clk(aclk), .src_in(sn_data), .src_send(sn_send), .src_rcv(sn_rcv),
            .dest_clk(s_axi_aclk), .dest_out(sn_out), .dest_req(sn_req), .dest_ack(1'b0));

    // =========================================================================
    // aclk side: message decode, per-channel reset, cores, statistics
    // =========================================================================
    // Registered reset, a two-level tree per channel (each core's reset fans
    // out to ~2.5k pipe, coefficient and statistics registers: keep it off
    // one net; the replicas of each level drive at most 64 / 32 loads).
    reg              rst_a = 1'b1;
    (* max_fanout = 32 *) reg [N_CH-1:0] rst_b  = {N_CH{1'b1}};
    (* max_fanout = 64 *) reg [N_CH-1:0] rst_ch = {N_CH{1'b1}};
    always @(posedge aclk) begin
        rst_a  <= !aresetn;
        rst_b  <= {N_CH{rst_a}};
        rst_ch <= rst_b;
    end

    wire [3:0]    m_ch   = hs_out[MW-1 -: 4];
    wire [1:0]    m_kind = hs_out[MW-5 -: 2];
    wire          m_byp  = hs_out[HW];
    // A message becomes per-channel events (COMMIT, a bypass value, CLR) that
    // pass CP register stages, and so does the set: each core gets the bus
    // through CP stages of its own (it is quasi-static -- hs_out holds until
    // the next message, long after -- and fans out to every lane's DSP
    // operand registers, so the stages keep that route off one cycle). The
    // set and the bypass bit of a COMMIT then apply on the same edge.
    localparam integer CP = 2;
    reg  [HW-1:0]   lo_buf;
    reg  [N_CH-1:0] e_commit [1:CP];
    reg  [N_CH-1:0] e_bset   [1:CP];     // a bypass value is carried
    reg  [N_CH-1:0] e_bval   [1:CP];
    reg  [N_CH-1:0] e_clr    [1:CP];
    reg  [N_CH-1:0] a_byp, a_commit, a_clr;
    // hs_age counts the cycles dest_req has been high: 0 -> the message is
    // decoded once (hs_new), CP+2 -> its events have reached the cores, so it
    // is acknowledged. Level-based, so a lost edge cannot wedge the crossing.
    localparam integer AGE_ACK = CP + 2;
    reg  [3:0]      hs_age = 4'd0;
    wire            hs_new = hs_req && hs_age == 4'd0;  // a message, once
    integer j;
    always @(posedge aclk) begin
        if (!hs_req)                 hs_age <= 4'd0;
        else if (hs_age != AGE_ACK)  hs_age <= hs_age + 4'd1;
        hs_ack <= hs_req && hs_age == AGE_ACK;      // applied: acknowledge until the source lets go
        if (hs_new && m_kind == K_LO) lo_buf <= hs_out[HW-1:0];
        for (i = 0; i < N_CH; i = i + 1) begin
            e_commit[1][i] <= hs_new && m_ch == i && m_kind == K_HI;
            e_bset[1][i]   <= hs_new && m_ch == i && (m_kind == K_CTRL || m_kind == K_HI);
            e_bval[1][i]   <= m_byp;
            e_clr[1][i]    <= hs_new && m_ch == i && m_kind == K_CLR;
        end
        for (j = 2; j <= CP; j = j + 1) begin
            e_commit[j] <= e_commit[j-1];
            e_bset[j]   <= e_bset[j-1];
            e_bval[j]   <= e_bval[j-1];
            e_clr[j]    <= e_clr[j-1];
        end
        a_commit <= e_commit[CP];
        a_clr    <= e_clr[CP];
        for (i = 0; i < N_CH; i = i + 1)
            if (rst_ch[i])          a_byp[i] <= 1'b1;
            else if (e_bset[CP][i]) a_byp[i] <= e_bval[CP][i];
    end
    wire [CW-1:0] coef_bus = {hs_out[HW-1:0], lo_buf};

    reg  [3:0]  rr = 4'd0;
    wire [N_CH-1:0] tv;
    reg  [31:0] so_cnt [0:N_CH-1];
    reg  [31:0] sg_cnt [0:N_CH-1];
    reg  [15:0] pk_in  [0:N_CH-1];
    reg  [15:0] pk_out [0:N_CH-1];
    reg  [N_CH-1:0] rst_seen;
    wire [N_CH-1:0] byp_out;

    genvar gc;
    generate for (gc = 0; gc < N_CH; gc = gc + 1) begin : g_ch
        wire [4:0]  so_inc;
        wire [6:0]  sg_inc;
        wire [15:0] am_in, am_out;
        wire [CW-1:0] act_unused;
        wire        tlast_unused, tready_unused;

        reg [CW-1:0] cn [1:CP];          // the set, CP stages per channel
        integer k;
        always @(posedge aclk) begin
            cn[1] <= coef_bus;
            for (k = 2; k <= CP; k = k + 1) cn[k] <= cn[k-1];
        end

        dpd_mpl_core #(.SSR(SSR)) u_core (
            .aclk(aclk), .aresetn(!rst_ch[gc]),
            .s_axis_tdata(s_axis_tdata[gc*W +: W]), .s_axis_tvalid(s_axis_tvalid),
            .s_axis_tready(tready_unused), .s_axis_tlast(1'b0),
            .m_axis_tdata(m_axis_tdata[gc*W +: W]), .m_axis_tvalid(tv[gc]),
            .m_axis_tready(1'b1), .m_axis_tlast(tlast_unused),
            .coef_next(cn[CP]), .coef_commit(a_commit[gc]), .bypass(a_byp[gc]),
            .coef_active(act_unused), .bypass_out(byp_out[gc]),
            .sat_out_inc(so_inc), .sat_gain_inc(sg_inc),
            .in_absmax(am_in), .out_absmax(am_out));

        wire [32:0] so_sum = {1'b0, so_cnt[gc]} + so_inc;
        wire [32:0] sg_sum = {1'b0, sg_cnt[gc]} + sg_inc;
        always @(posedge aclk) begin
            if (rst_ch[gc] || a_clr[gc]) begin
                so_cnt[gc] <= 32'd0; sg_cnt[gc] <= 32'd0;
                pk_in[gc]  <= 16'd0; pk_out[gc] <= 16'd0;
            end else begin
                so_cnt[gc] <= so_sum[32] ? 32'hFFFFFFFF : so_sum[31:0];
                sg_cnt[gc] <= sg_sum[32] ? 32'hFFFFFFFF : sg_sum[31:0];
                if (am_in  > pk_in[gc])  pk_in[gc]  <= am_in;
                if (am_out > pk_out[gc]) pk_out[gc] <= am_out;
            end
            if (rst_ch[gc])         rst_seen[gc] <= 1'b1;
            else if (a_commit[gc])  rst_seen[gc] <= 1'b0;
        end
    end endgenerate

    assign m_axis_tvalid = tv[0];   // every core carries the same valid pipe

    // statistics snapshots, round-robin over the channels
    always @(posedge aclk) begin
        if (!sn_send && !sn_rcv) begin
            sn_data <= {rr, so_cnt[rr], sg_cnt[rr], pk_out[rr], pk_in[rr], byp_out[rr], rst_seen[rr]};
            sn_send <= 1'b1;
        end else if (sn_send && sn_rcv) begin
            sn_send <= 1'b0;
            rr      <= (rr == N_CH - 1) ? 4'd0 : rr + 4'd1;
        end
    end

endmodule

`default_nettype wire
