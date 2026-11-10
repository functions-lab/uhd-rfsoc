// One lane, one tap of dpd_mpl_core: u = g * x (exact, 35 bit), 2 cascaded DSPs per rail, every
// operand through an input register of its own (DSP A/B registers).
// g_* and x*1 at stage 16, x*2 at stage 17; u valid at stage 20.
module dpd_cmul (
    input  logic               clk,
    input  logic signed [17:0] g_re, g_im,
    input  logic signed [15:0] xi1, xq1,
    input  logic signed [15:0] xi2, xq2,
    output logic signed [34:0] u_re, u_im
);
  logic signed [17:0] gra, grb, gi, gia, gib;
  logic signed [15:0] xi1r, xq1r, xi2r, xq2r;
  logic signed [33:0] m1r, m1i, m2r, m2i;
  logic signed [34:0] p1r, p1i;
  always_ff @(posedge clk) begin
    gra   <= g_re;                       // stage 17
    grb   <= g_re;
    gi    <= g_im;
    xi1r  <= xi1;
    xq1r  <= xq1;
    m1r   <= gra * xi1r;                 // stage 18
    m1i   <= grb * xq1r;
    gia   <= gi;
    gib   <= gi;
    xq2r  <= xq2;
    xi2r  <= xi2;
    p1r   <= 35'(m1r);                   // stage 19
    p1i   <= 35'(m1i);
    m2r   <= gia * xq2r;                 // stage 19
    m2i   <= gib * xi2r;
    u_re  <= p1r - 35'(m2r);             // stage 20
    u_im  <= p1i + 35'(m2i);
  end
endmodule
