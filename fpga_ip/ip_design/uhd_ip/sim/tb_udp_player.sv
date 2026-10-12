// tb_udp_player -- plays the UHD host against udp_player (PROTOCOL.md 6/7).
//
// The testbench builds host frames (ARP requests, VRT sample packets) and
// feeds them to s_axis_rx the way a CMAC does: no tready, random tvalid gaps
// inside and between frames, tuser on tlast for a bad FCS. It keeps a host
// flow-control model: it sends only while sent - consumed <= credit, with
// consumed taken from the status packets the DUT sends back.
//
// Everything observable is written to player.log and checked by
// check_player.py:
//   D <tick> <hex>      every non-zero DAC beat (tick = adc_time that cycle),
//                       M_WIDTH/4 hex digits
//   C <hex>             every m_axis_ctl frame, byte 0 first
//   S <hex>             (INTEG) every udp_streamer frame out of axis_pkt_arb
//   # ...               test metadata (bursts, expected values, stats)
//
// Sample model: sample n of burst B is I = (7n + 4096B) | 1, Q = n ^ (B<<8) ^ 0xA5A5
// (I is odd, so a sample is never zero and a zero beat is never data).
//
// Compile with -d INTEG to add udp_streamer + axis_pkt_arb and check that the
// arbiter merges the two frame streams without corrupting either.
//
// TICK_STEP (xelab -generic_top): ticks per slot. M_WIDTH (128/256/512): DAC
// beat width, M_WIDTH/32 slots per beat. adc_time advances by
// (M_WIDTH/32)*TICK_STEP per beat, packet TSFs by TICK_STEP per slot, and
// every time offset in the sequence is scaled by TICK_STEP*M_WIDTH/128 so the
// scenarios keep the same length in adc_clk cycles. The ADC clock follows the
// PROTOCOL.md 9 table (300 / 150 / 60 MHz for 128 / 256 / 512 bits).
// check_player.py --tick-step/--width must match.
//
// FMT (xelab -generic_top; 0 sc16, 1 sc8, 2 sc12, 3 fc32; PROTOCOL.md 10): the
// player's FMT register. Packets then carry wire-format samples (model below,
// mirrored in check_player.py) whose payload bytes are logged as
//   W <burst> <first slot> <hex>
// so the checker can hold them to its reference packer (UHD's sc12 pack, numpy
// float32) before deriving the DAC samples it expects. Wire models, slot n of
// burst B:
//   sc8   I = (7n + 16B) | 1, Q = n ^ (B<<3) ^ 0xA5             (8 bit)
//   sc12  I = (7n + 64B) | 1, Q = n ^ (B<<5) ^ 0xA5A            (12 bit)
//   fc32  Q = q/32768 with q = int16((n ^ (B<<8) ^ 0xA5A5) | 1); I = one of 24
//         corner floats (NaN, inf, saturation, ties) when n % 64 < 24, else
//         (4i + FR[n % 8]) / 2^17 with i = int16((7n + 4096B) | 1)
// Packet sizes follow the format's limits (sc8 up to 4096 slots, sc12 2688,
// fc32 1024, with odd-word fc32 packets inside and at the end of bursts).
// With -d INTEG the streamer runs the same FMT (sc16 for fc32 at M_WIDTH 512,
// which it does not support).
`timescale 1ns / 1ps

// FAST = 1 (xelab -generic_top): adc_clk at 300 MHz whatever M_WIDTH -- at
// 512 bits that is the "max rate" geometry, one 16-slot group per cycle.
// M_WIDTH 1024 (sc8max builds, sc8 only: run it with FMT 1) always runs its
// own max-rate geometry: adc_clk 187.5 MHz, one sc8 wire word per cycle.
// TXBW (xelab -generic_top): TX_BUF_WORDS (default 256); above 256 the
// metadata FIFO grows to 4096 and the overflow phase fills the buffer with
// maximum-size packets.
module tb_udp_player #(parameter int TICK_STEP = 1, parameter int M_WIDTH = 128,
                       parameter int FMT = 0, parameter int FAST = 0,
                       parameter int TXBW = 256, parameter int CHAIN = 0,
                       parameter int CHAIN_D = 64);
    localparam int BPS  = (FMT == 1) ? 2 : (FMT == 2) ? 3 : (FMT == 3) ? 8 : 4;  // bytes per slot
    localparam int GW   = (FMT == 2) ? 3 : 1;          // smallest packet, words
    localparam int GS   = GW * 64 / BPS;               // ... in slots
    localparam int SFMT = (FMT == 3 && M_WIDTH == 512) ? 0 : FMT;   // INTEG streamer
    localparam int  SLOTS = M_WIDTH / 32;
    localparam int  K     = M_WIDTH / 128;          // time-offset scale
    localparam int  MAXR  = FAST || (M_WIDTH == 1024);   // a group per cycle: timed bursts
    localparam real ADC_HALF = (M_WIDTH == 1024) ? 2.6667 : FAST ? 1.6667 :
                               (M_WIDTH == 512) ? 8.3333 : (M_WIDTH == 256) ? 3.3333 : 1.6667;
    localparam int MAXS   = (FMT == 1) ? 4096 : (FMT == 2) ? 2688 : (FMT == 3) ? 1024 : 2048;
    localparam int RSV    = 16;
    localparam int CREDIT = TXBW - RSV;
`ifdef INTEG
    localparam int FCI    = 8;
`else
    localparam int FCI    = 32;
`endif
    localparam [47:0] MY_MAC   = 48'h02_11_22_33_44_55;
    localparam [47:0] HOST_MAC = 48'h1a_2b_3c_4d_5e_6f;
    localparam [31:0] MY_IP    = 32'hC0A80502;
    localparam [31:0] HOST_IP  = 32'hC0A80501;
    localparam [15:0] TX_PORT  = 16'd49900;
    localparam [15:0] ASYNC_PORT = 16'd49826;
    localparam [15:0] SRC_PORT = 16'd49801;
    localparam [31:0] SID      = 32'h5A170003;

    reg adc_clk = 0, tx_clk = 0, axi_clk = 0;
    always #ADC_HALF adc_clk = ~adc_clk;   // 300 / 150 / 60 MHz
    bit tx_run = 0;                      // the CMAC user clock starts late
    always #1.5515 tx_clk  = tx_run ? ~tx_clk : tx_clk;    // 322.27 MHz
    always #5.0    axi_clk = ~axi_clk;   // 100 MHz
    reg adc_rstn = 0, tx_rstn = 0, axi_rstn = 0;

    integer fd;
    int errors = 0;

    // ------------------------------------------------------------------
    // Time base
    // ------------------------------------------------------------------
    wire [63:0] adc_time;
