// One lane, one tap, one rail of dpd_mpl_core: acc = kc + sum_n a[n]*b[n] through an NPROD-deep
// MAC chain, then g = sat18(acc >> 23). Caller aligns b[n] to stage S+n and loads a[n] (operand
// register) at the edge the slot leaves stage S+n; kc is read at stage S+2. b[n] passes an input
// register of its own (DSP B register) before its multiplier. Output g valid at stage
// S+NPROD+3 (= 16 for the core).
module dpd_gain_mac #(
    parameter int NPROD = 5
) (
    input  logic                              clk,
    input  logic signed [NPROD-1:0][26:0]     a,
    input  logic        [NPROD-1:0][16:0]     b,
    input  logic signed [47:0]                kc,
    output logic signed [17:0]                g,
    output logic                              satg
);
  logic signed [44:0] m[NPROD];
  logic signed [47:0] p[NPROD];
  logic signed [26:0] as[NPROD];
  logic signed [17:0] br[NPROD];

  for (genvar n = 0; n < NPROD; n++) begin : g_op
    assign as[n] = a[n];
  end

  always_ff @(posedge clk) begin
    for (int n = 0; n < NPROD; n++) br[n] <= {1'b0, b[n]};
    for (int n = 0; n < NPROD; n++) m[n] <= as[n] * br[n];
    p[0] <= 48'(m[0]) + kc;
    for (int n = 1; n < NPROD; n++) p[n] <= 48'(m[n]) + p[n-1];
  end

  logic signed [24:0] sh;
  assign sh = p[NPROD-1][47:23];
  always_ff @(posedge clk) begin
    satg <= (sh[24:17] != {8{sh[17]}});
    g    <= (sh[24:17] == {8{sh[17]}}) ? sh[17:0] : (sh[24] ? 18'sh20000 : 18'sh1FFFF);
  end
endmodule
