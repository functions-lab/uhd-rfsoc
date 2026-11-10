// One lane of the |x|^2 basis of dpd_mpl_core (stage numbers: in_reg = stage 1).
//   e1 = min((I*I+Q*Q)>>14, 131071)  valid at stage 6
//   e2 = (e1*e1)>>17                 valid at stage 9
//   e3 = (e2*e1)>>17                 valid at stage 12
// e?_d = e? delayed d clocks (same sample, later stage). Every multiplier
// takes its operands from registers of its own (DSP A/B registers).
module dpd_basis (
    input  logic                clk,
    input  logic signed [15:0]  i_in,
    input  logic signed [15:0]  q_in,
    output logic        [16:0]  e1_0, e1_2, e1_3, e1_4,
    output logic        [16:0]  e2_1, e2_2, e2_3,
    output logic        [16:0]  e3
);
  // e1: two DSP squares, the second one adds the first.
  logic signed [15:0] ir, qr, qr2;
  logic signed [31:0] mi, mq, p1;
  logic signed [32:0] s;
  logic        [16:0] e1_1;
  always_ff @(posedge clk) begin
    ir   <= i_in;              // stage 2
    qr   <= q_in;
    mi   <= ir * ir;           // stage 3
    qr2  <= qr;
    p1   <= mi;                // stage 4
    mq   <= qr2 * qr2;         // stage 4
    s    <= 33'(mq) + 33'(p1); // stage 5
    e1_0 <= s[31] ? 17'h1FFFF : s[30:14];  // stage 6 (only s == 2^31 reaches bit 31)
    e1_1 <= e1_0;
    e1_2 <= e1_1;
    e1_3 <= e1_2;
    e1_4 <= e1_3;
  end

  // e2
  logic signed [17:0] e1m;
  logic signed [35:0] m2, p2;
  logic        [16:0] e2_0;
  always_ff @(posedge clk) begin
    e1m <= {1'b0, e1_0};       // stage 7
    m2  <= e1m * e1m;          // stage 8
    p2  <= m2;                 // stage 9
  end
  assign e2_0 = p2[33:17];
  always_ff @(posedge clk) begin
    e2_1 <= e2_0;
    e2_2 <= e2_1;
    e2_3 <= e2_2;
  end

  // e3
  logic signed [17:0] e2m, e1m3;
  logic signed [35:0] m3, p3;
  always_ff @(posedge clk) begin
    e2m  <= {1'b0, e2_0};      // stage 10
    e1m3 <= {1'b0, e1_3};
    m3   <= e2m * e1m3;        // stage 11
    p3   <= m3;                // stage 12
  end
  assign e3 = p3[33:17];
endmodule
