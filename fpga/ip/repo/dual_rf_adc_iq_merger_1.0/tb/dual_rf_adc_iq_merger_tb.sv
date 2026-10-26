`timescale 1 ns / 1 ps

module dual_rf_adc_iq_merger_checker #(
    parameter integer C_S_AXIS_TDATA_WIDTH = 64,
    parameter integer CHECKER_ID = 0
) (
    input  wire clk,
    output reg  done
);
  localparam integer SAMPLE_COUNT = C_S_AXIS_TDATA_WIDTH / 16;

  reg rstn = 1'b0;
  reg [C_S_AXIS_TDATA_WIDTH-1:0] i_data = {C_S_AXIS_TDATA_WIDTH{1'b0}};
  reg i_valid = 1'b0;
  wire i_ready;
  reg [C_S_AXIS_TDATA_WIDTH-1:0] q_data = {C_S_AXIS_TDATA_WIDTH{1'b0}};
  reg q_valid = 1'b0;
  wire q_ready;
  wire [(2*C_S_AXIS_TDATA_WIDTH)-1:0] out_data;
  wire out_valid;
  reg out_ready = 1'b0;
  reg [(2*C_S_AXIS_TDATA_WIDTH)-1:0] expected;
  integer sample_index;

  dual_rf_adc_iq_merger_v1_0 #(
      .C_S_AXIS_TDATA_WIDTH(C_S_AXIS_TDATA_WIDTH)
  ) dut (
      .axis_aclk(clk), .axis_aresetn(rstn),
      .s_i_axis_tdata(i_data), .s_i_axis_tvalid(i_valid), .s_i_axis_tready(i_ready),
      .s_q_axis_tdata(q_data), .s_q_axis_tvalid(q_valid), .s_q_axis_tready(q_ready),
      .m_axis_tdata(out_data), .m_axis_tvalid(out_valid), .m_axis_tready(out_ready)
  );

  task load_samples;
    input [15:0] i_base;
    input [15:0] q_base;
    begin
      for (sample_index = 0; sample_index < SAMPLE_COUNT; sample_index = sample_index + 1) begin
        i_data[sample_index*16 +: 16] = i_base + sample_index;
        q_data[sample_index*16 +: 16] = q_base + sample_index;
        expected[(2*sample_index)*16 +: 16] = i_base + sample_index;
        expected[(2*sample_index+1)*16 +: 16] = q_base + sample_index;
      end
    end
  endtask

  initial begin
    done = 1'b0;
    if (C_S_AXIS_TDATA_WIDTH != 32 && C_S_AXIS_TDATA_WIDTH != 64 &&
        C_S_AXIS_TDATA_WIDTH != 128 && C_S_AXIS_TDATA_WIDTH != 256 &&
        C_S_AXIS_TDATA_WIDTH != 512 && C_S_AXIS_TDATA_WIDTH != 1024)
      $fatal(1, "checker %0d was instantiated with unsupported width %0d",
             CHECKER_ID, C_S_AXIS_TDATA_WIDTH);

    repeat (3) @(posedge clk);
    rstn = 1'b1;
    out_ready = 1'b1;
    #1;
    if (i_ready !== 1'b1 || q_ready !== 1'b1)
      $fatal(1, "width %0d: RFDC inputs must never be backpressured",
             C_S_AXIS_TDATA_WIDTH);

    // Simultaneous I and Q words are interleaved, lane zero in the LSBs.
    load_samples(16'h1001, 16'h4001);
    i_valid = 1'b1;
    q_valid = 1'b1;
    #1;
    if (out_valid !== 1'b1 || out_data !== expected)
      $fatal(1, "width %0d: interleave mapping failed", C_S_AXIS_TDATA_WIDTH);

    // A lone valid is never emitted or retained for later pairing.
    i_valid = 1'b0;
    #1;
    if (out_valid !== 1'b0)
      $fatal(1, "width %0d: lone Q valid was emitted", C_S_AXIS_TDATA_WIDTH);

    // Stalled samples are accepted from the converter and deliberately dropped.
    i_valid = 1'b1;
    out_ready = 1'b0;
    load_samples(16'h2001, 16'h8001);
    #1;
    if (out_valid !== 1'b0 || i_ready !== 1'b1 || q_ready !== 1'b1)
      $fatal(1, "width %0d: stall behavior failed", C_S_AXIS_TDATA_WIDTH);

    // Readiness exposes only the current converter word, never the dropped one.
    load_samples(16'h3001, 16'h9001);
    out_ready = 1'b1;
    #1;
    if (out_valid !== 1'b1 || out_data !== expected)
      $fatal(1, "width %0d: post-stall current sample failed",
             C_S_AXIS_TDATA_WIDTH);

    i_valid = 1'b0;
    q_valid = 1'b0;
    done = 1'b1;
    $display("DUAL_RF_ADC_IQ_MERGER width=%0d samples=%0d PASS",
             C_S_AXIS_TDATA_WIDTH, SAMPLE_COUNT);
  end
endmodule

module dual_rf_adc_iq_merger_tb;
  reg clk = 1'b0;
  wire [5:0] done;

  always #5 clk = ~clk;

  dual_rf_adc_iq_merger_checker #(.C_S_AXIS_TDATA_WIDTH(32),   .CHECKER_ID(0)) c32   (.clk(clk), .done(done[0]));
  dual_rf_adc_iq_merger_checker #(.C_S_AXIS_TDATA_WIDTH(64),   .CHECKER_ID(1)) c64   (.clk(clk), .done(done[1]));
  dual_rf_adc_iq_merger_checker #(.C_S_AXIS_TDATA_WIDTH(128),  .CHECKER_ID(2)) c128  (.clk(clk), .done(done[2]));
  dual_rf_adc_iq_merger_checker #(.C_S_AXIS_TDATA_WIDTH(256),  .CHECKER_ID(3)) c256  (.clk(clk), .done(done[3]));
  dual_rf_adc_iq_merger_checker #(.C_S_AXIS_TDATA_WIDTH(512),  .CHECKER_ID(4)) c512  (.clk(clk), .done(done[4]));
  dual_rf_adc_iq_merger_checker #(.C_S_AXIS_TDATA_WIDTH(1024), .CHECKER_ID(5)) c1024 (.clk(clk), .done(done[5]));

  initial begin
    wait (&done);
    $display("DUAL_RF_ADC_IQ_MERGER_TB ALL WIDTHS PASS");
    $finish;
  end

  initial begin
    #1000;
    $fatal(1, "timeout waiting for width checkers: done=%b", done);
  end
endmodule
