`timescale 1 ns / 1 ps

module dual_channel_rf_adc_iq_packer_tb;
  reg clk = 1'b0;
  reg resetn = 1'b0;
  reg [31:0] ch0_i = 32'h0002_0001;
  reg [31:0] ch0_q = 32'h1002_1001;
  reg [31:0] ch1_i = 32'h2002_2001;
  reg [31:0] ch1_q = 32'h3002_3001;
  reg ch0_i_valid = 1'b0, ch0_q_valid = 1'b0;
  reg ch1_i_valid = 1'b0, ch1_q_valid = 1'b0;
  reg ready = 1'b0;
  wire [127:0] packed_data;
  wire packed_valid;
  wire ch0_i_ready, ch0_q_ready, ch1_i_ready, ch1_q_ready;

  always #2 clk = ~clk;

  dual_channel_rf_adc_iq_packer_v1_0 dut (
      .axis_aclk(clk), .axis_aresetn(resetn),
      .s_ch0_i_axis_tdata(ch0_i), .s_ch0_i_axis_tvalid(ch0_i_valid), .s_ch0_i_axis_tready(ch0_i_ready),
      .s_ch0_q_axis_tdata(ch0_q), .s_ch0_q_axis_tvalid(ch0_q_valid), .s_ch0_q_axis_tready(ch0_q_ready),
      .s_ch1_i_axis_tdata(ch1_i), .s_ch1_i_axis_tvalid(ch1_i_valid), .s_ch1_i_axis_tready(ch1_i_ready),
      .s_ch1_q_axis_tdata(ch1_q), .s_ch1_q_axis_tvalid(ch1_q_valid), .s_ch1_q_axis_tready(ch1_q_ready),
      .m_axis_tdata(packed_data), .m_axis_tvalid(packed_valid), .m_axis_tready(ready));

  initial begin
    #1;
    if ({ch1_q_ready, ch1_i_ready, ch0_q_ready, ch0_i_ready} !== 4'b1111)
      $fatal(1, "input TREADY outputs are not tied high");
    if (packed_valid !== 1'b1)
      $fatal(1, "output TVALID is not tied high");
    if (packed_data !== {
        16'h3002,16'h2002,16'h3001,16'h2001,
        16'h1002,16'h0002,16'h1001,16'h0001})
      $fatal(1, "initial reshuffle incorrect: %h", packed_data);

    // TVALID, TREADY, clock, and reset must not gate or retain the data path.
    resetn = 1'b1;
    ch0_i_valid = 1'b1;
    ch1_q_valid = 1'b1;
    ch0_i = 32'h0102_0101;
    ch0_q = 32'h1102_1101;
    ch1_i = 32'h2102_2101;
    ch1_q = 32'h3102_3101;
    #1;
    if (packed_valid !== 1'b1)
      $fatal(1, "output TVALID changed with handshake inputs");
    if (packed_data !== {
        16'h3102,16'h2102,16'h3101,16'h2101,
        16'h1102,16'h0102,16'h1101,16'h0101})
      $fatal(1, "updated reshuffle incorrect: %h", packed_data);

    ready = 1'b1;
    ch0_i_valid = 1'b0;
    ch0_q_valid = 1'b1;
    ch1_i_valid = 1'b1;
    ch1_q_valid = 1'b0;
    #1;
    if ({packed_valid, ch1_q_ready, ch1_i_ready,
         ch0_q_ready, ch0_i_ready} !== 5'b11111)
      $fatal(1, "handshake outputs are not permanently high");

    $display("PASS: stateless IQ reshuffle; TREADY and TVALID permanently high");
    $finish;
  end
endmodule
