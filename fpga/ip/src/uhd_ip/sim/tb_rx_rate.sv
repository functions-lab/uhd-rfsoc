// tb_rx_rate -- rx_rate + its FIR Compiler stages (sim/rate_fir_ip.tcl makes
// rfir_1 .. rfir_K) at every depth 0..K, one chain reset between depths.
// Writes rx_d<k>.txt per depth for check_rate.py rx:
//   I <lane> <v>   every input sample the chain took after the reset
//   O <lane> <v>   every output sample (m_axis beats)
// Lane 2c = I, 2c+1 = Q of channel c. Ends with ASSERT_RX_NO_STALL ok|FAIL and
// the alignment of the channels follows from the per-lane bit-exact check
// (check_rate.py: every lane against the model from the same first sample).
`timescale 1ns / 1ps
module tb_rx_rate #(parameter int N_CH = 1, parameter int SPC = 4, parameter int K = 5,
                    parameter int G = 1, parameter int NIN = 512);
    localparam int L = 2 * N_CH, BW = N_CH * SPC * 32;
    reg aclk = 0, s_axi_aclk = 0;
    always #5 aclk = ~aclk;
    always #3.5 s_axi_aclk = ~s_axi_aclk;
    reg aresetn = 0, s_axi_aresetn = 0;
    localparam int FI1 = ((SPC >> 1) > 1 ? (SPC >> 1) : 1) * (2 * N_CH / G) * 16, FO1 = FI1 / 16 * 40;
    wire [FI1-1:0] m_st1g0_tdata; wire m_st1g0_tvalid, m_st1g0_tready;
    wire [FO1-1:0] s_st1g0_tdata; wire s_st1g0_tvalid, s_st1g0_tready;
    wire [FI1-1:0] m_st1g1_tdata; wire m_st1g1_tvalid, m_st1g1_tready;
    wire [FO1-1:0] s_st1g1_tdata; wire s_st1g1_tvalid, s_st1g1_tready;
    localparam int FI2 = ((SPC >> 2) > 1 ? (SPC >> 2) : 1) * (2 * N_CH / G) * 16, FO2 = FI2 / 16 * 40;
    wire [FI2-1:0] m_st2g0_tdata; wire m_st2g0_tvalid, m_st2g0_tready;
    wire [FO2-1:0] s_st2g0_tdata; wire s_st2g0_tvalid, s_st2g0_tready;
    wire [FI2-1:0] m_st2g1_tdata; wire m_st2g1_tvalid, m_st2g1_tready;
    wire [FO2-1:0] s_st2g1_tdata; wire s_st2g1_tvalid, s_st2g1_tready;
    localparam int FI3 = ((SPC >> 3) > 1 ? (SPC >> 3) : 1) * (2 * N_CH / G) * 16, FO3 = FI3 / 16 * 40;
    wire [FI3-1:0] m_st3g0_tdata; wire m_st3g0_tvalid, m_st3g0_tready;
    wire [FO3-1:0] s_st3g0_tdata; wire s_st3g0_tvalid, s_st3g0_tready;
    wire [FI3-1:0] m_st3g1_tdata; wire m_st3g1_tvalid, m_st3g1_tready;
    wire [FO3-1:0] s_st3g1_tdata; wire s_st3g1_tvalid, s_st3g1_tready;
    localparam int FI4 = ((SPC >> 4) > 1 ? (SPC >> 4) : 1) * (2 * N_CH / G) * 16, FO4 = FI4 / 16 * 40;
    wire [FI4-1:0] m_st4g0_tdata; wire m_st4g0_tvalid, m_st4g0_tready;
    wire [FO4-1:0] s_st4g0_tdata; wire s_st4g0_tvalid, s_st4g0_tready;
    wire [FI4-1:0] m_st4g1_tdata; wire m_st4g1_tvalid, m_st4g1_tready;
    wire [FO4-1:0] s_st4g1_tdata; wire s_st4g1_tvalid, s_st4g1_tready;
    localparam int FI5 = ((SPC >> 5) > 1 ? (SPC >> 5) : 1) * (2 * N_CH / G) * 16, FO5 = FI5 / 16 * 40;
    wire [FI5-1:0] m_st5g0_tdata; wire m_st5g0_tvalid, m_st5g0_tready;
    wire [FO5-1:0] s_st5g0_tdata; wire s_st5g0_tvalid, s_st5g0_tready;
    wire [FI5-1:0] m_st5g1_tdata; wire m_st5g1_tvalid, m_st5g1_tready;
    wire [FO5-1:0] s_st5g1_tdata; wire s_st5g1_tvalid, s_st5g1_tready;
    localparam int FI6 = ((SPC >> 6) > 1 ? (SPC >> 6) : 1) * (2 * N_CH / G) * 16, FO6 = FI6 / 16 * 40;
    wire [FI6-1:0] m_st6g0_tdata; wire m_st6g0_tvalid, m_st6g0_tready;
    wire [FO6-1:0] s_st6g0_tdata; wire s_st6g0_tvalid, s_st6g0_tready;
    wire [FI6-1:0] m_st6g1_tdata; wire m_st6g1_tvalid, m_st6g1_tready;
    wire [FO6-1:0] s_st6g1_tdata; wire s_st6g1_tvalid, s_st6g1_tready;
    reg  [BW-1:0] s_tdata = '0; reg s_tvalid = 0;
    wire [BW-1:0] m_tdata; wire m_tvalid;
    wire [3:0] depth_o; wire fir_rstn;
    reg  [15:0] awaddr = 0, araddr = 0; reg [31:0] wdata = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0, bready = 1, rready = 1;
    wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata; wire [1:0] bresp, rresp;
    rx_rate #(.N_CH(N_CH), .SPC(SPC), .K(K), .G(G)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(1'b1),
        .m_st1g0_tdata(m_st1g0_tdata), .m_st1g0_tvalid(m_st1g0_tvalid), .m_st1g0_tready(m_st1g0_tready),
        .s_st1g0_tdata(s_st1g0_tdata), .s_st1g0_tvalid(s_st1g0_tvalid), .s_st1g0_tready(s_st1g0_tready),
        .m_st1g1_tdata(m_st1g1_tdata), .m_st1g1_tvalid(m_st1g1_tvalid), .m_st1g1_tready(m_st1g1_tready),
        .s_st1g1_tdata(s_st1g1_tdata), .s_st1g1_tvalid(s_st1g1_tvalid), .s_st1g1_tready(s_st1g1_tready),
        .m_st2g0_tdata(m_st2g0_tdata), .m_st2g0_tvalid(m_st2g0_tvalid), .m_st2g0_tready(m_st2g0_tready),
        .s_st2g0_tdata(s_st2g0_tdata), .s_st2g0_tvalid(s_st2g0_tvalid), .s_st2g0_tready(s_st2g0_tready),
        .m_st2g1_tdata(m_st2g1_tdata), .m_st2g1_tvalid(m_st2g1_tvalid), .m_st2g1_tready(m_st2g1_tready),
        .s_st2g1_tdata(s_st2g1_tdata), .s_st2g1_tvalid(s_st2g1_tvalid), .s_st2g1_tready(s_st2g1_tready),
        .m_st3g0_tdata(m_st3g0_tdata), .m_st3g0_tvalid(m_st3g0_tvalid), .m_st3g0_tready(m_st3g0_tready),
        .s_st3g0_tdata(s_st3g0_tdata), .s_st3g0_tvalid(s_st3g0_tvalid), .s_st3g0_tready(s_st3g0_tready),
        .m_st3g1_tdata(m_st3g1_tdata), .m_st3g1_tvalid(m_st3g1_tvalid), .m_st3g1_tready(m_st3g1_tready),
        .s_st3g1_tdata(s_st3g1_tdata), .s_st3g1_tvalid(s_st3g1_tvalid), .s_st3g1_tready(s_st3g1_tready),
        .m_st4g0_tdata(m_st4g0_tdata), .m_st4g0_tvalid(m_st4g0_tvalid), .m_st4g0_tready(m_st4g0_tready),
        .s_st4g0_tdata(s_st4g0_tdata), .s_st4g0_tvalid(s_st4g0_tvalid), .s_st4g0_tready(s_st4g0_tready),
        .m_st4g1_tdata(m_st4g1_tdata), .m_st4g1_tvalid(m_st4g1_tvalid), .m_st4g1_tready(m_st4g1_tready),
        .s_st4g1_tdata(s_st4g1_tdata), .s_st4g1_tvalid(s_st4g1_tvalid), .s_st4g1_tready(s_st4g1_tready),
        .m_st5g0_tdata(m_st5g0_tdata), .m_st5g0_tvalid(m_st5g0_tvalid), .m_st5g0_tready(m_st5g0_tready),
        .s_st5g0_tdata(s_st5g0_tdata), .s_st5g0_tvalid(s_st5g0_tvalid), .s_st5g0_tready(s_st5g0_tready),
        .m_st5g1_tdata(m_st5g1_tdata), .m_st5g1_tvalid(m_st5g1_tvalid), .m_st5g1_tready(m_st5g1_tready),
        .s_st5g1_tdata(s_st5g1_tdata), .s_st5g1_tvalid(s_st5g1_tvalid), .s_st5g1_tready(s_st5g1_tready),
        .m_st6g0_tdata(m_st6g0_tdata), .m_st6g0_tvalid(m_st6g0_tvalid), .m_st6g0_tready(m_st6g0_tready),
        .s_st6g0_tdata(s_st6g0_tdata), .s_st6g0_tvalid(s_st6g0_tvalid), .s_st6g0_tready(s_st6g0_tready),
        .m_st6g1_tdata(m_st6g1_tdata), .m_st6g1_tvalid(m_st6g1_tvalid), .m_st6g1_tready(m_st6g1_tready),
        .s_st6g1_tdata(s_st6g1_tdata), .s_st6g1_tvalid(s_st6g1_tvalid), .s_st6g1_tready(s_st6g1_tready),
        .depth_o(depth_o), .fir_aresetn_o(fir_rstn),
        .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));
    generate
        if (1 <= K && 0 < G) begin : g_f1_0
            rfir_1 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st1g0_tvalid), .s_axis_data_tready(m_st1g0_tready), .s_axis_data_tdata(m_st1g0_tdata),
                .m_axis_data_tvalid(s_st1g0_tvalid), .m_axis_data_tready(s_st1g0_tready), .m_axis_data_tdata(s_st1g0_tdata));
        end else begin : g_n1_0
            assign m_st1g0_tready = 1'b1; assign s_st1g0_tvalid = 1'b0; assign s_st1g0_tdata = '0;
        end
        if (1 <= K && 1 < G) begin : g_f1_1
            rfir_1 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st1g1_tvalid), .s_axis_data_tready(m_st1g1_tready), .s_axis_data_tdata(m_st1g1_tdata),
                .m_axis_data_tvalid(s_st1g1_tvalid), .m_axis_data_tready(s_st1g1_tready), .m_axis_data_tdata(s_st1g1_tdata));
        end else begin : g_n1_1
            assign m_st1g1_tready = 1'b1; assign s_st1g1_tvalid = 1'b0; assign s_st1g1_tdata = '0;
        end
        if (2 <= K && 0 < G) begin : g_f2_0
            rfir_2 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st2g0_tvalid), .s_axis_data_tready(m_st2g0_tready), .s_axis_data_tdata(m_st2g0_tdata),
                .m_axis_data_tvalid(s_st2g0_tvalid), .m_axis_data_tready(s_st2g0_tready), .m_axis_data_tdata(s_st2g0_tdata));
        end else begin : g_n2_0
            assign m_st2g0_tready = 1'b1; assign s_st2g0_tvalid = 1'b0; assign s_st2g0_tdata = '0;
        end
        if (2 <= K && 1 < G) begin : g_f2_1
            rfir_2 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st2g1_tvalid), .s_axis_data_tready(m_st2g1_tready), .s_axis_data_tdata(m_st2g1_tdata),
                .m_axis_data_tvalid(s_st2g1_tvalid), .m_axis_data_tready(s_st2g1_tready), .m_axis_data_tdata(s_st2g1_tdata));
        end else begin : g_n2_1
            assign m_st2g1_tready = 1'b1; assign s_st2g1_tvalid = 1'b0; assign s_st2g1_tdata = '0;
        end
        if (3 <= K && 0 < G) begin : g_f3_0
            rfir_3 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st3g0_tvalid), .s_axis_data_tready(m_st3g0_tready), .s_axis_data_tdata(m_st3g0_tdata),
                .m_axis_data_tvalid(s_st3g0_tvalid), .m_axis_data_tready(s_st3g0_tready), .m_axis_data_tdata(s_st3g0_tdata));
        end else begin : g_n3_0
            assign m_st3g0_tready = 1'b1; assign s_st3g0_tvalid = 1'b0; assign s_st3g0_tdata = '0;
        end
        if (3 <= K && 1 < G) begin : g_f3_1
            rfir_3 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st3g1_tvalid), .s_axis_data_tready(m_st3g1_tready), .s_axis_data_tdata(m_st3g1_tdata),
                .m_axis_data_tvalid(s_st3g1_tvalid), .m_axis_data_tready(s_st3g1_tready), .m_axis_data_tdata(s_st3g1_tdata));
        end else begin : g_n3_1
            assign m_st3g1_tready = 1'b1; assign s_st3g1_tvalid = 1'b0; assign s_st3g1_tdata = '0;
        end
        if (4 <= K && 0 < G) begin : g_f4_0
            rfir_4 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st4g0_tvalid), .s_axis_data_tready(m_st4g0_tready), .s_axis_data_tdata(m_st4g0_tdata),
                .m_axis_data_tvalid(s_st4g0_tvalid), .m_axis_data_tready(s_st4g0_tready), .m_axis_data_tdata(s_st4g0_tdata));
        end else begin : g_n4_0
            assign m_st4g0_tready = 1'b1; assign s_st4g0_tvalid = 1'b0; assign s_st4g0_tdata = '0;
        end
        if (4 <= K && 1 < G) begin : g_f4_1
            rfir_4 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st4g1_tvalid), .s_axis_data_tready(m_st4g1_tready), .s_axis_data_tdata(m_st4g1_tdata),
                .m_axis_data_tvalid(s_st4g1_tvalid), .m_axis_data_tready(s_st4g1_tready), .m_axis_data_tdata(s_st4g1_tdata));
        end else begin : g_n4_1
            assign m_st4g1_tready = 1'b1; assign s_st4g1_tvalid = 1'b0; assign s_st4g1_tdata = '0;
        end
        if (5 <= K && 0 < G) begin : g_f5_0
            rfir_5 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st5g0_tvalid), .s_axis_data_tready(m_st5g0_tready), .s_axis_data_tdata(m_st5g0_tdata),
                .m_axis_data_tvalid(s_st5g0_tvalid), .m_axis_data_tready(s_st5g0_tready), .m_axis_data_tdata(s_st5g0_tdata));
        end else begin : g_n5_0
            assign m_st5g0_tready = 1'b1; assign s_st5g0_tvalid = 1'b0; assign s_st5g0_tdata = '0;
        end
        if (5 <= K && 1 < G) begin : g_f5_1
            rfir_5 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st5g1_tvalid), .s_axis_data_tready(m_st5g1_tready), .s_axis_data_tdata(m_st5g1_tdata),
                .m_axis_data_tvalid(s_st5g1_tvalid), .m_axis_data_tready(s_st5g1_tready), .m_axis_data_tdata(s_st5g1_tdata));
        end else begin : g_n5_1
            assign m_st5g1_tready = 1'b1; assign s_st5g1_tvalid = 1'b0; assign s_st5g1_tdata = '0;
        end
        if (6 <= K && 0 < G) begin : g_f6_0
            rfir_6 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st6g0_tvalid), .s_axis_data_tready(m_st6g0_tready), .s_axis_data_tdata(m_st6g0_tdata),
                .m_axis_data_tvalid(s_st6g0_tvalid), .m_axis_data_tready(s_st6g0_tready), .m_axis_data_tdata(s_st6g0_tdata));
        end else begin : g_n6_0
            assign m_st6g0_tready = 1'b1; assign s_st6g0_tvalid = 1'b0; assign s_st6g0_tdata = '0;
        end
        if (6 <= K && 1 < G) begin : g_f6_1
            rfir_6 u (.aclk(aclk), .aresetn(fir_rstn),
                .s_axis_data_tvalid(m_st6g1_tvalid), .s_axis_data_tready(m_st6g1_tready), .s_axis_data_tdata(m_st6g1_tdata),
                .m_axis_data_tvalid(s_st6g1_tvalid), .m_axis_data_tready(s_st6g1_tready), .m_axis_data_tdata(s_st6g1_tdata));
        end else begin : g_n6_1
            assign m_st6g1_tready = 1'b1; assign s_st6g1_tvalid = 1'b0; assign s_st6g1_tdata = '0;
        end
    endgenerate

    task automatic axi_wr(input [15:0] a, input [31:0] d);
        @(posedge s_axi_aclk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        fork
            begin wait (awready); @(posedge s_axi_aclk); awvalid <= 0; end
            begin wait (wready);  @(posedge s_axi_aclk); wvalid  <= 0; end
        join
        wait (bvalid); @(posedge s_axi_aclk);
    endtask
    task automatic axi_rd(input [15:0] a, output [31:0] d);
        @(posedge s_axi_aclk); araddr <= a; arvalid <= 1;
        wait (arready); @(posedge s_axi_aclk); arvalid <= 0;
        wait (rvalid); d = rdata; @(posedge s_axi_aclk);
    endtask

    // ---- stimulus: per lane a tone (its own frequency and amplitude) plus a
    // little pseudo-noise; every 4096 samples 256 full-scale square samples;
    // one sample per lane per slot, the RF-ADC's every-cycle beat
    longint n = 0;                       // sample index of slot 0 of this beat
    int unsigned lfsr = 32'h1;
    function automatic logic [15:0] smp(input longint t, input int a);
        real v; int iv;
        if ((t % 4096) >= 3840) return (((t / 16) % 2) ? 16'h7FFF : 16'h8000) ^ (a[0] ? 16'hFFFF : 16'h0);
        v = (9000.0 + 2500.0 * a) * $sin(2.0 * 3.14159265358979 * (0.0013 + 0.0071 * a) * t)
          + 3000.0 * $sin(2.0 * 3.14159265358979 * (0.37 - 0.011 * a) * t);
        iv = $rtoi(v) + ((t * 2654435761 + a * 40503) % 257) - 128;
        if (iv > 32767) iv = 32767; if (iv < -32768) iv = -32768;
        return iv[15:0];
    endfunction
    always @(posedge aclk) begin
        s_tvalid <= aresetn;
        if (aresetn) begin
            for (int c = 0; c < N_CH; c++)
                for (int s = 0; s < SPC; s++) begin
                    s_tdata[32*(c*SPC+s) +: 16]      <= smp(n + s, 2*c);
                    s_tdata[32*(c*SPC+s) + 16 +: 16] <= smp(n + s, 2*c + 1);
                end
            n <= n + SPC;
        end
    end

    // ---- dumps
    int fd = 0, nin_d = 0, nout_d = 0, cur = -1;
    bit stall_seen = 0;
    always @(posedge aclk) begin
        if (fd != 0 && !dut.crst && s_tvalid && nin_d < NIN * (1 << cur)) begin
            for (int s = 0; s < SPC; s++)
                for (int c = 0; c < N_CH; c++) begin
                    $fwrite(fd, "I %0d %0d\n", 2*c,     $signed(s_tdata[32*(c*SPC+s) +: 16]));
                    $fwrite(fd, "I %0d %0d\n", 2*c + 1, $signed(s_tdata[32*(c*SPC+s) + 16 +: 16]));
                end
            nin_d <= nin_d + SPC;
        end
        if (fd != 0 && !dut.crst && m_tvalid) begin
            for (int s = 0; s < SPC; s++)
                for (int c = 0; c < N_CH; c++) begin
                    $fwrite(fd, "O %0d %0d\n", 2*c,     $signed(m_tdata[32*(c*SPC+s) +: 16]));
                    $fwrite(fd, "O %0d %0d\n", 2*c + 1, $signed(m_tdata[32*(c*SPC+s) + 16 +: 16]));
                end
            nout_d <= nout_d + SPC;
        end
        if (!dut.crst && (dut.stall_a || dut.ovf_a)) stall_seen <= 1;
    end

    reg [31:0] rd;
    initial begin
        repeat (5) @(posedge s_axi_aclk); s_axi_aresetn = 1; aresetn = 1;
        axi_rd(16'h00, rd); if (rd !== 32'h5A525431) $fatal(1, "ID %h", rd);
        axi_rd(16'h0C, rd); $display("INFO=%h", rd);
        if (rd[3:0] != K || rd[20:16] != N_CH || rd[25:24] != G) $fatal(1, "INFO %h", rd);
        axi_wr(16'h08, K + 1); axi_rd(16'h08, rd); if (rd != 0) $fatal(1, "DEPTH > K accepted: %0d", rd);
        for (int d = 0; d <= K; d++) begin
            axi_wr(16'h04, 1);                     // hold
            axi_wr(16'h08, d);
            repeat (20) @(posedge aclk);
            wait (dut.rst);
            @(posedge aclk);
            cur = d; nin_d = 0; nout_d = 0;
            fd = $fopen($sformatf("rx_d%0d.txt", d), "w");
            $fwrite(fd, "# depth %0d\n# nch %0d\n# spc %0d\n", d, N_CH, SPC);
            axi_wr(16'h04, 0);                     // release
            wait (nin_d >= NIN * (1 << d));
            repeat (400 + 64 * (1 << d)) @(posedge aclk);
            $fclose(fd); fd = 0;
            axi_rd(16'h10, rd);
            $display("DEPTH %0d: in %0d out %0d STATUS %h", d, nin_d, nout_d, rd);
            if (rd[1:0] != 0) stall_seen = 1;
        end
        if (stall_seen) $display("ASSERT_RX_NO_STALL FAIL"); else $display("ASSERT_RX_NO_STALL ok");
        $finish;
    end
endmodule
