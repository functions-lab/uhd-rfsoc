// tb_tx_dpd -- stimulus + register checks for src/tx_dpd.v.
//
// Parameters (xelab -generic_top): N_CH, BEAT_W, ACLK_PS (converter clock
// period), CFILE (coefficient sets from `check_dpd.py gen`, NSETS x 40 words).
//
// The tb checks the register file itself (ID, CONFIG, TOPO, reset values,
// SHADOW / ACTIVE readback, STATUS, other addresses read 0, rvalid only after
// an AR handshake) and logs, one line per aclk cycle and per event:
//   I <cyc> <valid> <hex>                 s_axis this cycle
//   O <cyc> <valid> <hex>                 m_axis this cycle
//   E <c0> <c1> <c2> CTRL <ch> <byp>      CTRL write (bypass only), started at
//                                          cycle c0, done at c1, delivered by c2
//   E <c0> <c1> <c2> COMMIT <ch> <byp> <w0> .. <w39>   COMMIT of that set
//   E <c0> <c1> <c2> SRST                 s_axi reset (identity + bypass)
//   E <c0> <c0> <c0> ARST                 aclk reset (identity + bypass)
//   S <cyc> <ch> <sat_out> <sat_gain> <peak>   statistics read while idle,
//                                          counted since the previous CLR
//   C <cyc>                               CLR_STATS of every channel (idle)
// check_dpd.py replays the log against rfsoc_lib/dsp/dpd.py dpd_fx().
`timescale 1ns / 1ps

module tb_tx_dpd;
    parameter integer N_CH    = 4;
    parameter integer BEAT_W  = 512;
    parameter integer ACLK_PS = 3200;
    parameter         CFILE   = "coefs.hex";
    parameter integer NSETS   = 8;

    localparam integer W   = BEAT_W / N_CH;
    localparam integer SSR = W / 32;
    localparam integer SL  = BEAT_W / 32;

    bit aclk = 0, s_axi_aclk = 0;
    always #(ACLK_PS / 2000.0) aclk = ~aclk;
    always #5 s_axi_aclk = ~s_axi_aclk;                       // 100 MHz

    logic aresetn = 0, s_axi_aresetn = 0;

    logic [BEAT_W-1:0] s_tdata = '0;
    logic              s_tvalid = 0;
    wire               s_tready, m_tvalid;
    wire  [BEAT_W-1:0] m_tdata;

    logic [15:0] awaddr = 0, araddr = 0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = 0;
    wire         awready, wready, bvalid, arready, rvalid;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;

    tx_dpd #(.N_CH(N_CH), .BEAT_W(BEAT_W)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(1'b1),
        .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    integer errors = 0;
    integer flog;
    integer cyc = 0;
    logic [31:0] csets [0:NSETS*40-1];
    logic [31:0] shadow [0:N_CH-1][0:39];     // tb's copy of SHADOW
    logic [31:0] active [0:N_CH-1][0:39];     // ... of ACTIVE
    logic        byp    [0:N_CH-1];
    logic [7:0]  ccnt   [0:N_CH-1];

    // ---------------------------------------------------------------- stimulus
    integer p_valid = 100;                     // percent
    integer amp = 22000;                       // peak of the random samples
    bit     run = 0;

    function automatic logic [15:0] rnd16();
        int r = $urandom_range(0, 999);
        if (r < 6)  return 16'h8000;           // -32768
        if (r < 12) return 16'h7FFF;           //  32767
        if (r < 16) return 16'h8001;
        if (r < 20) return 16'h0000;
        return 16'($signed($urandom_range(0, 2 * amp)) - amp);
    endfunction
    function automatic logic [BEAT_W-1:0] rnd_beat();
        logic [BEAT_W-1:0] b;
        for (int i = 0; i < SL; i++) b[32*i +: 32] = {rnd16(), rnd16()};
        return b;
    endfunction

    // the DAC takes a beat every cycle: s_axis changes every cycle
    always @(posedge aclk) begin
        cyc <= cyc + 1;
        $fwrite(flog, "I %0d %0d %h\n", cyc, s_tvalid, s_tdata);
        $fwrite(flog, "O %0d %0d %h\n", cyc, m_tvalid, m_tdata);
        if (run && $urandom_range(0, 99) < p_valid) begin
            s_tdata <= rnd_beat(); s_tvalid <= 1;
        end else begin
            s_tdata <= run ? rnd_beat() : '0; s_tvalid <= 0;   // invalid data must not leak
        end
        if (!s_tready) begin errors++; $display("ERROR %t: s_axis_tready low", $time); end
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
            errors++; $display("ERROR read %s @0x%04h: got %08h expected %08h", what, a, d, e);
        end
    endtask
    function automatic [31:0] sx27(input [31:0] w);
        return {{5{w[26]}}, w[26:0]};
    endfunction

    // ---------------------------------------------------------------- registers
    function automatic [15:0] base(input integer c); return 16'(c * 16'h400); endfunction

    task automatic wait_status(input integer c, input integer bitn);   // until STATUS[bitn] = 0
        logic [31:0] d;
        integer n = 0;
        do begin axi_rd(base(c) + 16'h004, d); n++; end while (d[bitn] && n < 20000);
        if (d[bitn]) begin errors++; $display("ERROR: channel %0d STATUS[%0d] stuck", c, bitn); end
    endtask

    task automatic write_shadow(input integer c, input integer k);      // SHADOW <- set k
        for (int w = 0; w < 40; w++) begin
            axi_wr(base(c) + 16'h100 + 4*w, csets[k*40 + w]);
            shadow[c][w] = csets[k*40 + w];
        end
    endtask

    task automatic commit(input integer c, input bit b);
        integer c0 = cyc, c1, c2;
        axi_wr(base(c), {30'd0, 1'b1, b});
        c1 = cyc;
        wait_status(c, 1);
        c2 = cyc;
        byp[c] = b; ccnt[c] = ccnt[c] + 1;
        for (int w = 0; w < 40; w++) active[c][w] = shadow[c][w];
        $fwrite(flog, "E %0d %0d %0d COMMIT %0d %0d", c0, c1, c2, c, b);
        for (int w = 0; w < 40; w++) $fwrite(flog, " %08h", shadow[c][w] & 32'h07FFFFFF);
        $fwrite(flog, "\n");
    endtask

    task automatic set_bypass(input integer c, input bit b);
        integer c0 = cyc, c1, c2;
        axi_wr(base(c), {31'd0, b});
        c1 = cyc;
        wait_status(c, 2);
        c2 = cyc;
        byp[c] = b;
        $fwrite(flog, "E %0d %0d %0d CTRL %0d %0d\n", c0, c1, c2, c, b);
    endtask

    task automatic check_regs(input integer c);
        logic [31:0] st;
        expect_rd(base(c) + 16'h000, {31'd0, byp[c]}, "CTRL");
        expect_rd(base(c) + 16'h008, 32'h5A443031, "ID");
        expect_rd(base(c) + 16'h00C, 32'h20142244, "CONFIG");
        expect_rd(base(c) + 16'h01C, {8'd0, 8'(c), 8'(SSR), 8'(N_CH)}, "TOPO");
        for (int w = 0; w < 40; w++) begin
            expect_rd(base(c) + 16'h100 + 4*w, sx27(shadow[c][w]), "SHADOW");
            expect_rd(base(c) + 16'h200 + 4*w, sx27(active[c][w]), "ACTIVE");
        end
        expect_rd(base(c) + 16'h1A0, 32'd0, "beyond SHADOW");
        expect_rd(base(c) + 16'h2A0, 32'd0, "beyond ACTIVE");
        expect_rd(base(c) + 16'h020, 32'd0, "0x020");
        axi_rd(base(c) + 16'h004, st);
        if (st[15:8] !== ccnt[c] || st[2:1] !== 2'b00) begin
            errors++; $display("ERROR STATUS ch%0d: %08h (commits %0d)", c, st, ccnt[c]);
        end
    endtask

    task automatic idle(input integer n);        // input stopped for n beats
        run = 0;
        repeat (n) @(posedge aclk);
    endtask
    task automatic beats(input integer n);
        run = 1;
        repeat (n) @(posedge aclk);
    endtask

    task automatic read_stats();                 // while idle, after a snapshot refresh
        logic [31:0] so, sg, pk;
        repeat (20 * N_CH + 40) @(posedge s_axi_aclk);
        repeat (60 * N_CH) @(posedge aclk);
        for (int c = 0; c < N_CH; c++) begin
            axi_rd(base(c) + 16'h010, so);
            axi_rd(base(c) + 16'h014, sg);
            axi_rd(base(c) + 16'h018, pk);
            $fwrite(flog, "S %0d %0d %0d %0d %08h\n", cyc, c, so, sg, pk);
        end
    endtask
    task automatic clr_stats();                  // while idle
        for (int c = 0; c < N_CH; c++) begin
            axi_wr(base(c), {29'd0, 1'b1, 1'b0, byp[c]});
            wait_status(c, 2);
        end
        repeat (20 * N_CH + 40) @(posedge s_axi_aclk);
        repeat (60 * N_CH) @(posedge aclk);
        $fwrite(flog, "C %0d\n", cyc);
    endtask

    task automatic set_identity(input integer c);
        for (int w = 0; w < 40; w++) shadow[c][w] = (w == 0) ? 32'h00200000 : 32'd0;
    endtask

    initial begin
        string fn;
        logic [31:0] d;
        integer c0, c1, c2;
        $readmemh(CFILE, csets);
        if (!$value$plusargs("LOG=%s", fn)) fn = "dpd.log";
        flog = $fopen(fn, "w");
        $fwrite(flog, "P %0d %0d\n", N_CH, BEAT_W);
        for (int c = 0; c < N_CH; c++) begin
            set_identity(c);
            for (int w = 0; w < 40; w++) active[c][w] = shadow[c][w];
            byp[c] = 1; ccnt[c] = 1;              // the s_axi reset's identity COMMIT
        end

        repeat (20) @(posedge s_axi_aclk);
        aresetn = 1; s_axi_aresetn = 1;
        repeat (40) @(posedge aclk);
        for (int c = 0; c < N_CH; c++) wait_status(c, 1);
        repeat (20) @(posedge s_axi_aclk);

        // --- registers at reset; RO and out-of-range writes are ignored
        for (int c = 0; c < N_CH; c++) check_regs(c);
        axi_wr(16'h0008, 32'h1234);
        axi_wr(16'h0200, 32'h1234);
        axi_wr(16'h01A0, 32'h1234);                       // beyond SHADOW
        if (N_CH < 16) axi_wr(base(N_CH) + 16'h100, 32'h1234);
        axi_wr(16'h4000, 32'h1234);                       // [15:14] != 0
        expect_rd(16'h4008, 32'd0, "[15:14] != 0");
        if (N_CH < 16) expect_rd(base(N_CH) + 16'h008, 32'd0, "channel N_CH");
        for (int c = 0; c < N_CH; c++) check_regs(c);
        axi_rd(16'h0004, d);
        if (d[3] !== 1'b0) begin errors++; $display("ERROR: STATUS[3] set after the reset COMMIT"); end

        // --- A: bypass, then identity with the DPD path on (must be bit-exact)
        clr_stats();
        beats(200);
        for (int c = 0; c < N_CH; c++) set_bypass(c, 0);
        beats(200);
        idle(48); read_stats();
        // --- B: every channel its own set, committed mid-stream (bypass off)
        for (int k = 0; k < 3; k++) begin
            for (int c = 0; c < N_CH; c++) write_shadow(c, (k * N_CH + c + 1) % NSETS);
            beats(30);                                    // SHADOW written, no COMMIT: unchanged
            for (int c = 0; c < N_CH; c++) begin commit(c, 0); beats(20 + $urandom_range(0, 30)); end
            beats(100);
        end
        for (int c = 0; c < N_CH; c++) check_regs(c);
        // --- C: gaps in the input stream
        p_valid = 70; beats(300); p_valid = 100;
        // --- D: bypass toggling, and COMMIT with bypass on and off
        for (int t = 0; t < 6; t++) begin
            set_bypass(t % N_CH, t % 2 == 0); beats(40 + $urandom_range(0, 40));
        end
        for (int c = 0; c < N_CH; c++) begin
            write_shadow(c, (c + 5) % NSETS); commit(c, c % 2); beats(60);
        end
        for (int c = 0; c < N_CH; c++) set_bypass(c, 0);
        beats(100);
        // --- E: statistics over a saturating set at full drive
        idle(48); clr_stats();
        amp = 32767;
        for (int c = 0; c < N_CH; c++) begin write_shadow(c, 0); commit(c, 0); end
        idle(48); clr_stats();
        beats(400);
        idle(48); read_stats();
        amp = 22000;
        // --- F: COMMIT with SHADOW_IDENTITY: the set goes, SHADOW is identity after
        write_shadow(0, 2);
        begin
            c0 = cyc;
            axi_wr(base(0), 32'h0000000A);                // COMMIT | SHADOW_IDENTITY, bypass 0
            c1 = cyc; wait_status(0, 1); c2 = cyc;
            ccnt[0] = ccnt[0] + 1; byp[0] = 0;
            for (int w = 0; w < 40; w++) active[0][w] = shadow[0][w];
            $fwrite(flog, "E %0d %0d %0d COMMIT 0 0", c0, c1, c2);
            for (int w = 0; w < 40; w++) $fwrite(flog, " %08h", shadow[0][w] & 32'h07FFFFFF);
            $fwrite(flog, "\n");
            set_identity(0);
        end
        beats(200);
        check_regs(0);
        // --- G: back-to-back COMMITs on every channel, not waiting in between
        for (int c = 0; c < N_CH; c++) write_shadow(c, (c + 3) % NSETS);
        begin
            c0 = cyc;
            for (int c = 0; c < N_CH; c++) axi_wr(base(c), 32'h00000002);
            c1 = cyc;
            for (int c = 0; c < N_CH; c++) wait_status(c, 1);
            c2 = cyc;
            for (int c = 0; c < N_CH; c++) begin
                ccnt[c] = ccnt[c] + 1; byp[c] = 0;
                for (int w = 0; w < 40; w++) active[c][w] = shadow[c][w];
                $fwrite(flog, "E %0d %0d %0d COMMIT %0d 0", c0, c1, c2, c);
                for (int w = 0; w < 40; w++) $fwrite(flog, " %08h", shadow[c][w] & 32'h07FFFFFF);
                $fwrite(flog, "\n");
            end
        end
        run = 1;
        beats(300);
        // --- H: aclk reset: every channel back to bypass + identity, STATUS[3]
        idle(48);
        aresetn = 0; repeat (6) @(posedge aclk); aresetn = 1; repeat (6) @(posedge aclk);
        $fwrite(flog, "E %0d %0d %0d ARST\n", cyc, cyc, cyc);
        repeat (20 * N_CH + 40) @(posedge s_axi_aclk);
        repeat (60 * N_CH) @(posedge aclk);
        for (int c = 0; c < N_CH; c++) begin
            axi_rd(base(c) + 16'h004, d);
            if (d[3] !== 1'b1 || d[0] !== 1'b1) begin
                errors++; $display("ERROR: STATUS after aclk reset ch%0d %08h", c, d);
            end
        end
        beats(200);
        write_shadow(0, 4); commit(0, 0);
        axi_rd(16'h0004, d);
        repeat (20 * N_CH + 40) @(posedge s_axi_aclk);
        repeat (60 * N_CH) @(posedge aclk);
        axi_rd(16'h0004, d);
        if (d[3] !== 1'b0) begin errors++; $display("ERROR: STATUS[3] after a COMMIT %08h", d); end
        beats(200);
        // --- I: s_axi reset mid-stream: identity + bypass COMMITted to every channel
        begin
            c0 = cyc;
            s_axi_aresetn = 0; repeat (3) @(posedge s_axi_aclk); s_axi_aresetn = 1;
            for (int c = 0; c < N_CH; c++) wait_status(c, 1);
            c2 = cyc;
            $fwrite(flog, "E %0d %0d %0d SRST\n", c0, c0, c2);
            for (int c = 0; c < N_CH; c++) begin
                set_identity(c); byp[c] = 1; ccnt[c] = 1;
                for (int w = 0; w < 40; w++) active[c][w] = shadow[c][w];
            end
        end
        beats(200);
        for (int c = 0; c < N_CH; c++) check_regs(c);
        idle(48);

        $fwrite(flog, "D %0d\n", cyc);
        $fclose(flog);
        $display("TB_DONE N_CH=%0d BEAT_W=%0d SSR=%0d cycles=%0d TB_ERRORS=%0d", N_CH, BEAT_W, SSR, cyc, errors);
        $finish;
    end

    initial begin
        #20ms;
        $display("ERROR: timeout");
        $finish;
    end
endmodule
