// tb_udp_streamer -- drives udp_streamer and dumps every emitted frame.
// Frames are checked by check_frames.py (Ethernet/IPv4/UDP/VRT, checksums,
// timestamps, payload), so the RTL is held to the Protocol (top AGENTS.md).
//
// ADC data model (pattern off): the slot with timestamp t is
//   I = t*3 (16 bit), Q = t ^ 16'h5A5A.
// A beat is S_WIDTH/32 slots; slot k of a beat has timestamp
// t_model + k*TICK_STEP (ticks); the checker recomputes it from each packet's
// TSF (check_frames.py --tick-step --width).
//
// S_WIDTH (xelab -generic_top, 128/256/512): the ADC clock follows the
// Protocol §9 table (300 / 150 / 60 MHz) and time offsets in the sequence
// scale with the beat so the scenarios keep their length in adc_clk cycles.
//
// FMT (xelab -generic_top, 0 sc16 / 1 sc8 / 2 sc12 / 3 fc32): the FMT register
// (0x78). With FMT != 0 the ADC model replaces the slots whose index
// n = t / TICK_STEP has n % 64 < 16 by a table of rounding / saturation corner
// values (CORNER_I/Q, mirrored in check_frames.py); FMT = 0 keeps the original
// stimulus. The one-word case (spp16) uses the format's minimum SPP. After the
// last frame the SPP coercion of the register file is checked for FMT.
`timescale 1ns / 1ps

// FAST = 1 (xelab -generic_top): adc_clk at 300 MHz whatever S_WIDTH -- at
// 512 bits that is the "max rate" geometry, one 16-slot group per cycle --
// and SPP is the format's maximum (as the daemon sets it), so the framer's
// per-packet overhead does not limit the rate.
// S_WIDTH 1024 (the sc8-only wide beat no build uses) always runs its own max-rate
// geometry: adc_clk 187.5 MHz, a 32-slot beat -> one sc8 wire word per cycle
// (96 Gb/s), SPP the format's maximum; any other FMT must drop everything.
module tb_udp_streamer #(parameter int TICK_STEP = 1, parameter int S_WIDTH = 128,
                         parameter int FMT = 0, parameter int FAST = 0);
    localparam int GRAN = (FMT == 1) ? 32 : (FMT == 2) ? 64 : (FMT == 3) ? 8 : 16;
    localparam int WIDE = (S_WIDTH == 1024);
    localparam int MAXR = FAST || WIDE;             // max-rate SPP
    localparam int SPP  = !MAXR ? 64 :
                          (FMT == 1) ? 4096 : (FMT == 2) ? 2688 : (FMT == 3) ? 1024 : 2048;
    localparam bit [15:0] CORNER_I [16] = '{16'sd32767, -16'sd32768, 16'sd32640, 16'sd32639,
        16'sd128, -16'sd128, 16'sd384, -16'sd384, 16'sd8, -16'sd8, 16'sd24, -16'sd24,
        16'sd32760, 16'sd32759, 16'sd0, -16'sd1};
    localparam bit [15:0] CORNER_Q [16] = '{-16'sd32768, 16'sd32767, -16'sd32640, 16'sd32631,
        16'sd136, -16'sd136, 16'sd383, -16'sd385, 16'sd7, -16'sd9, 16'sd40, -16'sd40,
        -16'sd32760, 16'sd32752, 16'sd1, 16'sd255};
    localparam int  SLOTS = S_WIDTH / 32;
    localparam int  K     = S_WIDTH / 128;          // time-offset scale
    localparam real ADC_HALF = WIDE ? 2.6667 : FAST ? 1.6667 :
                               (S_WIDTH == 512) ? 8.3333 : (S_WIDTH == 256) ? 3.3333 : 1.6667;
    reg adc_clk = 0, tx_clk = 0, axi_clk = 0;
    always #ADC_HALF adc_clk = ~adc_clk;   // 300 / 150 / 60 MHz
    always #1.5515 tx_clk  = ~tx_clk;    // 322.27 MHz
    always #5.0    axi_clk = ~axi_clk;   // 100 MHz
    reg adc_rstn = 0, tx_rstn = 0, axi_rstn = 0;

    // ---- ADC stream: continuous, with an occasional gap to exercise tvalid
    reg  [63:0]  t_model = 0;
    reg  [S_WIDTH-1:0] adc_data;
    reg          adc_valid = 0;
    integer k;
    always @(*) for (k = 0; k < SLOTS; k = k + 1) begin
        longint unsigned n;
        n = (t_model + k * TICK_STEP) / TICK_STEP;
        if (FMT != 0 && (n % 64) < 16) begin
            adc_data[32*k +: 16]      = CORNER_I[n % 16];
            adc_data[32*k + 16 +: 16] = CORNER_Q[n % 16];
        end else begin
            adc_data[32*k +: 16]      = (t_model + k * TICK_STEP) * 3;
            adc_data[32*k + 16 +: 16] = (t_model[15:0] + k * TICK_STEP) ^ 16'h5A5A;
        end
    end
    integer cyc = 0;
    always @(posedge adc_clk) begin
        cyc <= cyc + 1;
        if (!adc_rstn) begin adc_valid <= 0; t_model <= 0; end
        else begin
            if (adc_valid) t_model <= t_model + SLOTS * TICK_STEP;
            adc_valid <= (cyc % 97) != 0;
        end
    end

    // ---- DUT
    wire [511:0] m_tdata; wire [63:0] m_tkeep; wire m_tvalid, m_tlast, m_tuser;
    reg          m_tready = 1;
    reg  [15:0] awaddr, araddr; reg awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata;
    wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata; wire [1:0] bresp, rresp;

    udp_streamer #(.DATA_FIFO_DEPTH(512), .TICK_STEP(TICK_STEP), .S_WIDTH(S_WIDTH)) dut (
        .adc_clk(adc_clk), .adc_aresetn(adc_rstn),
        .s_axis_tdata(adc_data), .s_axis_tvalid(adc_valid), .s_axis_tready(), .adc_time(),
        .m_axis_adc_tdata(), .m_axis_adc_tvalid(), .m_axis_adc_tready(1'b1),
        .tx_clk(tx_clk), .tx_aresetn(tx_rstn),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser), .m_axis_tready(m_tready),
        .cmac_rx_aligned(1'b1), .cmac_tx_ready(1'b1),
        .s_axi_aclk(axi_clk), .s_axi_aresetn(axi_rstn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    task axi_wr(input [15:0] a, input [31:0] d);
        begin
            @(posedge axi_clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
            fork
                begin wait (awready); @(posedge axi_clk); awvalid <= 0; end
                begin wait (wready);  @(posedge axi_clk); wvalid  <= 0; end
            join
            wait (bvalid); @(posedge axi_clk);
        end
    endtask
    task axi_rd(input [15:0] a, output [31:0] d);
        begin
            @(posedge axi_clk); araddr <= a; arvalid <= 1;
            wait (arready); @(posedge axi_clk); arvalid <= 0;
            wait (rvalid); d = rdata; @(posedge axi_clk);
        end
    endtask

    // ---- Frame capture: one hex line per frame, byte 0 first
    integer fd;
    reg [8*9000-1:0] fbuf; integer flen = 0; integer nframes = 0; integer bubbles = 0;
    reg in_frame = 0;
    integer b;
    always @(posedge tx_clk) begin
        if (in_frame && !m_tvalid) bubbles = bubbles + 1;   // CMAC forbids these
        if (m_tvalid && m_tready) begin
            in_frame = !m_tlast;
            for (b = 0; b < 64; b = b + 1)
                if (m_tkeep[b]) begin
                    $fwrite(fd, "%02x", m_tdata[8*b +: 8]);
                    flen = flen + 1;
                end
            if (m_tlast) begin
                $fwrite(fd, "\n"); nframes = nframes + 1; flen = 0;
            end
        end
    end

    // A FIFO written while full would put data and descriptors out of step.
    integer full_wr = 0;
    always @(posedge adc_clk)
        if ((dut.dfifo_wr && dut.dfifo_full) || (dut.qfifo_wr && dut.qfifo_full)) full_wr = full_wr + 1;

    // Expected SPP read-back (see the udp_streamer header).
    function automatic int unsigned spp_want(input int unsigned w);
        case (FMT)
            0: return (w[11:4] == 0) ? 16 : (w > 2048) ? 2048 : (w & 32'hFF0);
            1: return (w < 32) ? 32 : (w > 4096) ? 4096 : (w & ~32'd31);
            2: return (w < 64) ? 64 : (w > 2688) ? 2688 : (w & ~32'd63);
            default: return (w < 8) ? 8 : (w > 1024) ? 1024 : (w & ~32'd7);
        endcase
    endfunction
    int unsigned spp_in[] = '{0, 7, 8, 9, 31, 33, 100, 1000, 2047, 2048, 2689, 3000, 4095,
                              4096, 4097, 32'hFFFF_FFFF};

    reg [31:0] rd, rd2;
    initial begin
        fd = $fopen("frames.hex", "w");
        $fwrite(fd, "# tick_step %0d\n", TICK_STEP);
        $fwrite(fd, "# width %0d\n", S_WIDTH);
        $fwrite(fd, "# fmt %0d\n", FMT);
        if (MAXR) $fwrite(fd, "# fast spp %0d\n", SPP);
        repeat (20) @(posedge axi_clk);
        adc_rstn = 1; tx_rstn = 1; axi_rstn = 1;
        repeat (50) @(posedge axi_clk);
        axi_rd(8'h00, rd); $display("ID=%h", rd);
        if (rd !== 32'h5A533031) $fatal(1, "bad ID");

        axi_wr(8'h30, 32'hddeeff01); axi_wr(8'h34, 32'h0000aabb);   // src aa:bb:dd:ee:ff:01
        axi_wr(8'h38, 32'h5c6d7e8f); axi_wr(8'h3C, 32'h00001a2b);   // dst 1a:2b:5c:6d:7e:8f
        axi_wr(8'h40, 32'hC0A80502); axi_wr(8'h44, 32'hC0A80501);
        axi_wr(8'h48, 49800); axi_wr(8'h4C, 49810); axi_wr(8'h50, 3);
        if (FMT != 0) axi_wr(8'h78, FMT);
        axi_wr(8'h54, SPP);   axi_wr(8'h58, 32'h5A160000);

        // 1) continuous, ADC data, 3 ports
        $fwrite(fd, "# case cont\n");
        axi_wr(8'h04, 32'h1);
        axi_wr(8'h08, 32'h101);                 // continuous, now
        repeat (3000) @(posedge adc_clk);
        axi_wr(8'h08, 32'h100);                 // stop
        repeat (2000) @(posedge adc_clk);

        // 2) timed num_done burst with pattern: 1000 samples at t0 + 5000 + 2
        $fwrite(fd, "# case burst\n");
        axi_wr(8'h04, 32'h3);
        axi_rd(8'h1C, rd); axi_rd(8'h20, rd2);
        $fwrite(fd, "# t_req %0d n_req 1000\n", rd + 32'd5002 * K);
        axi_wr(8'h0C, 1000); axi_wr(8'h10, 0);
        axi_wr(8'h14, rd + 32'd5002 * K); axi_wr(8'h18, 0);
        axi_wr(8'h08, 32'h002);                 // num_done, timed
        repeat (4000) @(posedge adc_clk);

        // 3) overflow: stall the CMAC, stream continuous, expect drops
        $fwrite(fd, "# case overflow\n");
        axi_wr(8'h04, 32'h1 | 32'h4);           // enable + clear stats
        m_tready = 0;
        axi_wr(8'h08, 32'h101);
        repeat (6000) @(posedge adc_clk);
        m_tready = 1;
        repeat (3000) @(posedge adc_clk);
        axi_wr(8'h08, 32'h100);
        repeat (3000) @(posedge adc_clk);
        axi_rd(8'h68, rd); $display("OVERFLOWS=%0d", rd);
        $fwrite(fd, "# overflows %0d\n", rd);
        axi_rd(8'h60, rd); $display("PKTS=%0d", rd);
        axi_rd(8'h74, rd); $display("CMDS=%0d", rd);
        axi_rd(8'h6C, rd); $display("STATUS=%h", rd);
        axi_rd(8'h70, rd); $display("FIFO_HWM=%0d", rd);

        // 4) one-word packets (SPP 16), ADC data, with a CMAC stall: at
        // S_WIDTH 512 every beat is a whole packet (start and end at once)
        $fwrite(fd, "# case spp16\n");
        axi_wr(8'h54, GRAN);
        axi_wr(8'h04, 32'h1 | 32'h4);           // enable + clear stats
        axi_wr(8'h08, 32'h101);
        repeat (1000) @(posedge adc_clk);
        m_tready = 0;
        repeat (1500) @(posedge adc_clk);
        m_tready = 1;
        repeat (1500) @(posedge adc_clk);
        axi_wr(8'h08, 32'h100);
        repeat (2000) @(posedge adc_clk);
        axi_rd(8'h68, rd); $display("SPP16_OVERFLOWS=%0d", rd);
        $fwrite(fd, "# overflows16 %0d\n", rd);
        $display("FRAMES=%0d BUBBLES=%0d FULL_WRITES=%0d", nframes, bubbles, full_wr);
        $fclose(fd);
        if (bubbles != 0) $fatal(1, "TX bubbles inside a frame");
        if (full_wr != 0) $fatal(1, "FIFO written while full");

        // SPP coercion for this FMT (and FMT read-back), after the traffic
        axi_rd(8'h78, rd);
        if (rd !== FMT) $fatal(1, "FMT read back %0d, want %0d", rd, FMT);
        foreach (spp_in[i]) begin
            axi_wr(8'h54, spp_in[i]);
            repeat (4) @(posedge axi_clk);
            axi_rd(8'h54, rd);
            if (rd !== spp_want(spp_in[i])) $fatal(1, "SPP %0d coerced to %0d, want %0d",
                                                   spp_in[i], rd, spp_want(spp_in[i]));
        end
        $display("SPP_COERCION ok (FMT %0d)", FMT);
        $finish;
    end
endmodule
