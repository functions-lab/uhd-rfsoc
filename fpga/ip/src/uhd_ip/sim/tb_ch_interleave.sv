// tb_ch_interleave -- self-checking test of src/ch_interleave.v.
//
// For every legal (N_CH, BEAT_W) pair (N_CH*32 <= BEAT_W) and REG = 0 and 1:
//   * DIR 0 on a random stream, checked against an independent model of
//     Protocol §9 (channel-major slot k*S+s -> sample-major slot s*N+k);
//   * DIR 1 on a random stream, checked against the inverse model;
//   * DIR 0 followed by DIR 1, checked to be the identity.
// Streams have random tvalid and random downstream tready (sources hold their
// beat while it is not accepted), and each output is scoreboarded against the
// beats accepted at the input, so REG = 1 backpressure is covered too.
// Prints one line per combination and "CH_INTERLEAVE PASS" / fatal.
`timescale 1ns / 1ps

module chk_one #(parameter int N = 1, parameter int W = 128, parameter int REG = 0) (
    input  bit clk,
    input  bit run,
    output int errors,
    output int beats
);
    localparam int SLOTS = W / 32;
    localparam int S     = SLOTS / N;

    function automatic [W-1:0] c2s(input [W-1:0] cm);   // model of DIR 0
        for (int k = 0; k < N; k++)
            for (int s = 0; s < S; s++)
                c2s[32*(s*N + k) +: 32] = cm[32*(k*S + s) +: 32];
    endfunction
    function automatic [W-1:0] s2c(input [W-1:0] sm);   // model of DIR 1
        for (int k = 0; k < N; k++)
            for (int s = 0; s < S; s++)
                s2c[32*(k*S + s) +: 32] = sm[32*(s*N + k) +: 32];
    endfunction
    function automatic [W-1:0] rnd();
        for (int i = 0; i < W / 32; i++) rnd[32*i +: 32] = $urandom;
    endfunction

    // three paths: 0 = DIR0, 1 = DIR1, 2 = DIR0 -> DIR1
    logic [W-1:0] s_d [3];
    logic         s_v [3];
    wire          s_r [3];
    wire  [W-1:0] m_d [3];
    wire          m_v [3];
    logic         m_r [3];
    wire  [W-1:0] mid_d; wire mid_v, mid_r;

    ch_interleave #(.N_CH(N), .BEAT_W(W), .DIR(0), .REG(REG)) u_c2s (
        .aclk(clk), .s_axis_tdata(s_d[0]), .s_axis_tvalid(s_v[0]), .s_axis_tready(s_r[0]),
        .m_axis_tdata(m_d[0]), .m_axis_tvalid(m_v[0]), .m_axis_tready(m_r[0]));
    ch_interleave #(.N_CH(N), .BEAT_W(W), .DIR(1), .REG(REG)) u_s2c (
        .aclk(clk), .s_axis_tdata(s_d[1]), .s_axis_tvalid(s_v[1]), .s_axis_tready(s_r[1]),
        .m_axis_tdata(m_d[1]), .m_axis_tvalid(m_v[1]), .m_axis_tready(m_r[1]));
    ch_interleave #(.N_CH(N), .BEAT_W(W), .DIR(0), .REG(REG)) u_ch0 (
        .aclk(clk), .s_axis_tdata(s_d[2]), .s_axis_tvalid(s_v[2]), .s_axis_tready(s_r[2]),
        .m_axis_tdata(mid_d), .m_axis_tvalid(mid_v), .m_axis_tready(mid_r));
    ch_interleave #(.N_CH(N), .BEAT_W(W), .DIR(1), .REG(REG)) u_ch1 (
        .aclk(clk), .s_axis_tdata(mid_d), .s_axis_tvalid(mid_v), .s_axis_tready(mid_r),
        .m_axis_tdata(m_d[2]), .m_axis_tvalid(m_v[2]), .m_axis_tready(m_r[2]));

    logic [W-1:0] sb [3][$];
    initial begin
        errors = 0; beats = 0;
        for (int p = 0; p < 3; p++) begin s_v[p] = 0; s_d[p] = '0; m_r[p] = 0; end
    end
    always @(posedge clk) begin
        for (int p = 0; p < 3; p++) begin
            // REG = 0 must pass tready straight through
            if (REG == 0 && p < 2 && s_r[p] !== m_r[p]) begin
                if (errors < 5) $display("ERROR N=%0d W=%0d REG=%0d path %0d: tready not passed through", N, W, REG, p);
                errors++;
            end
            if (REG == 0 && p < 2 && m_v[p] !== s_v[p]) begin
                if (errors < 5) $display("ERROR N=%0d W=%0d REG=%0d path %0d: tvalid not passed through", N, W, REG, p);
                errors++;
            end
            // input side: record the expected output of each accepted beat (before the
            // output check: with REG = 0 the same beat leaves in this cycle)
            if (s_v[p] && s_r[p])
                sb[p].push_back(p == 0 ? c2s(s_d[p]) : p == 1 ? s2c(s_d[p]) : s_d[p]);
            // output side: compare against the scoreboard
            if (m_v[p] && m_r[p]) begin
                if (sb[p].size() == 0) begin
                    if (errors < 5) $display("ERROR N=%0d W=%0d REG=%0d path %0d: output with no input", N, W, REG, p);
                    errors++;
                end else begin
                    logic [W-1:0] want;
                    want = sb[p].pop_front();
                    if (m_d[p] !== want) begin
                        if (errors < 5) $display("ERROR N=%0d W=%0d REG=%0d path %0d: got %h want %h", N, W, REG, p, m_d[p], want);
                        errors++;
                    end
                    beats++;
                end
            end
            if (!s_v[p] || s_r[p]) begin             // AXIS: hold until accepted
                s_v[p] <= run && ($urandom % 4 != 0);
                s_d[p] <= rnd();
            end
            m_r[p] <= ($urandom % 5 != 0);
        end
    end
endmodule

module tb_ch_interleave;
    bit clk = 0;
    always #2 clk = ~clk;
    bit run = 0;

    localparam int NS [5] = '{1, 2, 4, 8, 16};
    localparam int WS [4] = '{128, 256, 512, 1024};
    int err [2][4][5];
    int nbt [2][4][5];

    genvar r, w, n;
    generate
        for (r = 0; r < 2; r++) begin : g_r
            for (w = 0; w < 4; w++) begin : g_w
                for (n = 0; n < 5; n++) begin : g_n
                    if (NS[n] * 32 <= WS[w]) begin : g_ok
                        chk_one #(.N(NS[n]), .W(WS[w]), .REG(r)) u (
                            .clk(clk), .run(run), .errors(err[r][w][n]), .beats(nbt[r][w][n]));
                    end else begin : g_skip
                        initial begin err[r][w][n] = 0; nbt[r][w][n] = -1; end
                    end
                end
            end
        end
    endgenerate

    initial begin
        int total_err, combos;
        repeat (5) @(posedge clk);
        run = 1;
        repeat (4000) @(posedge clk);
        run = 0;
        repeat (20) @(posedge clk);          // drain
        total_err = 0; combos = 0;
        $display("REG BEAT_W N_CH  beats/path  errors  (paths: DIR0, DIR1, DIR0->DIR1)");
        for (int rr = 0; rr < 2; rr++)
            for (int ww = 0; ww < 4; ww++)
                for (int nn = 0; nn < 5; nn++)
                    if (nbt[rr][ww][nn] >= 0) begin
                        $display("%3d %6d %4d  %10d  %6d  %s", rr, WS[ww], NS[nn],
                                 nbt[rr][ww][nn] / 3, err[rr][ww][nn],
                                 (err[rr][ww][nn] == 0 && nbt[rr][ww][nn] > 3000) ? "PASS" : "FAIL");
                        if (err[rr][ww][nn] != 0 || nbt[rr][ww][nn] <= 3000) total_err++;
                        combos++;
                    end
        if (total_err != 0) $fatal(1, "CH_INTERLEAVE FAIL: %0d of %0d combinations", total_err, combos);
        $display("CH_INTERLEAVE PASS: %0d combinations x 3 paths", combos);
        $finish;
    end
endmodule