`ifndef INTEG
    reg  [63:0] tb_time = 64'h0000_0000_FFFF_C000;   // crosses 2^32 during the run
    always @(posedge adc_clk) if (adc_rstn) tb_time <= tb_time + SLOTS * TICK_STEP;
    assign adc_time = tb_time;
`endif

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg  [511:0] rx_tdata = 0; reg [63:0] rx_tkeep = 0;
    reg          rx_tvalid = 0, rx_tlast = 0, rx_tuser = 0;
    wire [511:0] ctl_tdata; wire [63:0] ctl_tkeep; wire ctl_tvalid, ctl_tlast, ctl_tuser;
    wire         ctl_tready;
    reg  [M_WIDTH-1:0] dma_tdata = 0; reg dma_tvalid = 0; wire dma_tready;
    wire [M_WIDTH-1:0] dac_tdata; wire dac_tvalid; reg dac_tready = 1;

    reg  [7:0]  awaddr, araddr; reg awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata;
    wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata; wire [1:0] bresp, rresp;
    reg  [7:0]  awaddr_p, araddr_p; reg awvalid_p = 0, wvalid_p = 0, arvalid_p = 0;
    wire awready_p, wready_p, bvalid_p, arready_p, rvalid_p; wire [31:0] rdata_p;

    // XFER_DEPTH: 32 (the build uses 512) leaves ~16 groups of play-out
    // ahead of the mover. With FMT != 0 the converter adds up to 12 tx_clk of
    // latency, which at fc32 / M_WIDTH 512 is just more than burst 6 (a bad-
    // FCS packet the mover discards word by word) leaves: use 64 there.
    // META_DEPTH: 4096 above 256 words, as the builds have (v49_tx_buffer): the
    // overflow phase parks ~2056 8-word sc8 packets at TXBW 32768, more than 2048
    udp_player #(.TX_BUF_WORDS(TXBW), .TX_BUF_RESERVE(RSV), .META_DEPTH((TXBW > 256) ? 4096 : 64),
                 .XFER_DEPTH((FMT == 0) ? 32 : 64), .CHAIN_STAGES(CHAIN), .CHAIN_DEPTH(CHAIN_D),
                 .URAM_RD_LATENCY(4), .TICK_STEP(TICK_STEP),
                 .M_WIDTH(M_WIDTH)) dut (
        .tx_clk(tx_clk), .tx_aresetn(tx_rstn),
        .s_axis_rx_tdata(rx_tdata), .s_axis_rx_tkeep(rx_tkeep), .s_axis_rx_tvalid(rx_tvalid),
        .s_axis_rx_tlast(rx_tlast), .s_axis_rx_tuser(rx_tuser),
        .m_axis_ctl_tdata(ctl_tdata), .m_axis_ctl_tkeep(ctl_tkeep), .m_axis_ctl_tvalid(ctl_tvalid),
        .m_axis_ctl_tlast(ctl_tlast), .m_axis_ctl_tuser(ctl_tuser), .m_axis_ctl_tready(ctl_tready),
        .adc_clk(adc_clk), .adc_aresetn(adc_rstn), .adc_time(adc_time),
        .s_axis_dma_tdata(dma_tdata), .s_axis_dma_tvalid(dma_tvalid), .s_axis_dma_tready(dma_tready),
        .m_axis_dac_tdata(dac_tdata), .m_axis_dac_tvalid(dac_tvalid), .m_axis_dac_tready(dac_tready),
        .s_axi_aclk(axi_clk), .s_axi_aresetn(axi_rstn),
        .s_axi_awaddr({8'd0, awaddr_p}), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid_p), .s_axi_awready(awready_p),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid_p), .s_axi_wready(wready_p),
        .s_axi_bresp(), .s_axi_bvalid(bvalid_p), .s_axi_bready(bready),
        .s_axi_araddr({8'd0, araddr_p}), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid_p), .s_axi_arready(arready_p),
        .s_axi_rdata(rdata_p), .s_axi_rresp(), .s_axi_rvalid(rvalid_p), .s_axi_rready(rready));

    // Frames seen by the host: straight from m_axis_ctl, or (INTEG) out of the arbiter.
    wire [511:0] mon_tdata; wire [63:0] mon_tkeep; wire mon_tvalid, mon_tlast; reg mon_tready = 1;

`ifdef INTEG
    reg  [7:0]  awaddr_s, araddr_s; reg awvalid_s = 0, wvalid_s = 0, arvalid_s = 0;
    wire awready_s, wready_s, bvalid_s, arready_s, rvalid_s; wire [31:0] rdata_s;
    wire [511:0] st_tdata; wire [63:0] st_tkeep; wire st_tvalid, st_tlast, st_tuser, st_tready;
    wire mon_tuser;
    udp_streamer #(.DATA_FIFO_DEPTH(512), .TICK_STEP(TICK_STEP), .S_WIDTH(M_WIDTH)) u_str (
        .adc_clk(adc_clk), .adc_aresetn(adc_rstn),
        .s_axis_tdata({M_WIDTH{1'b0}}), .s_axis_tvalid(1'b1), .s_axis_tready(),
        .m_axis_adc_tdata(), .m_axis_adc_tvalid(), .m_axis_adc_tready(1'b1),
        .adc_time(adc_time),
        .tx_clk(tx_clk), .tx_aresetn(tx_rstn),
        .m_axis_tdata(st_tdata), .m_axis_tkeep(st_tkeep), .m_axis_tvalid(st_tvalid),
        .m_axis_tlast(st_tlast), .m_axis_tuser(st_tuser), .m_axis_tready(st_tready),
        .cmac_rx_aligned(1'b1), .cmac_tx_ready(1'b1),
        .s_axi_aclk(axi_clk), .s_axi_aresetn(axi_rstn),
        .s_axi_awaddr({8'd0, awaddr_s}), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid_s), .s_axi_awready(awready_s),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid_s), .s_axi_wready(wready_s),
        .s_axi_bresp(), .s_axi_bvalid(bvalid_s), .s_axi_bready(bready),
        .s_axi_araddr({8'd0, araddr_s}), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid_s), .s_axi_arready(arready_s),
        .s_axi_rdata(rdata_s), .s_axi_rresp(), .s_axi_rvalid(rvalid_s), .s_axi_rready(rready));
    axis_pkt_arb #(.REG_OUT(1)) u_arb (
        .clk(tx_clk), .aresetn(tx_rstn),
        .s0_axis_tdata(st_tdata), .s0_axis_tkeep(st_tkeep), .s0_axis_tvalid(st_tvalid),
        .s0_axis_tlast(st_tlast), .s0_axis_tuser(st_tuser), .s0_axis_tready(st_tready),
        .s1_axis_tdata(ctl_tdata), .s1_axis_tkeep(ctl_tkeep), .s1_axis_tvalid(ctl_tvalid),
        .s1_axis_tlast(ctl_tlast), .s1_axis_tuser(ctl_tuser), .s1_axis_tready(ctl_tready),
        .m_axis_tdata(mon_tdata), .m_axis_tkeep(mon_tkeep), .m_axis_tvalid(mon_tvalid),
        .m_axis_tlast(mon_tlast), .m_axis_tuser(mon_tuser), .m_axis_tready(mon_tready));
    // AXI select: 0 = player, 1 = streamer
    reg axsel = 0;
    always @(*) begin
        awaddr_p = awaddr; araddr_p = araddr; awaddr_s = awaddr; araddr_s = araddr;
        awvalid_p = awvalid & ~axsel; wvalid_p = wvalid & ~axsel; arvalid_p = arvalid & ~axsel;
        awvalid_s = awvalid &  axsel; wvalid_s = wvalid &  axsel; arvalid_s = arvalid &  axsel;
    end
    assign awready = axsel ? awready_s : awready_p;
    assign wready  = axsel ? wready_s  : wready_p;
    assign bvalid  = axsel ? bvalid_s  : bvalid_p;
    assign arready = axsel ? arready_s : arready_p;
    assign rvalid  = axsel ? rvalid_s  : rvalid_p;
    assign rdata   = axsel ? rdata_s   : rdata_p;
`else
    assign mon_tdata = ctl_tdata; assign mon_tkeep = ctl_tkeep;
    assign mon_tvalid = ctl_tvalid; assign mon_tlast = ctl_tlast;
    assign ctl_tready = mon_tready;
    always @(*) begin
        awaddr_p = awaddr; araddr_p = araddr;
        awvalid_p = awvalid; wvalid_p = wvalid; arvalid_p = arvalid;
    end
    assign awready = awready_p; assign wready = wready_p; assign bvalid = bvalid_p;
    assign arready = arready_p; assign rvalid = rvalid_p; assign rdata = rdata_p;
`endif

    // ------------------------------------------------------------------
    // AXI-Lite
    // ------------------------------------------------------------------
    task axi_wr(input [7:0] a, input [31:0] d);
        begin
            @(posedge axi_clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
            fork
                begin wait (awready); @(posedge axi_clk); awvalid <= 0; end
                begin wait (wready);  @(posedge axi_clk); wvalid  <= 0; end
            join
            wait (bvalid); @(posedge axi_clk);
        end
    endtask
    task axi_rd(input [7:0] a, output [31:0] d);
        begin
            @(posedge axi_clk); araddr <= a; arvalid <= 1;
            wait (arready); @(posedge axi_clk); arvalid <= 0;
            wait (rvalid); d = rdata; @(posedge axi_clk);
        end
    endtask
    task expect_rd(input [7:0] a, input [31:0] want, input string what);
        reg [31:0] d;
        begin
            axi_rd(a, d);
            $fwrite(fd, "# reg %s 0x%02x = %0d (want %0d)\n", what, a, d, want);
            if (d !== want) begin
                $display("ERROR reg %s (0x%02x) = %0d / 0x%h, want %0d / 0x%h", what, a, d, d, want, want);
                errors++;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // CMAC RX model: a queue of frames, sent with random tvalid gaps
    // ------------------------------------------------------------------
    localparam int FMEM = 1 << 22;
    byte unsigned fmem [0:FMEM-1];
    typedef struct { int off; int len; bit bad; } fdesc_t;
    fdesc_t fq[$];
    int fwp = 0, bp = 0, bstart = 0;
    int gap_pct = 20;
    int frames_sent = 0;

    fdesc_t cur;
    int     cur_b = -1;
    always @(posedge tx_clk) begin
        if (cur_b < 0 && fq.size() > 0) begin cur = fq.pop_front(); cur_b = 0; end
        if (cur_b >= 0 && ($urandom % 100) >= gap_pct) begin
            bit last;
            for (int i = 0; i < 64; i++) begin
                int p;
                p = cur_b * 64 + i;
                rx_tdata[8*i +: 8] <= (p < cur.len) ? fmem[cur.off + p] : $urandom;
                rx_tkeep[i]        <= (p < cur.len);
            end
            last = ((cur_b + 1) * 64 >= cur.len);
            rx_tvalid <= 1; rx_tlast <= last; rx_tuser <= last && cur.bad;
            if (last) cur_b = -1; else cur_b = cur_b + 1;
        end else begin
            rx_tvalid <= 0; rx_tlast <= $urandom; rx_tuser <= $urandom;
            rx_tdata  <= {16{$urandom}};
        end
    end

    function void b8(input [7:0] v);   fmem[bp] = v; bp = bp + 1; endfunction
    function void b16(input [15:0] v); b8(v[15:8]); b8(v[7:0]); endfunction
    function void b32(input [31:0] v); b16(v[31:16]); b16(v[15:0]); endfunction
    function void b48(input [47:0] v); b16(v[47:32]); b32(v[31:0]); endfunction
    function void l16(input [15:0] v); b8(v[7:0]); b8(v[15:8]); endfunction
    function void l32(input [31:0] v); l16(v[15:0]); l16(v[31:16]); endfunction
    function void begin_frame();
        if (fwp + 10000 > FMEM) fwp = 0;
        bp = fwp; bstart = fwp;
    endfunction
    function void end_frame(input bit bad);
        fdesc_t d;
        d.off = bstart; d.len = bp - bstart; d.bad = bad;
        fq.push_back(d);
        fwp = bp;
        frames_sent++;
    endfunction
    function void ip_csum_patch(input int ip0);   // ip0 = byte offset of the IPv4 header
        int s;
        s = 0;
        for (int i = 0; i < 20; i += 2) s += {fmem[ip0 + i], fmem[ip0 + i + 1]};
        while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
        s = ~s & 16'hFFFF;
        fmem[ip0 + 10] = s[15:8]; fmem[ip0 + 11] = s[7:0];
    endfunction

    task arp_req(input [47:0] dmac, input [47:0] sha, input [31:0] spa, input [31:0] tpa, input bit bad);
        begin
            begin_frame();
            b48(dmac); b48(sha); b16(16'h0806);
            b16(16'h0001); b16(16'h0800); b8(6); b8(4); b16(16'h0001);
            b48(sha); b32(spa); b48(48'h0); b32(tpa);
            repeat (18) b8(8'h00);
            end_frame(bad);
        end
    endtask

    function [31:0] samp(input int B, input int n);
        reg [15:0] i, q;
        i = ((n * 7 + B * 4096) | 1);
        q = n ^ (B << 8) ^ 16'hA5A5;
        samp = {q, i};
    endfunction

    // ---- wire-format models (FMT != 0)
    localparam bit [31:0] FCORN [24] = '{
        32'h7FC00000, 32'hFFC00001, 32'h7F800000, 32'hFF800000,   // NaN, -NaN, +inf, -inf
        32'h3F800000, 32'hBF800000, 32'h40000000, 32'hC0600000,   // 1, -1, 2, -3.5
        32'h7149F2CA, 32'h8C0A0B0C, 32'h3F7FFFFF, 32'hBF800001,   // 1e30, -tiny, 1-eps, -1-eps
        32'h38000000, 32'h37800000, 32'h37C00000, 32'h38400000,   // x32768: 1, 0.5, 0.75, 1.5
        32'h38200000, 32'h38A00000, 32'hB7800000, 32'hB8400000,   // 1.25, 2.5, -0.5, -1.5
        32'h80000000, 32'h00000001, 32'h3F7FFF00, 32'hBF7FFF00};  // -0, denormal, +-32767.5
    localparam int FR [8] = '{0, 2, -2, 1, 3, -1, 6, -6};         // quarters of an LSB

    function automatic [31:0] fbits(input int m);    // float32 of m / 2^17, exact
        int a, p;
        begin
            if (m == 0) return 32'd0;
            a = (m < 0) ? -m : m;
            p = 0;
            while ((a >> (p + 1)) != 0) p++;
            return {(m < 0) ? 1'b1 : 1'b0, 8'(127 + p - 17), 23'((a << (23 - p)) & 32'h7FFFFF)};
        end
    endfunction
    function automatic [31:0] wslot_i(input int B, input int n);
        reg [15:0] v;
        case (FMT)
            1: return ((n * 7 + B * 16) | 1) & 8'hFF;
            2: return ((n * 7 + B * 64) | 1) & 12'hFFF;
            default: begin
                if (n % 64 < 24) return FCORN[n % 64];
                v = (n * 7 + B * 4096) | 1;
                return fbits(4 * $signed(v) + FR[n % 8]);
            end
        endcase
    endfunction
    function automatic [31:0] wslot_q(input int B, input int n);
        reg [15:0] v;
        case (FMT)
            1: return (n ^ (B << 3) ^ 8'hA5) & 8'hFF;
            2: return (n ^ (B << 5) ^ 12'hA5A) & 12'hFFF;
            default: begin
                v = (n ^ (B << 8) ^ 16'hA5A5) | 1;
                return fbits(4 * $signed(v));
            end
        endcase
    endfunction
    // byte k of a packet payload whose first slot is n0 (n0 % 4 == 0 for sc12)
    function automatic [7:0] wbyte(input int B, input int n0, input int k);
        reg [11:0] v [8];
        reg [31:0] l [3];
        reg [31:0] w;
        int n;
        case (FMT)
            1: begin
                n = n0 + k / 2;
                w = (k % 2 == 0) ? wslot_i(B, n) : wslot_q(B, n);
                return w[7:0];
            end
            2: begin   // UHD pack(): 4 slots in 3 little-endian lines
                n = n0 + 4 * (k / 12);
                for (int j = 0; j < 4; j++) begin
                    v[2 * j] = wslot_i(B, n + j); v[2 * j + 1] = wslot_q(B, n + j);
                end
                l[0] = {v[0], v[1], v[2][11:4]};
                l[1] = {v[2][3:0], v[3], v[4], v[5][11:8]};
                l[2] = {v[5][7:0], v[6], v[7]};
                w = l[(k % 12) / 4];
                return w[8 * (k % 4) +: 8];
            end
            default: begin
                n = n0 + k / 8;
                w = (k % 8 < 4) ? wslot_i(B, n) : wslot_q(B, n);
                return w[8 * (k % 4) +: 8];
            end
        endcase
    endfunction

    // host flow-control state
    int unsigned host_sent = 0;     // words the FPGA will eventually pop
    int unsigned host_cons = 0;     // latest consumed from a status packet
    int          host_pcnt = 0;
    int          n_acc = 0;          // packets expected to be accepted
    int          ip_id = 0;

    task send_pkt(input int B, input int n0, input int ns, input bit sob, input bit eob,
                  input bit timed, input [63:0] tsf,
                  input bit bad = 0, input bit fc = 1, input int vlen_adj = 0,
                  input int ulen_adj = 0, input [15:0] dport = TX_PORT,
                  input [47:0] dmac = MY_MAC, input [31:0] dip = MY_IP,
                  input bit counts = 1);
        int nw, vlen, ulen, ip0;
        reg [31:0] w0;
        begin
            nw = ns * BPS / 64;
            if (fc) while (host_sent - host_cons + nw > CREDIT) @(posedge tx_clk);
            vlen = 4 + ns * BPS / 4 + vlen_adj;
            ulen = 8 + 4 * vlen + ulen_adj;
            begin_frame();
            b48(dmac); b48(HOST_MAC); b16(16'h0800);
            ip0 = bp;
            b8(8'h45); b8(8'h00); b16(ulen + 20); b16(ip_id); b16(16'h4000); b8(64); b8(17);
            b16(16'h0000); b32(HOST_IP); b32(dip);
            ip_csum_patch(ip0);
            ip_id++;
            b16(16'd50000); b16(dport); b16(ulen); b16(16'h0000);
            w0 = (32'h1 << 28) | (sob << 25) | (eob << 24) | (timed << 20) |
                 ((host_pcnt & 15) << 16) | (vlen & 16'hFFFF);
            l32(w0); l32(SID); l32(tsf[63:32]); l32(tsf[31:0]);
            if (FMT == 0)
                for (int i = 0; i < 4 * vlen - 16; i += 4) l32(samp(B, n0 + i / 4));
            else begin
                for (int i = 0; i < 4 * vlen - 16; i++) b8(wbyte(B, n0, i));
                if (counts && vlen_adj == 0 && ulen_adj == 0) begin
                    $fwrite(fd, "W %0d %0d ", B, n0);
                    for (int i = bp - (4 * vlen - 16); i < bp; i++) $fwrite(fd, "%02x", fmem[i]);
                    $fwrite(fd, "\n");
                end
            end
            end_frame(bad);
            if (counts) begin
                host_pcnt++;
                host_sent += nw;
                if (!bad) n_acc++;
            end
        end
    endtask

    // A burst: list of packet sizes; TSF advances with the packets as UHD does.
    task send_burst(input int B, input int sizes[], input bit timed, input [63:0] tsf,
                    input int skip_pcnt_before = -1);
        int n0;
        begin
            n0 = 0;
            for (int k = 0; k < sizes.size(); k++) begin
                if (k == skip_pcnt_before) host_pcnt++;
                send_pkt(B, n0, sizes[k], k == 0, k == sizes.size() - 1, timed,
                         tsf + n0 * TICK_STEP);
                n0 += sizes[k];
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Host side monitor of the frames coming back
    // ------------------------------------------------------------------
    byte unsigned mbuf [0:16383];
    int  mlen = 0, n_ctl = 0, n_status = 0, n_arp_rx = 0, n_str = 0, bubbles = 0;
    int  n_ev [0:255];
    bit  in_frame = 0;
    initial for (int i = 0; i < 256; i++) n_ev[i] = 0;
    always @(posedge tx_clk) begin
        if (in_frame && !mon_tvalid) bubbles++;
        if (mon_tvalid && mon_tready) begin
            in_frame = !mon_tlast;
            for (int b = 0; b < 64; b++) if (mon_tkeep[b]) begin mbuf[mlen] = mon_tdata[8*b +: 8]; mlen++; end
            if (mon_tlast) begin
                bit is_status, is_str;
                is_status = (mlen == 66) && {mbuf[36], mbuf[37]} == ASYNC_PORT && {mbuf[12], mbuf[13]} == 16'h0800;
                is_str = (mlen > 66) && {mbuf[12], mbuf[13]} == 16'h0800;
                if (is_str) $fwrite(fd, "S "); else $fwrite(fd, "C ");
                for (int i = 0; i < mlen; i++) $fwrite(fd, "%02x", mbuf[i]);
                $fwrite(fd, "\n");
                if (is_str) n_str++;
                else begin
                    n_ctl++;
                    if (is_status) begin
                        n_status++;
                        host_cons = {mbuf[65], mbuf[64], mbuf[63], mbuf[62]};
                        n_ev[mbuf[58]]++;
                    end else if ({mbuf[12], mbuf[13]} == 16'h0806) n_arp_rx++;
                end
                mlen = 0;
            end
        end
    end
    always @(posedge tx_clk) mon_tready <= ($urandom % 100) < `ifdef INTEG 70 `else 85 `endif;

    // ------------------------------------------------------------------
    // DAC side: log non-zero beats; check the DMA pass-through
    // ------------------------------------------------------------------
    bit log_dac = 0, chk_dma = 0, chk_player = 0, rand_ready = 0;
    int dma_err = 0, dma_beats = 0;
    always @(posedge adc_clk) begin
        if (log_dac && dut.src_d && dac_tvalid && dac_tready && dac_tdata != '0)
            $fwrite(fd, "D %0d %h\n", adc_time, dac_tdata);     // %h: full width, zero-padded
        for (int w = 0; w < SLOTS; w += 4)
            dma_tdata[32*w +: 128] <= {$urandom, $urandom, $urandom, $urandom};
        dma_tvalid <= ($urandom % 4) != 0;
        dac_tready <= rand_ready ? (($urandom % 4) != 0) : 1'b1;
    end
    // the URAM buffer must never be written while full (credit exactness)
    int buf_ovf = 0;
    always @(posedge tx_clk) if (tx_rstn && dut.bw_en && dut.u_buf.full) buf_ovf++;
    always @(negedge adc_clk) begin
        if (chk_dma) begin
            dma_beats++;
            if (dac_tdata !== dma_tdata || dac_tvalid !== dma_tvalid || dma_tready !== dac_tready)
                dma_err++;
        end
        if (chk_player && (dma_tready !== 1'b1 || dac_tvalid !== 1'b1)) dma_err++;
    end

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    task wait_ev(input int code, input int n, input int timeout_us = 200);
        int t0;
        begin
            t0 = $time;
            while (n_ev[code] < n) begin
                @(posedge tx_clk);
                if ($time - t0 > timeout_us * 1000) begin
                    $display("ERROR timeout waiting for event 0x%0h #%0d", code, n);
                    errors++;
                    return;
                end
            end
        end
    endtask
    task quiesce(input string what);
        reg [31:0] d;
        begin
            repeat (3000) @(posedge adc_clk);
            axi_rd(8'h64, d);
            if (d !== host_sent) begin
                $display("ERROR %s: CONSUMED=%0d, host sent %0d", what, d, host_sent);
                errors++;
            end
            $fwrite(fd, "# quiesce %s consumed %0d\n", what, host_sent);
        end
    endtask
    task log_burst(input int B, input int sizes[], input bit timed, input [63:0] tsf,
                   input bit late, input bit und);
        int n;
        begin
            n = 0;
            foreach (sizes[k]) n += sizes[k];
            $fwrite(fd, "# burst %0d n %0d timed %0d tsf %0d late %0d und %0d now %0d\n",
                    B, n, timed, tsf, late, und, adc_time);
        end
    endtask

    initial begin
        #3ms;
        $display("ERROR global timeout");
        $fatal(1, "timeout");
    end

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    reg [31:0] rd;
    reg [63:0] t0;
    int sz[];
    int room, c0, wbig, fsz;
    int npark;
    int n_mal = 2;
    initial begin
        fd = $fopen("player.log", "w");
        $fwrite(fd, "# tick_step %0d\n", TICK_STEP);
        $fwrite(fd, "# width %0d\n", M_WIDTH);
        $fwrite(fd, "# fmt %0d streamer_fmt %0d\n", FMT, SFMT);
        repeat (20) @(posedge axi_clk);
        adc_rstn = 1; axi_rstn = 1;          // tx_clk not running, tx_aresetn low
        repeat (50) @(posedge axi_clk);

        // ---- register defaults
        expect_rd(8'h00, 32'h5A503031, "ID");
        expect_rd(8'h08, 32'h43323136, "MY_MAC_LO default");
        expect_rd(8'h0C, 32'h0000025A, "MY_MAC_HI default");
        expect_rd(8'h10, 32'hC0A80502, "MY_IP default");
        expect_rd(8'h14, 49900, "TX_PORT default");
        expect_rd(8'h24, 49826, "ASYNC_PORT default");
        expect_rd(8'h28, 49801, "SRC_PORT default");
        expect_rd(8'h2C, TXBW / 8, "FC_INTERVAL default");
        expect_rd(8'h30, CREDIT, "TX_BUF_WORDS");
        expect_rd(8'h34, 32'h5A170000, "SID default");

        axi_wr(8'h08, MY_MAC[31:0]); axi_wr(8'h0C, MY_MAC[47:32]);
        axi_wr(8'h10, MY_IP);
        axi_wr(8'h18, HOST_MAC[31:0]); axi_wr(8'h1C, HOST_MAC[47:32]);
        axi_wr(8'h20, HOST_IP);
        axi_wr(8'h2C, FCI);
        axi_wr(8'h34, SID);
        if (FMT != 0) begin
            axi_wr(8'h74, FMT);
            expect_rd(8'h74, FMT, "FMT readback");
        end
        $fwrite(fd, "# cfg credit %0d fci %0d\n", CREDIT, FCI);

        // ---- DMA pass-through (dac_src = 0), DAC tready toggling, while the
        // CMAC user clock is still stopped: must not depend on tx_clk at all.
        axi_wr(8'h04, 32'h1);
        repeat (50) @(posedge adc_clk);
        rand_ready = 1; chk_dma = 1;
        repeat (500) @(posedge adc_clk);
        chk_dma = 0; rand_ready = 0;
        repeat (4) @(posedge adc_clk);
        $display("DMA pass-through (tx_clk stopped): %0d beats, %0d mismatches", dma_beats, dma_err);
        axi_wr(8'h04, 32'h3);                // player selected, still no tx_clk: zeros
        repeat (50) @(posedge adc_clk);
        chk_player = 1; log_dac = 1;
        repeat (300) @(posedge adc_clk);
        chk_player = 0;
        axi_wr(8'h04, 32'h1);
        // ---- now the CMAC comes up: clock first, reset released later
        tx_run = 1;
        repeat (200) @(posedge tx_clk);
        tx_rstn = 1;
        repeat (200) @(posedge tx_clk);
        $fwrite(fd, "# tx_clk started\n");

`ifdef INTEG
        // ---- streamer: continuous test pattern, 64-sample packets
        axsel = 1;
        axi_wr(8'h30, 32'hddeeff01); axi_wr(8'h34, 32'h0000aabb);
        axi_wr(8'h38, 32'h5c6d7e8f); axi_wr(8'h3C, 32'h00001a2b);
        axi_wr(8'h40, 32'hC0A80502); axi_wr(8'h44, 32'hC0A80501);
        axi_wr(8'h48, 49800); axi_wr(8'h4C, 49810); axi_wr(8'h50, 3);
        if (SFMT != 0) axi_wr(8'h78, SFMT);
        axi_wr(8'h54, 64); axi_wr(8'h58, 32'h5A160000);
        axi_wr(8'h04, 32'h3);
        axi_wr(8'h08, 32'h101);
        axsel = 0;
        axi_wr(8'h04, 32'h3 | 32'h8);
        repeat (400) @(posedge adc_clk);
        $fwrite(fd, "# phase integ\n");
        for (int k = 0; k < 3; k++) begin
            arp_req(48'hFFFFFFFFFFFF, HOST_MAC, HOST_IP, MY_IP, 0);
            repeat (300) @(posedge tx_clk);
        end
        sz = '{256, 512, 256, 1024};
        send_burst(1, sz, 0, 0);
        wait_ev(1, 1);
        arp_req(MY_MAC, HOST_MAC, HOST_IP, MY_IP, 0);
        repeat (3000) @(posedge adc_clk);
        axsel = 1; axi_wr(8'h08, 32'h100); axsel = 0;     // stop the streamer
        repeat (3000) @(posedge adc_clk);
        $fwrite(fd, "# integ arp %0d status %0d streamer %0d bubbles %0d\n",
                n_arp_rx, n_status, n_str, bubbles);
        $display("INTEG: ARP=%0d STATUS=%0d STREAMER_FRAMES=%0d BUBBLES=%0d",
                 n_arp_rx, n_status, n_str, bubbles);
        if (bubbles != 0) begin $display("ERROR bubbles inside frames"); errors++; end
        if (n_arp_rx != 4 || n_ev[1] != 1 || n_str < 100) begin
            $display("ERROR integ counts"); errors++;
        end
`else
        // ---- player on (stream_setup_tx: enable, dac_src, flush)
        axi_wr(8'h04, 32'h3 | 32'h8);
        expect_rd(8'h04, 32'h3, "CTRL readback");
        repeat (400) @(posedge adc_clk);
        chk_player = 1; log_dac = 1;

        // ---- ARP
        $fwrite(fd, "# phase arp\n");
        arp_req(48'hFFFFFFFFFFFF, HOST_MAC, HOST_IP, MY_IP, 0);               // reply
        arp_req(48'hFFFFFFFFFFFF, HOST_MAC, HOST_IP, 32'hC0A80509, 0);        // not ours
        arp_req(48'hFFFFFFFFFFFF, HOST_MAC, HOST_IP, MY_IP, 1);               // bad FCS
        arp_req(48'h02_00_00_00_00_99, HOST_MAC, HOST_IP, MY_IP, 0);          // other MAC
        repeat (300) @(posedge tx_clk);
        arp_req(MY_MAC, 48'h0a_0b_0c_0d_0e_0f, 32'hC0A80577, MY_IP, 0);       // unicast, reply
        repeat (500) @(posedge tx_clk);
        $fwrite(fd, "# arp_expect %012x %08x\n", HOST_MAC, HOST_IP);
        $fwrite(fd, "# arp_expect %012x %08x\n", 48'h0a_0b_0c_0d_0e_0f, 32'hC0A80577);

        // ---- 1: timed burst, larger than the credit (flow control while playing).
        // Every packet carries the timed bit; only the first may be honoured.
        $fwrite(fd, "# phase timed\n");
        case (FMT)
            0: sz = '{2048, 1024, 512, 2048, 256, 2048};
            1: sz = '{4096, 1024, 512, 2048, 256, 4096};
            2: sz = '{2688, 1024, 512, 2048, 256, 2688};
            default: sz = '{1024, 1016, 520, 1024, 8, 1000};   // odd-word packets
        endcase
        t0 = adc_time + 64'd3002 * TICK_STEP * K;
        log_burst(1, sz, 1, t0, 0, 0);
        send_burst(1, sz, 1, t0);
        wait_ev(1, 1);
        quiesce("timed");

        // ---- 2: untimed burst
        $fwrite(fd, "# phase untimed\n");
        if (FMT == 3) sz = '{512, 512, 504};     // ends on half a group: padded
        else          sz = '{512, 512, 512};
        t0 = MAXR ? adc_time + 64'd3002 * TICK_STEP * K : 0;   // MAXR: see burst 6
        log_burst(2, sz, MAXR, t0, 0, 0);
        send_burst(2, sz, MAXR, t0);
        wait_ev(1, 2);
        quiesce("untimed");

        // ---- 3: late burst -> TIME_ERROR, plays at once
        $fwrite(fd, "# phase late\n");
        sz = '{256, 256};
        t0 = adc_time - 64'd401 * TICK_STEP * K;
        log_burst(3, sz, 1, t0, 1, 0);
        send_burst(3, sz, 1, t0);
        wait_ev(1, 3);
        quiesce("late");

        // ---- 4: starvation mid-burst -> UNDERFLOW once, zeros, resume, ACK
        $fwrite(fd, "# phase starve\n");
        sz = '{256, 256, 256, 256};
        t0 = adc_time + 64'd2000 * TICK_STEP * K;
        log_burst(4, sz, 1, t0, 0, 1);
        send_pkt(4, 0,   256, 1, 0, 1, t0);
        send_pkt(4, 256, 256, 0, 0, 1, t0 + 256 * TICK_STEP);
        wait_ev(2, 1);
        repeat (200) @(posedge adc_clk);
        send_pkt(4, 512, 256, 0, 0, 1, t0 + 512 * TICK_STEP);
        send_pkt(4, 768, 256, 0, 1, 1, t0 + 768 * TICK_STEP);
        wait_ev(1, 4);
        quiesce("starve");

        // ---- 5: packet-count gap -> SEQ_ERROR, burst still plays
        $fwrite(fd, "# phase seq\n");
        sz = '{256, 256, 256};
        t0 = MAXR ? adc_time + 64'd3002 * TICK_STEP * K : 0;   // MAXR: see burst 6
        log_burst(5, sz, MAXR, t0, 0, 0);
        send_burst(5, sz, MAXR, t0, 1);
        wait_ev(1, 5);
        wait_ev(4, 1);
        quiesce("seq");

        // ---- 6: bad FCS inside a burst: discarded (but consumed), the
        // retransmission with the same packet count is no sequence error.
        $fwrite(fd, "# phase badfcs\n");
        // An untimed burst plays from its first packet on, so that packet must
        // outlast the bad one plus its retransmission, and the bad packet's
        // credit only returns once the mover reaches it: at fc32 (twice the
        // sc16 bytes) the later packets are 256 slots.
        // With FAST (a group per cycle) no link can deliver a packet and its
        // retransmission while one small packet plays: there bursts 6 and 8
        // are timed, so they start from a pre-filled buffer.
        c0 = (FMT == 3) ? 256 : 512;
        sz = '{512, c0, c0};
        t0 = MAXR ? adc_time + 64'd3002 * TICK_STEP * K : 0;
        log_burst(6, sz, MAXR, t0, 0, 0);
        send_pkt(6, 0, 512, 1, 0, MAXR, t0);
        send_pkt(99, 512, c0, 0, 0, MAXR, t0 + 512 * TICK_STEP, 1);   // bad FCS: counts=1 advances pcnt and sent
        host_pcnt--;                                 // the retransmission reuses the count
        send_pkt(6, 512, c0, 0, 0, MAXR, t0 + 512 * TICK_STEP);
        send_pkt(6, 512 + c0, c0, 0, 1, MAXR, t0 + (512 + c0) * TICK_STEP);
        wait_ev(1, 6);
        quiesce("badfcs");

        // ---- malformed / not for us: nothing plays, no seq tracking
        $fwrite(fd, "# phase malformed\n");
        // 24 payload words (not whole 64-byte words)
        send_pkt(98, 0, GS, 1, 1, 0, 0, 0, 1, 24 - GS * BPS / 4, 0, TX_PORT, MY_MAC, MY_IP, 0);
        send_pkt(98, 0, 64, 1, 1, 0, 0, 0, 1, 0, 4, TX_PORT, MY_MAC, MY_IP, 0);       // UDP length off
        host_sent += 1 + BPS;     // rejected for us: credited as floor((vlen-4)/16) = 1 and 64 slots
        if (FMT == 2) begin       // sc12: one word is not a whole 3-word unit
            send_pkt(98, 0, GS, 1, 1, 0, 0, 0, 1, 16 - GS * BPS / 4, 0, TX_PORT, MY_MAC, MY_IP, 0);
            host_sent += 1;
            n_mal++;
        end
        send_pkt(98, 0, 64, 1, 1, 0, 0, 0, 1, 0, 0, 16'd49901, MY_MAC, MY_IP, 0);     // other port
        send_pkt(98, 0, 64, 1, 1, 0, 0, 0, 1, 0, 0, TX_PORT, 48'h020000000099, MY_IP, 0); // other MAC
        send_pkt(98, 0, 64, 1, 1, 0, 0, 0, 1, 0, 0, TX_PORT, MY_MAC, 32'hC0A80509, 0); // other IP
        repeat (2000) @(posedge tx_clk);
        expect_rd(8'h6C, n_mal, "udp_malformed");

        // ---- 7: overflow. A far-future timed burst parks the data; fill the
        // credit exactly (no drop), then one packet more (dropped whole).
        $fwrite(fd, "# phase overflow\n");
        t0 = adc_time + 64'd50000000 * TICK_STEP * K;
        $fwrite(fd, "# burst 7 flushed\n");
        // park enough to fill the crossing FIFO and the deep play-out chain
        // behind the URAM (sc8/sc12 cross as wire words, fewer per slot), so
        // consumed stops moving: their words plus half the credit, which
        // then waits in the URAM (twice their words overflowed the 240-word
        // credit at 3 x 128); at least 4 / 8 packets
        npark = ((((FMT == 0) ? 32 : 64) + CHAIN * CHAIN_D + CREDIT / 2) + 256 * BPS / 64 - 1) / (256 * BPS / 64);
        if (npark < ((FMT == 0) ? 4 : 8)) npark = (FMT == 0) ? 4 : 8;
        send_pkt(7, 0,  256, 1, 0, 1, t0, 0, 0);
        for (int k = 1; k < npark; k++) send_pkt(7, 256 * k, 256, 0, 0, 1, t0, 0, 0);
        repeat (2000) @(posedge tx_clk);
        axi_rd(8'h64, rd); c0 = rd;
        room = CREDIT - (host_sent - c0);
        $display("overflow: consumed %0d, sent %0d, room %0d words", c0, host_sent, room);
        fsz = (TXBW > 256) ? MAXS : 256;             // fill packet, slots
        wbig = fsz * BPS / 64;                       // ... and words
        for (int k = 0; room >= wbig; k++) begin
            send_pkt(7, 1024 + fsz * k, fsz, 0, 0, 1, t0, 0, 0);
            room -= wbig;
        end
        // the rest in one packet of whole units (exact for every format but sc12)
        if (room >= GW) send_pkt(7, 5000, (room / GW) * GS, 0, 0, 1, t0, 0, 0);
        while (fq.size() != 0 || cur_b >= 0) @(posedge tx_clk);          // a large TXBW takes a while to send
        repeat (2000) @(posedge tx_clk);
        expect_rd(8'h50, 0, "overflow before full");
        expect_rd(8'h64, c0, "consumed while parked");
        send_pkt(7, 6000, GS, 0, 0, 1, t0, 0, 0, 0, 0, TX_PORT, MY_MAC, MY_IP, 0);
        host_pcnt++;                                 // sent, will be dropped...
        host_sent += GW;                             // ...and credited back at once
        while (fq.size() != 0 || cur_b >= 0) @(posedge tx_clk);
        repeat (2000) @(posedge tx_clk);
        expect_rd(8'h50, 1, "overflow after full");
        expect_rd(8'h68, 32'h1, "status: playing (waiting), not empty");
        // stream_stop_tx / stream_setup_tx: flush
        $fwrite(fd, "# flush\n");
        axi_wr(8'h04, 32'h3 | 32'h8);
        repeat (1000) @(posedge adc_clk);
        expect_rd(8'h64, host_sent, "consumed after flush (monotonic: all sent words)");
        expect_rd(8'h68, 32'h2, "status after flush: idle, empty");

        // ---- 8: normal burst after the flush
        $fwrite(fd, "# phase postflush\n");
        if (FMT == 3) sz = '{1024, 512};         // same reason as burst 6
        else          sz = '{512, 1024};
        t0 = MAXR ? adc_time + 64'd3002 * TICK_STEP * K : 0;
        log_burst(8, sz, MAXR, t0, 0, 0);
        send_burst(8, sz, MAXR, t0);
        wait_ev(1, 7);
        quiesce("postflush");

        // ---- 9-11: untimed-start gate (USTART / UTIMEOUT, off until now)
        // c0 slots per packet: 3 packets fit the 240-word credit in every
        // format (sc12: 48-word packets, whole 3-word units)
        c0 = (FMT == 3) ? 512 : 1024;
        // 9: released by the EOB packet. Pauses between the packets are far
        // longer than a packet plays: without the gate this underflows;
        // held whole, it plays back to back.
        $fwrite(fd, "# phase gate_eob\n");
        axi_wr(8'h78, 32'hFFFFFF);
        axi_wr(8'h7C, 32'd0);
        expect_rd(8'h78, 32'hFFFFFF, "USTART readback");
        sz = '{c0, c0, 512};
        log_burst(9, sz, 0, 0, 0, 0);
        send_pkt(9, 0, c0, 1, 0, 0, 0);
        repeat (3000) @(posedge tx_clk);
        expect_rd(8'h68, 32'h0, "gate: the first packet is held (not playing, not empty)");
        send_pkt(9, c0, c0, 0, 0, 0, 0);
        repeat (3000) @(posedge tx_clk);
        expect_rd(8'h68, 32'h0, "gate: two packets held");
        send_pkt(9, 2 * c0, 512, 0, 1, 0, 0);
        wait_ev(1, 8);
        quiesce("gate_eob");

        // 10: released by the threshold, before the EOB packet is sent
        $fwrite(fd, "# phase gate_threshold\n");
        axi_wr(8'h78, 3 * c0 * BPS / 64);
        sz = '{c0, c0, c0, 512};
        log_burst(10, sz, 0, 0, 0, 0);
        send_pkt(10, 0, c0, 1, 0, 0, 0);
        send_pkt(10, c0, c0, 0, 0, 0, 0);
        while (fq.size() != 0 || cur_b >= 0) @(posedge tx_clk);
        repeat (300) @(posedge tx_clk);
        expect_rd(8'h68, 32'h0, "gate: below the threshold, held");
        send_pkt(10, 2 * c0, c0, 0, 0, 0, 0);
        while (fq.size() != 0 || cur_b >= 0) @(posedge tx_clk);
        // released by the threshold: playing before the EOB packet is sent
        // (the playing bit crosses from adc_clk, slow at the wide beats)
        rd = 0;
        for (int k = 0; k < 400 && rd[0] !== 1'b1; k++) begin
            repeat (10) @(posedge tx_clk);
            axi_rd(8'h68, rd);
        end
        if (rd[0] !== 1'b1) begin
            $display("ERROR gate: threshold reached, not playing (status %0h)", rd);
            errors++;
        end
        send_pkt(10, 3 * c0, 512, 0, 1, 0, 0);
        wait_ev(1, 9);
        quiesce("gate_threshold");

        // 11: released by the timeout: one packet and no EOB plays after
        // UTIMEOUT cycles, then underflows (the EOB packet comes later)
        $fwrite(fd, "# phase gate_timeout\n");
        axi_wr(8'h78, 32'hFFFFFF);
        axi_wr(8'h7C, 32'd2000);
        sz = '{512, 512};
        log_burst(11, sz, 0, 0, 0, 1);
        send_pkt(11, 0, 512, 1, 0, 0, 0);
        repeat (1000) @(posedge tx_clk);
        expect_rd(8'h68, 32'h0, "gate: held before its timeout");
        wait_ev(2, 2);
        repeat (200) @(posedge adc_clk);
        send_pkt(11, 512, 512, 0, 1, 0, 0);
        wait_ev(1, 10);
        quiesce("gate_timeout");
        expect_rd(8'h80, 3, "UGATED");
        expect_rd(8'h84, 1, "UTIMEOUTS");
        axi_wr(8'h78, 32'd0);                        // gate off again

        // ---- final stats
        expect_rd(8'h40, frames_sent, "rx_frames");
        expect_rd(8'h44, 2, "rx_bad_fcs");
        expect_rd(8'h48, 2, "arp_replies");
        expect_rd(8'h4C, n_acc, "udp_accepted");
        expect_rd(8'h50, 1, "udp_dropped_overflow");
        expect_rd(8'h54, 1, "seq_errors");
        expect_rd(8'h58, 2, "underflows");
        expect_rd(8'h5C, 1, "late");
        expect_rd(8'h60, 10, "bursts_acked");
        expect_rd(8'h64, host_sent, "consumed_words");
        expect_rd(8'h68, 32'h2, "status idle+empty");
        expect_rd(8'h6C, n_mal, "udp_malformed");
        expect_rd(8'h70, n_status, "status_pkts");
        $fwrite(fd, "# events ack %0d und %0d seq %0d late %0d fc %0d\n",
                n_ev[1], n_ev[2], n_ev[4], n_ev[8], n_ev[0]);
        axi_wr(8'h04, 32'h3 | 32'h4);                // clear stats
        repeat (20) @(posedge axi_clk);
        expect_rd(8'h40, 0, "rx_frames after clear");
        expect_rd(8'h60, 0, "bursts_acked after clear");
        expect_rd(8'h80, 0, "UGATED after clear");
        expect_rd(8'h04, 32'h3, "CTRL after clear");
        if (dma_err != 0) begin $display("ERROR DMA/player DAC mux: %0d", dma_err); errors++; end
        if (bubbles != 0) begin $display("ERROR ctl frame bubbles: %0d", bubbles); errors++; end
        if (buf_ovf != 0) begin $display("ERROR URAM buffer written while full: %0d", buf_ovf); errors++; end
        $display("FRAMES_SENT=%0d ACCEPTED=%0d STATUS=%0d ARP=%0d EV ack=%0d und=%0d seq=%0d late=%0d fc=%0d",
                 frames_sent, n_acc, n_status, n_arp_rx, n_ev[1], n_ev[2], n_ev[4], n_ev[8], n_ev[0]);
`endif
        $fwrite(fd, "# end errors %0d\n", errors);
        $fclose(fd);
        $display("TB_ERRORS=%0d", errors);
        $finish;
    end
endmodule
