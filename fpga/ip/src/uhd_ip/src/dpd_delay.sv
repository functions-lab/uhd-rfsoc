// Plain N-stage delay line, no reset (infers SRL).
module dpd_delay #(
    parameter int W = 1,
    parameter int N = 1
) (
    input  logic         clk,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
  if (N == 0) begin : g_wire
    assign q = d;
  end else begin : g_sr
    (* shreg_extract = "yes" *) logic [W-1:0] sr[N];
    always_ff @(posedge clk) begin
      sr[0] <= d;
      for (int i = 1; i < N; i++) sr[i] <= sr[i-1];
    end
    assign q = sr[N-1];
  end
endmodule
