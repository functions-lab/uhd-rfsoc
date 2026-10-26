// tb_axis_pkt_arb -- axis_pkt_arb (REG_OUT 1 and 0) against
// axis_pkt_arb_skid_ref (the previous REG_OUT=1 form): the same random
// traffic into both, every port compared on every cycle -- s0/s1 tready and
// m_axis_tvalid always, m_axis_t{data,keep,last,user} while tvalid. Phases
// sweep the sources' valid density and the sink's ready density (always
// ready, CMAC-like rare stalls, 50 %, mostly stalled, bursts), with resets in
// between. Also checks AXIS rules on m_axis (no bubble inside a frame while
// the granted source has data is the reference's behaviour, so equality
// covers it) and counts beats and frames per source.
`timescale 1ns / 1ps
module tb_axis_pkt_arb;
    localparam int W = 512 + 64 + 2;
    logic clk = 0, aresetn = 0;
    always #1.55 clk = ~clk;

    logic [511:0] d0, d1; logic [63:0] k0, k1;
    logic v0, v1, l0, l1, u0, u1, rdy;

    // DUTs
    wire r0_ref, r1_ref, r0_new, r1_new, r0_cmb, r1_cmb;
    wire [511:0] md_ref, md_new; wire [63:0] mk_ref, mk_new;
    wire mv_ref, mv_new, ml_ref, ml_new, mu_ref, mu_new;
    axis_pkt_arb_skid_ref #(.REG_OUT(1)) ref_i (.clk, .aresetn,
        .s0_axis_tdata(d0), .s0_axis_tkeep(k0), .s0_axis_tvalid(v0), .s0_axis_tlast(l0), .s0_axis_tuser(u0), .s0_axis_tready(r0_ref),
        .s1_axis_tdata(d1), .s1_axis_tkeep(k1), .s1_axis_tvalid(v1), .s1_axis_tlast(l1), .s1_axis_tuser(u1), .s1_axis_tready(r1_ref),
        .m_axis_tdata(md_ref), .m_axis_tkeep(mk_ref), .m_axis_tvalid(mv_ref), .m_axis_tlast(ml_ref), .m_axis_tuser(mu_ref),
        .m_axis_tready(rdy));
    axis_pkt_arb #(.REG_OUT(1)) new_i (.clk, .aresetn,
        .s0_axis_tdata(d0), .s0_axis_tkeep(k0), .s0_axis_tvalid(v0), .s0_axis_tlast(l0), .s0_axis_tuser(u0), .s0_axis_tready(r0_new),
        .s1_axis_tdata(d1), .s1_axis_tkeep(k1), .s1_axis_tvalid(v1), .s1_axis_tlast(l1), .s1_axis_tuser(u1), .s1_axis_tready(r1_new),
        .m_axis_tdata(md_new), .m_axis_tkeep(mk_new), .m_axis_tvalid(mv_new), .m_axis_tlast(ml_new), .m_axis_tuser(mu_new),
        .m_axis_tready(rdy));
    // REG_OUT=0 still elaborates and passes the handshake through
    wire [511:0] md_cmb; wire [63:0] mk_cmb; wire mv_cmb, ml_cmb, mu_cmb;
    axis_pkt_arb #(.REG_OUT(0)) cmb_i (.clk, .aresetn,
        .s0_axis_tdata(d0), .s0_axis_tkeep(k0), .s0_axis_tvalid(v0), .s0_axis_tlast(l0), .s0_axis_tuser(u0), .s0_axis_tready(r0_cmb),
        .s1_axis_tdata(d1), .s1_axis_tkeep(k1), .s1_axis_tvalid(v1), .s1_axis_tlast(l1), .s1_axis_tuser(u1), .s1_axis_tready(r1_cmb),
        .m_axis_tdata(md_cmb), .m_axis_tkeep(mk_cmb), .m_axis_tvalid(mv_cmb), .m_axis_tlast(ml_cmb), .m_axis_tuser(mu_cmb),
        .m_axis_tready(rdy));

    int errors = 0, cycles = 0, beats = 0, frames = 0, s0_beats = 0, s1_beats = 0;
    int pv0, pv1, prdy, plast;   // per-phase densities, percent

    // AXIS-legal sources: a beat is held until accepted (the arbiter relies on
    // it). Nonblocking: the DUTs sample the previous values on this edge.
    task automatic new_beat(input int src);
        if (src == 0) begin
            d0 <= {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
                  $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
            k0 <= {$urandom, $urandom}; l0 <= ($urandom_range(99) < plast); u0 <= $urandom;
            v0 <= ($urandom_range(99) < pv0);
        end else begin
            d1 <= {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
                  $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
            k1 <= {$urandom, $urandom}; l1 <= ($urandom_range(99) < plast); u1 <= $urandom;
            v1 <= ($urandom_range(99) < pv1);
        end
    endtask

    always @(negedge clk) if (aresetn) begin
        cycles++;
        if (r0_new !== r0_ref) begin errors++; if (errors < 20) $display("ERROR %0t s0_tready new %b ref %b", $time, r0_new, r0_ref); end
        if (r1_new !== r1_ref) begin errors++; if (errors < 20) $display("ERROR %0t s1_tready new %b ref %b", $time, r1_new, r1_ref); end
        if (mv_new !== mv_ref) begin errors++; if (errors < 20) $display("ERROR %0t m_tvalid new %b ref %b", $time, mv_new, mv_ref); end
        else if (mv_ref && {mu_new, ml_new, mk_new, md_new} !== {mu_ref, ml_ref, mk_ref, md_ref}) begin
            errors++; if (errors < 20) $display("ERROR %0t m_axis beat differs (last new %b ref %b)", $time, ml_new, ml_ref);
        end
    end

    // drive on the rising edge (after the DUTs sample): accepted beats are
    // replaced, unaccepted ones held; tready of the sink re-drawn each cycle
    always @(posedge clk) begin
        if (aresetn) begin
            if (v0 && r0_ref) begin s0_beats++; new_beat(0); end else if (!v0) v0 <= ($urandom_range(99) < pv0);
            if (v1 && r1_ref) begin s1_beats++; new_beat(1); end else if (!v1) v1 <= ($urandom_range(99) < pv1);
            if (mv_ref && rdy) begin beats++; if (ml_ref) frames++; end
        end
        rdy <= ($urandom_range(99) < prdy);
    end

    task automatic phase(input int a, input int b, input int r, input int lst, input int n);
        pv0 = a; pv1 = b; prdy = r; plast = lst;
        aresetn <= 0; v0 <= 0; v1 <= 0;
        repeat (4) @(posedge clk);
        new_beat(0); new_beat(1);
        aresetn <= 1;
        repeat (n) @(posedge clk);
        $display("phase s0 %0d%% s1 %0d%% ready %0d%% last %0d%%: %0d cycles so far, %0d beats, %0d frames, errors %0d",
                 a, b, r, lst, cycles, beats, frames, errors);
    endtask

    initial begin
        phase(100, 0, 100, 5, 20000);     // streamer alone, never stalled
        phase(100, 5, 100, 10, 20000);    // + rare control frames
        phase(100, 20, 98, 3, 50000);     // CMAC-like: rare one-cycle stalls
        phase(90, 30, 50, 20, 50000);
        phase(60, 60, 10, 30, 50000);     // mostly stalled
        phase(100, 100, 75, 1, 50000);    // long frames, both always waiting
        phase(30, 30, 100, 50, 50000);    // sparse sources, short frames
        for (int i = 0; i < 20; i++)
            phase($urandom_range(100), $urandom_range(100), $urandom_range(100), $urandom_range(1, 60), 10000);
        $display("%0d cycles, %0d beats (%0d from s0, %0d from s1), %0d frames, %0d errors",
                 cycles, beats, s0_beats, s1_beats, frames, errors);
        if (errors == 0 && beats > 100000) $display("AXIS_PKT_ARB PASS");
        else $display("AXIS_PKT_ARB FAIL");
        $finish;
    end
endmodule
