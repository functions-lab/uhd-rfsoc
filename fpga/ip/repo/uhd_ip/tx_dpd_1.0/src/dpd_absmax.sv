// max(|I|,|Q|) over the NL (1, 2, 4 or 8) lanes of a beat; unused lanes are zero-padded to
// eight, so the latency is 5 clocks for every NL.
module dpd_absmax #(
    parameter int NL = 4
) (
    input  logic             clk,
    input  logic [32*NL-1:0] d,
    output logic [15:0]      q
);
  function automatic logic [15:0] absv(input logic signed [15:0] v);
    return v[15] ? 16'(-v) : 16'(v);
  endfunction
  function automatic logic [15:0] max2(input logic [15:0] a, input logic [15:0] b);
    return (a > b) ? a : b;
  endfunction

  logic [255:0] dp;
  assign dp = 256'(d);
  logic [15:0] a [16];
  logic [15:0] l1[8];
  logic [15:0] l2[4];
  logic [15:0] l3[2];

  always_ff @(posedge clk) begin
    for (int k = 0; k < 8; k++) begin
      a[2*k]   <= (k < NL) ? absv(dp[32*k+:16]) : 16'd0;
      a[2*k+1] <= (k < NL) ? absv(dp[32*k+16+:16]) : 16'd0;
    end
    for (int i = 0; i < 8; i++) l1[i] <= max2(a[2*i], a[2*i+1]);
    for (int i = 0; i < 4; i++) l2[i] <= max2(l1[2*i], l1[2*i+1]);
    for (int i = 0; i < 2; i++) l3[i] <= max2(l2[2*i], l2[2*i+1]);
    q <= max2(l3[0], l3[1]);
  end
endmodule
