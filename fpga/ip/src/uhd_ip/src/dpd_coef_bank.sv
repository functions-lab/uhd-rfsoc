// Coefficient active bank of dpd_mpl_core with exact-slot commit; a reset loads the identity set
// (a_{0,0} = 1.0, every other coefficient 0) whatever coef_next holds.
// coef_pend is captured at the edge where coef_commit is sampled. Each operand register is
// loaded from coef_pend at the edge where the committing slot enters the stage that feeds it, so
// the committing slot and all later slots see the new set in every term.
module dpd_coef_bank (
    input  logic                              clk,
    input  logic                              aresetn,
    input  logic [1079:0]                     coef_next,
    input  logic                              coef_commit,
    output logic [1079:0]                     coef_active,
    // [tap m][rail r][product n]; chain order per tap (see dpd_mpl_core)
    output logic signed [3:0][1:0][4:0][26:0] a_op,
    output logic signed [3:0][1:0][47:0]      kc_op
);
  localparam logic [1079:0] IDENT = 1080'(1) << 21;  // a_{0,0} = 1.0 (Q6.21), real rail
  logic [1079:0] pend;
  logic [12:1]   cf;  // commit flag travelling with the slot (stage index)
  always_ff @(posedge clk) begin
    if (!aresetn) pend <= IDENT;
    else if (coef_commit) pend <= coef_next;
    cf <= {cf[11:1], aresetn & coef_commit};
  end
  assign coef_active = pend;

  function automatic logic signed [26:0] rail(input logic [1079:0] bus, input int i, input int r);
    return bus[54*i+27*r+:27];
  endfunction
  function automatic logic signed [47:0] kconst(input logic signed [26:0] c0);
    return (48'(c0) <<< 17) + 48'sd4194304;
  endfunction

  for (genvar m = 0; m < 4; m++) begin : g_tap
    localparam int NP = (m < 2) ? 5 : 3;
    localparam int S = (m < 2) ? 8 : 10;  // stage of the first multiplier operand
    for (genvar r = 0; r < 2; r++) begin : g_rail
      // C-port constant, read at stage S+2
      logic signed [47:0] kc;
      always_ff @(posedge clk) begin
        if (!aresetn) kc <= kconst(rail(IDENT, 4 * m, r));
        else if (cf[S+1]) kc <= kconst(rail(pend, 4 * m, r));
      end
      assign kc_op[m][r] = kc;

      for (genvar n = 0; n < 5; n++) begin : g_n
        if (n < NP) begin : g_used
          // coefficient index of product n
          localparam int IDX = (m < 2) ? ((n == 0) ? 4 * m + 1 :
                                          (n == 1) ? 16 + 2 * m :
                                          (n == 2) ? 4 * m + 2 :
                                          (n == 3) ? 17 + 2 * m : 4 * m + 3)
                                       : 4 * m + 1 + n;
          logic signed [26:0] op;
          always_ff @(posedge clk) begin
            if (!aresetn) op <= rail(IDENT, IDX, r);
            else if (cf[S+n]) op <= rail(pend, IDX, r);
          end
          assign a_op[m][r][n] = op;
        end else begin : g_unused
          assign a_op[m][r][n] = '0;
        end
      end
    end
  end
endmodule
