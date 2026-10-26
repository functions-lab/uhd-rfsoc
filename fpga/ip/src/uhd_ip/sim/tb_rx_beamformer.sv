// tb_rx_beamformer -- stimulus + register checks for src/rx_beamformer.v.
//
// Parameters (xelab -generic_top): N_CH, BEAT_W, ACLK_PS (converter clock
// period), WFILE / SFILE (weight sets and their SHIFTs from `check_rbf.py gen`,
// NSETS x N_CH words and NSETS shifts).
//
// The tb checks the register file itself (ID, NCH, CTRL, W defaults and
// readback, SHIFT reset log2(N) and readback, LOAD reads 0, rvalid only
// after an AR handshake) and the AXIS
// contract (tvalid/tdata stable while stalled, tready path), and logs:
//   I <n> <hex>                   input beat n accepted
//   O <n> <hex>                   output beat n accepted
//   E <n_issue> <n_done> EN <v>   CTRL.enable written (beat counts at the
//                                 start and end of the AXI write)
//   E <n_issue> <n_done> LOAD <shift> <w0> .. <wN-1>   LOAD written, SHIFT
//                                 and W[] at that time
//   E <n_issue> <n_done> SRST     s_axi reset (defaults, enable 0, LOAD)
//   E <n_issue> <n_done> ARST     aclk reset (weights must survive)
// check_rbf.py replays the log against the exact beam arithmetic.
`timescale 1ns / 1ps

module tb_rx_beamformer;
    parameter integer N_CH    = 4;
    parameter integer BEAT_W  = 256;
    parameter integer ACLK_PS = 3333;
    parameter         WFILE   = "weights.hex";
    parameter         SFILE   = "shifts.hex";
    parameter integer NSETS   = 9;

    localparam integer W  = BEAT_W / N_CH;
    localparam integer SL = BEAT_W / 32;
    localparam integer L  = $clog2(N_CH);
    localparam integer LAT = 7 + L;

    bit aclk = 0, s_axi_aclk = 0;
    always #(ACLK_PS / 2000.0) aclk = ~aclk;
    always #5 s_axi_aclk = ~s_axi_aclk;                       // 100 MHz

    logic aresetn = 0, s_axi_aresetn = 0;

    logic [BEAT_W-1:0] s_tdata = '0;
    logic              s_tvalid = 0, m_tready = 0;
    wire               s_tready, m_tvalid;
    wire  [BEAT_W-1:0] m_tdata;

    logic [15:0] awaddr = 0, araddr = 0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = 0;
    wire         awready, wready, bvalid, arready, rvalid;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;

    rx_beamformer #(.N_CH(N_CH), .BEAT_W(BEAT_W)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    integer errors = 0;
    integer flog;
    integer n_in = 0, n_out = 0;
    logic [31:0] wsets [0:NSETS*N_CH-1];
    logic [31:0] wreg  [0:N_CH-1];             // tb's copy of W[]
    logic [3:0]  ssets [0:NSETS-1];
    logic [3:0]  sreg;                         // tb's copy of SHIFT

    // ---------------------------------------------------------------- stimulus
    integer p_valid = 100, p_ready = 100;      // percent
    bit     run = 0;

    function automatic logic [15:0] rnd16();
        int r = $urandom_range(0, 99);
        if (r < 4)  return 16'h8000;           // -32768
        if (r < 8)  return 16'h7FFF;           //  32767
        if (r < 10) return 16'h8001;           // -32767
        if (r < 12) return 16'h0000;
        if (r < 14) return 16'hFFFF;           // -1
        return $urandom;
    endfunction
    function automatic logic [BEAT_W-1:0] rnd_beat(input integer n);
        logic [BEAT_W-1:0] b;
        for (int i = 0; i < SL; i++) b[32*i +: 32] = {rnd16(), rnd16()};
        if (n % 37 == 0) b[31:0] = 32'h80008000;        // -1-1j on ch0 slot 0
        if (n % 41 == 0) b[31:0] = 32'h7FFF7FFF;
        if (n % 43 == 0) b[31:0] = 32'h80007FFF;
        // coherent beats: channel 0 copied to every channel (one element per
        // channel seeing the same wavefront), incl. full-scale corners
        if (n % 5 == 0)
            for (int c = 1; c < N_CH; c++) b[c*W +: W] = b[W-1:0];
        if (n % 53 == 0)
            for (int c = 0; c < N_CH; c++) b[c*W +: W] = {SL / N_CH{32'h80008000}};
        return b;
    endfunction

    always @(posedge aclk) begin
        // AXI-Stream source: hold the beat until accepted
        if (s_tvalid && s_tready) begin
            $fwrite(flog, "I %0d %h\n", n_in, s_tdata);
            n_in = n_in + 1;
            s_tvalid <= 0;
        end
        if (run && (!s_tvalid || s_tready) && $urandom_range(0, 99) < p_valid) begin
            s_tdata  <= rnd_beat(n_in);
            s_tvalid <= 1;
        end
        // sink
        if (m_tvalid && m_tready) begin
            $fwrite(flog, "O %0d %h\n", n_out, m_tdata);
            n_out = n_out + 1;
        end
        m_tready <= ($urandom_range(0, 99) < p_ready);
    end

    // AXIS contract: a stalled output beat stays put; s_tready follows the sink
    logic [BEAT_W-1:0] last_d; logic last_stall = 0;
    always @(posedge aclk) if (aresetn) begin
        if (last_stall && (!m_tvalid || m_tdata !== last_d)) begin
            errors++; $display("ERROR %t: m_axis changed while stalled", $time);
        end
        last_stall <= m_tvalid && !m_tready;
        last_d     <= m_tdata;
        if (m_tready && !s_tready) begin
            errors++; $display("ERROR %t: s_axis_tready low while m_axis_tready high", $time);
        end
    end

    // Latency: with tready held high, the first beat leaves exactly LAT =
    // 7 + log2(N) cycles after it was accepted.
    integer cyc = 0, t_in0 = -1, t_out0 = -1;
    always @(posedge aclk) begin
        cyc++;
        if (t_in0 < 0 && s_tvalid && s_tready) t_in0 = cyc;
        if (t_out0 < 0 && m_tvalid && m_tready) t_out0 = cyc;
    end

    // AXI-Lite: rvalid only after an AR handshake
    integer ar_done = 0, r_done = 0;
    always @(posedge s_axi_aclk) begin
        if (rvalid && ar_done <= r_done) begin
            errors++; $display("ERROR %t: rvalid without a completed AR handshake", $time);
        end
        if (arvalid && arready) ar_done++;
        if (rvalid && rready) r_done++;
    end

    // ---------------------------------------------------------------- AXI-Lite
    task automatic axi_wr(input [15:0] a, input [31:0] d);
        @(posedge s_axi_aclk);
        awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1; bready <= 1;
        fork
            begin do @(posedge s_axi_aclk); while (!awready); awvalid <= 0; end
            begin do @(posedge s_axi_aclk); while (!wready);  wvalid  <= 0; end
        join
        while (!bvalid) @(posedge s_axi_aclk);
        @(posedge s_axi_aclk); bready <= 0;
    endtask
    task automatic axi_rd(input [15:0] a, output [31:0] d);
        @(posedge s_axi_aclk);
        araddr <= a; arvalid <= 1; rready <= 1;
        do @(posedge s_axi_aclk); while (!arready);
        arvalid <= 0;
        while (!rvalid) @(posedge s_axi_aclk);
        d = rdata;
        @(posedge s_axi_aclk); rready <= 0;
    endtask
    task automatic expect_rd(input [15:0] a, input [31:0] e, input string what);
        logic [31:0] d;
        axi_rd(a, d);
        if (d !== e) begin
            errors++; $display("ERROR read %s @0x%02h: got %08h expected %08h", what, a, d, e);
        end
    endtask

    // ---------------------------------------------------------------- events
    task automatic set_en(input bit v);
        integer n0 = n_in;
        axi_wr(16'h04, {31'd0, v});
        $fwrite(flog, "E %0d %0d EN %0d\n", n0, n_in, v);
    endtask
    task automatic write_set(input integer k);          // W[], SHIFT <- set k, no LOAD
        for (int c = 0; c < N_CH; c++) begin
            axi_wr(16'h40 + 4*c, wsets[k*N_CH + c]);
            wreg[c] = wsets[k*N_CH + c];
        end
        axi_wr(16'h10, {28'd0, ssets[k]});
        sreg = ssets[k];
    endtask
    task automatic load();
        integer n0 = n_in;
        axi_wr(16'h0C, 32'd1);
        $fwrite(flog, "E %0d %0d LOAD %h", n0, n_in, sreg);
        for (int c = 0; c < N_CH; c++) $fwrite(flog, " %08h", wreg[c]);
        $fwrite(flog, "\n");
    endtask
    task automatic beats(input integer n);               // wait for n more input beats
        integer t = n_in + n;
        while (n_in < t) @(posedge aclk);
    endtask
    task automatic drain();
        run = 0;
        repeat (4) @(posedge aclk);
        while (s_tvalid || n_out < n_in) begin p_ready = 100; @(posedge aclk); end
        repeat (4) @(posedge aclk);
    endtask
    task automatic check_regs(input bit en);
        expect_rd(16'h00, 32'h5A523031, "ID");
        expect_rd(16'h04, {31'd0, en}, "CTRL");
        expect_rd(16'h08, N_CH, "NCH");
        expect_rd(16'h0C, 32'd0, "LOAD");
        expect_rd(16'h10, {28'd0, sreg}, "SHIFT");
        for (int c = 0; c < N_CH; c++) expect_rd(16'h40 + 4*c, wreg[c], "W");
        if (N_CH < 16) expect_rd(16'h40 + 4*N_CH, 32'd0, "W[N_CH]");
    endtask

    initial begin
        string fn;
        $readmemh(WFILE, wsets);
        $readmemh(SFILE, ssets);
        sreg = L;
        if (!$value$plusargs("LOG=%s", fn)) fn = "rbf.log";
        flog = $fopen(fn, "w");
        $fwrite(flog, "P %0d %0d\n", N_CH, BEAT_W);
        for (int c = 0; c < N_CH; c++) wreg[c] = 32'h00007FFF;

        repeat (20) @(posedge s_axi_aclk);
        aresetn = 1; s_axi_aresetn = 1;
        repeat (20) @(posedge s_axi_aclk);

        // --- registers at reset
        check_regs(0);
        axi_wr(16'h08, 32'h1234);                         // RO: ignored
        axi_wr(16'h00, 32'h1234);
        if (N_CH < 16) axi_wr(16'h40 + 4*N_CH, 32'h1234); // beyond N_CH: ignored
        check_regs(0);

        // --- A: bypass, RFDC-like (valid and ready every cycle)
        run = 1; p_valid = 100; p_ready = 100;
        beats(300);
        // --- B: bypass with gaps and backpressure
        p_valid = 70; p_ready = 60;
        beats(300);
        // --- C: enable with the reset weights (unity, SHIFT log2 N)
        p_valid = 100; p_ready = 100;
        set_en(1); beats(200);
        // --- D: steering weights loaded mid-stream, each LOADed while streaming
        for (int k = 0; k < NSETS; k++) begin
            if (k == 3) begin p_valid = 80; p_ready = 70; end
            if (k == 6) begin p_valid = 100; p_ready = 100; end
            write_set(k);
            beats(60);                                    // W written, no LOAD: unchanged
            load(); beats(150);
        end
        check_regs(1);
        // --- E: LOAD without changes, twice
        load(); beats(100);
        load(); beats(100);
        // --- F: enable toggling, also under backpressure
        for (int t = 0; t < 8; t++) begin
            if (t == 4) begin p_valid = 75; p_ready = 65; end
            set_en(t % 2 == 0 ? 0 : 1); beats(40 + $urandom_range(0, 40));
        end
        p_valid = 100; p_ready = 100;
        set_en(1); beats(50);
        // --- G: back-to-back LOADs (second one is held while the first crosses)
        write_set(1); load();
        write_set(2); load();
        beats(200);
        // --- H: aclk reset: the datapath must keep the last LOADed set
        drain();
        aresetn = 0; repeat (5) @(posedge aclk); aresetn = 1; repeat (5) @(posedge aclk);
        $fwrite(flog, "E %0d %0d ARST\n", n_in, n_in);
        run = 1; beats(200);
        // --- I: s_axi reset: enable 0, W defaults, LOADed automatically
        drain();
        s_axi_aresetn = 0; repeat (3) @(posedge s_axi_aclk); s_axi_aresetn = 1;
        $fwrite(flog, "E %0d %0d SRST\n", n_in, n_in);
        for (int c = 0; c < N_CH; c++) wreg[c] = 32'h00007FFF;
        sreg = L;
        repeat (20) @(posedge s_axi_aclk);
        check_regs(0);
        run = 1; beats(100);
        set_en(1); beats(150);
        // --- J: corner weight set (saturation, SHIFT 0) with sustained
        // backpressure, then SHIFT 15 and SHIFT 0 random sets, then end
        p_valid = 90; p_ready = 50;
        write_set(4); load(); beats(200);
        p_valid = 100; p_ready = 100;
        write_set(6); load(); beats(150);
        write_set(8); load(); beats(150);
        drain();

        $display("LATENCY %0d cycles", t_out0 - t_in0);
        if (t_out0 - t_in0 != LAT) begin
            errors++; $display("ERROR: latency %0d, expected %0d", t_out0 - t_in0, LAT);
        end
        if (n_out != n_in) begin
            errors++; $display("ERROR: %0d beats in, %0d out", n_in, n_out);
        end
        $fwrite(flog, "D %0d %0d\n", n_in, n_out);
        $fclose(flog);
        $display("TB_DONE N_CH=%0d BEAT_W=%0d beats=%0d TB_ERRORS=%0d", N_CH, BEAT_W, n_in, errors);
        $finish;
    end

    initial begin
        #5ms;
        $display("ERROR: timeout");
        $finish;
    end
endmodule
