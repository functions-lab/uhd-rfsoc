// dpd_mpl_core: one channel of tx_dpd.v, SSR lanes (1, 2, 4 or 8 samples per clock) of the
// MPL-4x4 DPD (memory polynomial, taps m = 0..3, odd orders 1/3/5/7, lag terms on taps 0 and 1),
// fixed latency 32 clocks. The arithmetic is bit-exact to dpd_fx() in rfsoc/rfsoc_lib/dsp/dpd.py
// (the reference the sims, the daemon and the host tool share).
// Stage numbering: in_reg = stage 1; the beat captured at edge k is on m_axis after edge k+31
// (stage 32).
//
//   stage  1        in_reg (zeroed when the slot is not accepted)
//   2..12           basis e1 (valid 6), e2 (9), e3 (12)
//   8..15           per-tap MAC chains (5 or 3 DSPs) -> acc at 15
//   16              g = sat18(acc >> 23)
//   17..20          g * x (cascaded DSPs) -> u at 20
//   21, 22          tap routing across beats + 2-level exact sum -> z
//   23, 24          round (+2^14) then saturate to 16 bit -> y
//   25              bypass / DPD mux, invalid-slot zeroing
//   26..32          SRL delay to the output register
// Every DSP multiplier takes its operands from registers of its own (A/B
// registers): no fabric or DSP output reaches a multiplier in one cycle.
module dpd_mpl_core #(
    parameter int SSR = 4
) (
    input  logic          aclk,
    input  logic          aresetn,
    input  logic [32*SSR-1:0] s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tlast,
    output logic [32*SSR-1:0] m_axis_tdata,
    output logic          m_axis_tvalid,
    input  logic          m_axis_tready,
    output logic          m_axis_tlast,
    input  logic [1079:0] coef_next,
    input  logic          coef_commit,
    input  logic          bypass,
    output logic [1079:0] coef_active,
    output logic          bypass_out,
    output logic [4:0]    sat_out_inc,    // saturated output rails this beat (<= 2*SSR)
    output logic [6:0]    sat_gain_inc,   // saturated gains this beat (<= 8*SSR)
    output logic [15:0]   in_absmax,
    output logic [15:0]   out_absmax
);
  // ---------------------------------------------------------------- stage 1 and control pipes
  localparam int W  = 32 * SSR;
  localparam int HD = (3 + SSR - 1) / SSR;  // product history depth in beats (memory taps m <= 3)
  if (SSR != 1 && SSR != 2 && SSR != 4 && SSR != 8) begin : g_bad_ssr
    $error("dpd_mpl_core: illegal SSR=%0d", SSR);
  end
  assign s_axis_tready = m_axis_tready;
  logic acc;
  assign acc = s_axis_tvalid & m_axis_tready;

  logic [32:1]  vp, lp, bp;  // valid, last, bypass: index = stage
  logic [W-1:0] xin;         // in_reg
  logic [W-1:0] xd[2:24];    // x delayed to stage s

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      vp  <= '0;
      lp  <= '0;
      bp  <= '0;
      xin <= '0;
    end else begin
      vp  <= {vp[31:1], acc};
      lp  <= {lp[31:1], s_axis_tlast & acc};
      bp  <= {bp[31:1], bypass};
      xin <= acc ? s_axis_tdata : '0;
    end
  end

  always_ff @(posedge aclk) begin
    xd[2] <= xin;
    for (int s = 3; s <= 24; s++) xd[s] <= xd[s-1];
  end

  // ---------------------------------------------------------------- coefficient bank
  logic signed [3:0][1:0][4:0][26:0] a_op;
  logic signed [3:0][1:0][47:0]      kc_op;
  dpd_coef_bank u_bank (
      .clk        (aclk),
      .aresetn    (aresetn),
      .coef_next  (coef_next),
      .coef_commit(coef_commit),
      .coef_active(coef_active),
      .a_op       (a_op),
      .kc_op      (kc_op)
  );

  // ---------------------------------------------------------------- basis
  logic [16:0] e1_0[SSR], e1_2[SSR], e1_3[SSR], e1_4[SSR], e2_1[SSR], e2_2[SSR], e2_3[SSR], e3[SSR];
  for (genvar k = 0; k < SSR; k++) begin : g_basis
    dpd_basis u_basis (
        .clk (aclk),
        .i_in(xin[32*k+:16]),
        .q_in(xin[32*k+16+:16]),
        .e1_0(e1_0[k]), .e1_2(e1_2[k]), .e1_3(e1_3[k]), .e1_4(e1_4[k]),
        .e2_1(e2_1[k]), .e2_2(e2_2[k]), .e2_3(e2_3[k]),
        .e3  (e3[k])
    );
  end

  // ---------------------------------------------------------------- gains
  logic signed [17:0] g[SSR][4][2];
  logic               sg[SSR][4][2];
  for (genvar k = 0; k < SSR; k++) begin : g_lane
    // lag operand (sample s-1): lane k-1 of this slot, or the last lane of the previous slot, which
    // sits one stage further along in the pipeline.
    logic [16:0] lag_e1, lag_e2;
    if (k == 0) begin : g_lag0
      assign lag_e1 = e1_4[SSR-1];
      assign lag_e2 = e2_3[SSR-1];
    end else begin : g_lagk
      assign lag_e1 = e1_3[k-1];
      assign lag_e2 = e2_2[k-1];
    end
    for (genvar m = 0; m < 4; m++) begin : g_tap
      for (genvar r = 0; r < 2; r++) begin : g_rail
        if (m < 2) begin : g_five
          dpd_gain_mac #(.NPROD(5)) u_mac (
              .clk (aclk),
              .a   (a_op[m][r]),
              .b   ({e3[k], lag_e2, e2_1[k], lag_e1, e1_2[k]}),
              .kc  (kc_op[m][r]),
              .g   (g[k][m][r]),
              .satg(sg[k][m][r])
          );
        end else begin : g_three
          dpd_gain_mac #(.NPROD(3)) u_mac (
              .clk (aclk),
              .a   (a_op[m][r][2:0]),
              .b   ({e3[k], e2_2[k], e1_4[k]}),
              .kc  (kc_op[m][r]),
              .g   (g[k][m][r]),
              .satg(sg[k][m][r])
          );
        end
      end
    end
  end

  // ---------------------------------------------------------------- complex multiplies
  logic signed [34:0] uu[2][SSR][4];  // [rail][lane][tap], stage 20
  logic signed [34:0] uh[1:HD][2][SSR][4];  // products of the previous HD slots (uh[d] = d slots back)
  for (genvar k = 0; k < SSR; k++) begin : g_cm_lane
    for (genvar m = 0; m < 4; m++) begin : g_cm_tap
      dpd_cmul u_cmul (
          .clk (aclk),
          .g_re(g[k][m][0]),
          .g_im(g[k][m][1]),
          .xi1 (xd[16][32*k+:16]),
          .xq1 (xd[16][32*k+16+:16]),
          .xi2 (xd[17][32*k+:16]),
          .xq2 (xd[17][32*k+16+:16]),
          .u_re(uu[0][k][m]),
          .u_im(uu[1][k][m])
      );
    end
  end
  always_ff @(posedge aclk) begin
    for (int r = 0; r < 2; r++)
      for (int k = 0; k < SSR; k++)
        for (int m = 0; m < 4; m++) begin
          uh[1][r][k][m] <= uu[r][k][m];
          for (int d = 2; d <= HD; d++) uh[d][r][k][m] <= uh[d-1][r][k][m];
        end
  end

  // ---------------------------------------------------------------- tap routing, sum, round
  logic signed [37:0] sa[2][SSR], sb[2][SSR], z[2][SSR], zr[2][SSR];
  logic signed [15:0] y[2][SSR];
  logic               so[2][SSR];  // output saturation flags, stage 24
  for (genvar r = 0; r < 2; r++) begin : g_sum_rail
    for (genvar k = 0; k < SSR; k++) begin : g_sum_lane
      // Output sample n = SSR*t + k takes u_m of sample n-m: P = k - m lanes back, which is D whole
      // slots back and source lane L. 
      logic signed [34:0] src[4];
      for (genvar m = 0; m < 4; m++) begin : g_src
        localparam int P = k - m;
        localparam int D = (P >= 0) ? 0 : ((-P + SSR - 1) / SSR);
        localparam int L = P + D * SSR;
        if (D == 0) begin : g_cur
          assign src[m] = uu[r][L][m];
        end else begin : g_prev
          assign src[m] = uh[D][r][L][m];
        end
      end
      logic signed [22:0] sh;
      assign sh = zr[r][k][37:15];
      always_ff @(posedge aclk) begin
        sa[r][k] <= 38'(src[0]) + 38'(src[1]);  // stage 21
        sb[r][k] <= 38'(src[2]) + 38'(src[3]);
        z[r][k]  <= sa[r][k] + sb[r][k];        // stage 22
        zr[r][k] <= z[r][k] + 38'sd16384;       // stage 23
        so[r][k] <= (sh[22:15] != {8{sh[15]}}); // stage 24
        y[r][k]  <= (sh[22:15] == {8{sh[15]}}) ? sh[15:0] : (sh[22] ? 16'sh8000 : 16'sh7FFF);
      end
    end
  end

  // ---------------------------------------------------------------- bypass mux (stage 25)
  logic [W-1:0] mux25;
  always_ff @(posedge aclk) begin
    for (int k = 0; k < SSR; k++) begin
      mux25[32*k+:32] <= !vp[24] ? 32'd0 :
                         bp[24]  ? xd[24][32*k+:32] : {y[1][k], y[0][k]};
    end
  end

  // ---------------------------------------------------------------- statistics
  // sat_gain: flags at stage 16 -> per-lane counts (17) -> total gated by valid (18)
  logic [3:0] sgl[SSR];
  logic [6:0] sgt;
  always_ff @(posedge aclk) begin
    for (int k = 0; k < SSR; k++) begin
      logic [3:0] c;
      c = '0;
      for (int m = 0; m < 4; m++) c = c + 4'(sg[k][m][0]) + 4'(sg[k][m][1]);
      sgl[k] <= c;
    end
    begin
      logic [6:0] t;
      t = '0;
      for (int k = 0; k < SSR; k++) t = t + 7'(sgl[k]);
      sgt <= vp[17] ? t : 7'd0;
    end
  end

  // sat_out: flags at stage 24 -> count gated by valid (25)
  logic [4:0] sot;
  always_ff @(posedge aclk) begin
    logic [4:0] c;
    c = '0;
    for (int k = 0; k < SSR; k++) c = c + 5'(so[0][k]) + 5'(so[1][k]);
    sot <= vp[24] ? c : 5'd0;
  end

  logic [15:0] in_am, out_am;
  dpd_absmax #(.NL(SSR)) u_in_am (.clk(aclk), .d(xin), .q(in_am));        // stage 6
  dpd_absmax #(.NL(SSR)) u_out_am (.clk(aclk), .d(mux25), .q(out_am));    // stage 30

  // ---------------------------------------------------------------- delay to stage 32
  dpd_delay #(.W(W), .N(7))   u_dly_data (.clk(aclk), .d(mux25), .q(m_axis_tdata));
  dpd_delay #(.W(5),   .N(7))  u_dly_so   (.clk(aclk), .d(sot),   .q(sat_out_inc));
  dpd_delay #(.W(7),   .N(14)) u_dly_sg   (.clk(aclk), .d(sgt),   .q(sat_gain_inc));
  dpd_delay #(.W(16),  .N(26)) u_dly_ia   (.clk(aclk), .d(in_am), .q(in_absmax));
  dpd_delay #(.W(16),  .N(2))  u_dly_oa   (.clk(aclk), .d(out_am), .q(out_absmax));

  assign m_axis_tvalid = vp[32];
  assign m_axis_tlast  = lp[32];
  assign bypass_out    = bp[32];
endmodule
