// udp_streamer -- RFDC ADC samples -> Ethernet/IPv4/UDP/VRT frames for a CMAC.
//
// The wire format is Protocol §4 (top AGENTS.md), the contract with the UHD
// host module; every byte offset below comes from it.
//
//   s_axis  (adc_clk)   S_WIDTH-bit converter stream (128, 256, 512 or 1024), one
//                       32-bit slot (complex int16, I low, Q high) per 32 bits,
//                       slot 0 from bit 0. The RFDC ignores tready.
//                       Forwarded unchanged on m_axis_adc (DDR capture path).
//                       With N channels (Protocol §9) the block design has
//                       already merged them into one beat, sample-major
//                       (ch_interleave DIR=0): slot i = channel i%N, sample i/N.
//   m_axis  (tx_clk)    512-bit CMAC TX AXIS, byte 0 first on the wire.
//   s_axi   (s_axi_aclk) AXI4-Lite register file, map in the table below.
//
// Three clock domains:
//   adc_clk  timekeeper, stream-command engine, (512/S_WIDTH)-beat -> 512-bit
//            packer.
//            A packet is admitted only if the data FIFO can hold all of it;
//            otherwise the whole packet is dropped and counted, so a timestamp
//            gap is the host's one loss indicator.
//   tx_clk   framer: pops a descriptor once its data is fully in the FIFO,
//            so a frame never stalls mid-packet (the CMAC forbids TX bubbles).
//   s_axi    registers. Configuration is quasi-static (written before a
//            stream starts) and crosses on plain synchronisers; commands and
//            the time snapshot cross on XPM handshakes.
//
// Register map (byte offsets):
//   0x00 ID        RO  0x5A533031 'ZS01'
//   0x04 CTRL      RW  [0] enable [1] test pattern [2] clear stats (self-clearing)
//   0x08 STREAM_CMD W  [1:0] 0 stop, 1 continuous, 2 num_done, 3 num_more
//                      [8] now. The write issues NUM_SAMPS/CMD_TIME with it.
//   0x0C/0x10 NUM_SAMPS lo/hi   0x14/0x18 CMD_TIME lo/hi (ticks)
//   0x1C/0x20 TIME_NOW lo/hi RO (reading lo freezes hi)
//   0x24/0x28 TIME_SET lo/hi    0x2C TIME_CTRL [0] load TIME_SET now (strobe;
//                      the low bits are cleared to a multiple of BEAT_TICKS)
//   0x30/0x34 SRC_MAC lo/hi     0x38/0x3C DST_MAC lo/hi
//   0x40 SRC_IP  0x44 DST_IP  0x48 SRC_PORT  0x4C DST_PORT_BASE  0x50 NPORTS
//   0x54 SPP (slots; coerced to the FMT granularity and range below)   0x58 SID
//   0x60/0x64 PKTS lo/hi RO   0x68 OVERFLOWS RO   0x70 FIFO_HWM RO (words)
//   0x6C STATUS RO [0] streaming [1] cmac rx aligned [2] cmac tx ready
//                  [3] command rejected since last clear (start while busy)
//   0x74 CMDS RO  stream commands accepted by the adc domain
//   0x78 FMT  RW  [1:0] over-the-wire sample format (Protocol §10):
//                 0 sc16, 1 sc8, 2 sc12, 3 fc32. Quasi-static like the header
//                 fields: write it only while the stream is idle.
//
// Over-the-wire formats (Protocol §10). The packer always builds 16-slot
// sc16 groups (one 512-bit word, after the test-pattern mux; fc32 uses 8-slot
// half groups); a converter in adc_clk turns them into whole 64-byte wire words
// before the data FIFO, so the FIFO, the descriptor word count, the framer and
// every length field count WIRE words (bytes per packet = slots x bytes/slot):
//   FMT  bytes/slot  conversion unit           SPP granularity, range
//   sc16     4       1 group  -> 1 word         16,  16..2048 (unchanged)
//   sc8      2       2 groups -> 1 word         32,  32..4096
//                    int8 = round-half-up(x/256), saturated to 127
//   sc12     3       4 groups -> 3 words        64,  64..2688
//                    int12 = round-half-up(x/16), saturated to 2047; UHD
//                    sc12_item32_le packing (4 slots in 3 LE 32-bit lines)
//   fc32     8       1 half group -> 1 word      8,   8..1024
//                    float32 = x/32768 exactly (0 -> +0.0)
// SPP writes are coerced: below the granularity -> the granularity, above the
// range -> the maximum, else rounded down (sc16 keeps its original coercion,
// including 16 for any value with bits [11:4] clear); the read-back is the
// coerced value for the current FMT. NUM_SAMPS of a num_done burst rounds up
// to the same granularity. Packets always hold whole conversion units, so a
// packet TSF is the tick of its first slot exactly as for sc16.
// The sc16 path is the original one, cycle for cycle; the other formats go
// through a 3 (sc8, sc12) or 4 (fc32) stage pipeline and reserve 4 more words
// in the admission test.
// fc32 at S_WIDTH = 512 would need two FIFO words per adc_clk cycle: it is not
// supported. Every packet is then dropped at admission and counted in
// OVERFLOWS (no frame is sent); the daemon refuses that combination.
// S_WIDTH = 1024 (the sc8max builds, Protocol §9) carries sc8 ONLY: a beat
// is 32 slots, the packer's group is the whole beat and the sc8 converter
// turns it into exactly one wire word, so the FIFO takes one word per
// adc_clk cycle (96 Gb/s at 187.5 MHz). sc16, sc12 and fc32 would need more
// than one word per cycle; like fc32 at 512, their packets are all dropped at
// admission and counted, and the daemon refuses them.
// Time is a 64-bit count of ticks. The tick rate is fixed per build (UHD
// tick_rate, 1.2 GHz; 960 MHz for N = 16) whatever the converter factor F
// compiled into the block design; one slot is TICK_STEP ticks (single
// channel: F/2, so F = 2, 4, 8 -> 1, 2, 4; multi-channel builds: 1, one tick
// per slot, Protocol §9). A beat carries S_WIDTH/32 slots, so the
// timekeeper advances by BEAT_TICKS = (S_WIDTH/32)*TICK_STEP per ADC beat and
// slot k of a beat has timestamp now + k*TICK_STEP. Packet timestamps are
// multiples of BEAT_TICKS. TIME_SET is aligned down to a multiple of
// BEAT_TICKS, which assumes TICK_STEP is a power of two (it is for every
// supported F). A 512-bit FIFO word is always 16 slots, so the 16-slot
// granularity of NUM_SAMPS and SPP does not depend on S_WIDTH.

`timescale 1ns / 1ps
`default_nettype none

module udp_streamer #(
    parameter integer DATA_FIFO_DEPTH = 1024,     // 512-bit words
    parameter integer TICK_STEP       = 1,        // ticks per slot = F/2 (1 ch); power of 2
    parameter integer S_WIDTH         = 128       // s_axis / m_axis_adc width: 128, 256, 512 or 1024 (sc8 only)
) (
    // ---- ADC side
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 adc_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis_adc, ASSOCIATED_RESET adc_aresetn" *)
    input  wire         adc_clk,
    input  wire         adc_aresetn,
    input  wire [S_WIDTH-1:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    // Pass-through of s_axis to the existing DDR capture path. The streamer
    // observes every beat on tvalid alone: the RFDC ignores tready, so the
    // downstream ready is only forwarded, never acted on.
    output wire [S_WIDTH-1:0] m_axis_adc_tdata,
    output wire         m_axis_adc_tvalid,
    input  wire         m_axis_adc_tready,
    output wire [63:0]  adc_time,        // timekeeper (adc_clk): shared with the DAC player

    // ---- CMAC TX side
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET tx_aresetn, FREQ_HZ 322265625" *)
    input  wire         tx_clk,
    input  wire         tx_aresetn,
    output wire [511:0] m_axis_tdata,
    output wire [63:0]  m_axis_tkeep,
    output wire         m_axis_tvalid,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser,
    input  wire         m_axis_tready,

    // ---- CMAC status (any clock; synchronised here)
    input  wire         cmac_rx_aligned,
    input  wire         cmac_tx_ready,

    // ---- AXI4-Lite
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,
    input  wire [15:0]  s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output reg          s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output reg          s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output reg          s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [15:0]  s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output reg          s_axi_arready,
    output reg  [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output reg          s_axi_rvalid,
    input  wire         s_axi_rready
);

    localparam [31:0] ID = 32'h5A533031;
    localparam integer DCW = $clog2(DATA_FIFO_DEPTH) + 1;
    localparam integer WIDE  = (S_WIDTH == 1024);     // sc8-only 32-slot groups
    localparam integer GW    = WIDE ? 1024 : 512;     // packer group width (bits)
    localparam integer NV    = GW / 16;               // 16-bit values per group
    localparam integer SLOTS = S_WIDTH / 32;          // slots per ADC beat
    localparam integer BPW   = WIDE ? 1 : 512 / S_WIDTH;  // ADC beats per group
    localparam [63:0]  BEAT_TICKS = SLOTS * TICK_STEP; // ticks per ADC beat
    localparam [1:0]   LAST_BEAT  = BPW - 1;

    // Elaboration-time check: an unsupported width instantiates a module that
    // does not exist, so the build fails instead of mis-packing.
    generate if (S_WIDTH != 128 && S_WIDTH != 256 && S_WIDTH != 512 && S_WIDTH != 1024) begin : g_bad_width
        udp_streamer_S_WIDTH_must_be_128_256_512_or_1024 u_bad ();
    end endgenerate

    assign s_axis_tready     = m_axis_adc_tready;
    assign m_axis_adc_tdata  = s_axis_tdata;
    assign m_axis_adc_tvalid = s_axis_tvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    // =========================================================================
    // AXI4-Lite register file (s_axi_aclk)
    // =========================================================================
    reg  [31:0] r_ctrl, r_num_lo, r_num_hi, r_ctime_lo, r_ctime_hi;
    reg  [31:0] r_tset_lo, r_tset_hi;
    reg  [31:0] r_smac_lo, r_smac_hi, r_dmac_lo, r_dmac_hi;
    reg  [31:0] r_sip, r_dip, r_sport, r_dport, r_nports, r_spp, r_sid;
    reg  [31:0] r_spp_wr;            // SPP as written; r_spp is it coerced for r_fmt
    reg  [1:0]  r_fmt;
    reg  [7:0]  r_sppw;              // 64-byte wire words per packet
    reg  [31:0] r_time_hi_frozen;

    reg         cmd_send_a;          // handshake request (axi domain)
    reg  [130:0] cmd_data_a;         // {now, mode[1:0], num_samps[63:0], time[63:0]}
    wire        cmd_rcv_a;
    reg         tset_send_a;
    reg  [63:0] tset_data_a;
    wire        tset_rcv_a;
    reg         clr_toggle_a;

    wire [63:0] time_now_a;          // snapshot of the adc-domain clock
    wire [31:0] pkts_a, ovf_a, hwm_a, cmds_a;
    wire        streaming_a, aligned_a, txrdy_a, rejected_a;

    reg  [15:0] wr_addr;
    reg  [31:0] wr_data;
    reg         aw_seen, w_seen;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0; w_seen <= 1'b0;
            r_ctrl <= 32'd0; r_num_lo <= 32'd0; r_num_hi <= 32'd0;
            r_ctime_lo <= 32'd0; r_ctime_hi <= 32'd0;
            r_tset_lo <= 32'd0; r_tset_hi <= 32'd0;
            r_smac_lo <= 32'h43323136; r_smac_hi <= 32'h0000025A; // 02:5a:43:32:31:36 (sw sets it anyway)
            r_dmac_lo <= 32'hFFFFFFFF; r_dmac_hi <= 32'h0000FFFF;
            r_sip <= 32'hC0A80502; r_dip <= 32'hC0A80501;
            r_sport <= 32'd49800; r_dport <= 32'd49810; r_nports <= 32'd1;
            r_spp_wr <= 32'd2048; r_sid <= 32'h5A160000; r_fmt <= 2'd0;
            cmd_send_a <= 1'b0; tset_send_a <= 1'b0; clr_toggle_a <= 1'b0;
            cmd_data_a <= 131'd0; tset_data_a <= 64'd0;
        end else begin
            // Accept address and data independently, act once both are held.
            if (s_axi_awvalid && !aw_seen) begin
                aw_seen <= 1'b1; wr_addr <= s_axi_awaddr; s_axi_awready <= 1'b1;
            end else s_axi_awready <= 1'b0;
            if (s_axi_wvalid && !w_seen) begin
                w_seen <= 1'b1; wr_data <= s_axi_wdata; s_axi_wready <= 1'b1;
            end else s_axi_wready <= 1'b0;

            if (aw_seen && w_seen && !s_axi_bvalid) begin
                aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
                case (wr_addr[7:2])
                    6'h01: begin
                        r_ctrl <= wr_data & 32'h3;
                        if (wr_data[2]) clr_toggle_a <= ~clr_toggle_a;
                    end
                    6'h02: if (!cmd_send_a) begin
                        cmd_data_a <= {wr_data[8], wr_data[1:0], r_num_hi, r_num_lo,
                                       r_ctime_hi, r_ctime_lo};
                        cmd_send_a <= 1'b1;
                    end
                    6'h03: r_num_lo   <= wr_data;
                    6'h04: r_num_hi   <= wr_data;
                    6'h05: r_ctime_lo <= wr_data;
                    6'h06: r_ctime_hi <= wr_data;
                    6'h09: r_tset_lo  <= wr_data;
                    6'h0A: r_tset_hi  <= wr_data;
                    6'h0B: if (wr_data[0] && !tset_send_a) begin
                        tset_data_a <= {r_tset_hi, r_tset_lo};
                        tset_send_a <= 1'b1;
                    end
                    6'h0C: r_smac_lo <= wr_data;
                    6'h0D: r_smac_hi <= wr_data & 32'hFFFF;
                    6'h0E: r_dmac_lo <= wr_data;
                    6'h0F: r_dmac_hi <= wr_data & 32'hFFFF;
                    6'h10: r_sip     <= wr_data;
                    6'h11: r_dip     <= wr_data;
                    6'h12: r_sport   <= wr_data & 32'hFFFF;
                    6'h13: r_dport   <= wr_data & 32'hFFFF;
                    6'h14: r_nports  <= (wr_data[7:0] == 8'd0) ? 32'd1 : (wr_data & 32'hFF);
                    6'h15: r_spp_wr  <= wr_data;
                    6'h16: r_sid     <= wr_data;
                    6'h1E: r_fmt     <= wr_data[1:0];
                    default: ;
                endcase
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            // Four-phase handshakes: drop the request once the far side has it.
            if (cmd_send_a && cmd_rcv_a)   cmd_send_a  <= 1'b0;
            if (tset_send_a && tset_rcv_a) tset_send_a <= 1'b0;
        end
    end

    // SPP coerced to the format's granularity and range (see the header), and
    // the packet length in 64-byte wire words. Registered every cycle, so a
    // later FMT write re-coerces an earlier SPP write.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            r_spp <= 32'd2048; r_sppw <= 8'd128;
        end else begin
            case (r_fmt)
                2'd0: r_spp <= (r_spp_wr[11:4] == 8'd0) ? 32'd16 :
                               (r_spp_wr > 32'd2048) ? 32'd2048 : (r_spp_wr & 32'hFF0);
                2'd1: r_spp <= (r_spp_wr < 32'd32) ? 32'd32 :
                               (r_spp_wr > 32'd4096) ? 32'd4096 : (r_spp_wr & 32'h1FE0);
                2'd2: r_spp <= (r_spp_wr < 32'd64) ? 32'd64 :
                               (r_spp_wr > 32'd2688) ? 32'd2688 : (r_spp_wr & 32'hFC0);
                default: r_spp <= (r_spp_wr < 32'd8) ? 32'd8 :
                               (r_spp_wr > 32'd1024) ? 32'd1024 : (r_spp_wr & 32'h7F8);
            endcase
            case (r_fmt)
                2'd0: r_sppw <= r_spp[11:4];                          // 16 slots / word
                2'd1: r_sppw <= r_spp[12:5];                          // 32 slots / word
                2'd2: r_sppw <= {r_spp[11:6], 1'b0} + {2'd0, r_spp[11:6]};   // 3 words / 64 slots
                default: r_sppw <= r_spp[10:3];                       // 8 slots / word
            endcase
        end
    end

    reg  [15:0] rd_addr;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0;
            r_time_hi_frozen <= 32'd0;
        end else if (!s_axi_arready && !s_axi_rvalid && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;            // address handshake completes next edge
            rd_addr       <= s_axi_araddr;
        end else if (s_axi_arready) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b1;
            case (rd_addr[7:2])
                6'h00: s_axi_rdata <= ID;
                6'h01: s_axi_rdata <= r_ctrl;
                6'h03: s_axi_rdata <= r_num_lo;
                6'h04: s_axi_rdata <= r_num_hi;
                6'h05: s_axi_rdata <= r_ctime_lo;
                6'h06: s_axi_rdata <= r_ctime_hi;
                6'h07: begin
                    s_axi_rdata      <= time_now_a[31:0];
                    r_time_hi_frozen <= time_now_a[63:32];
                end
                6'h08: s_axi_rdata <= r_time_hi_frozen;
                6'h09: s_axi_rdata <= r_tset_lo;
                6'h0A: s_axi_rdata <= r_tset_hi;
                6'h0C: s_axi_rdata <= r_smac_lo;
                6'h0D: s_axi_rdata <= r_smac_hi;
                6'h0E: s_axi_rdata <= r_dmac_lo;
                6'h0F: s_axi_rdata <= r_dmac_hi;
                6'h10: s_axi_rdata <= r_sip;
                6'h11: s_axi_rdata <= r_dip;
                6'h12: s_axi_rdata <= r_sport;
                6'h13: s_axi_rdata <= r_dport;
                6'h14: s_axi_rdata <= r_nports;
                6'h15: s_axi_rdata <= r_spp;
                6'h16: s_axi_rdata <= r_sid;
                6'h18: s_axi_rdata <= pkts_a;
                6'h19: s_axi_rdata <= 32'd0;
                6'h1A: s_axi_rdata <= ovf_a;
                6'h1B: s_axi_rdata <= {28'd0, rejected_a, txrdy_a, aligned_a, streaming_a};
                6'h1C: s_axi_rdata <= hwm_a;
                6'h1D: s_axi_rdata <= cmds_a;
                6'h1E: s_axi_rdata <= {30'd0, r_fmt};
                default: s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Clock-domain crossings
    // =========================================================================
    // Quasi-static configuration -> adc domain: {pattern, enable, format, spp words}
    wire [1:0]  ctrl_d;
    wire [1:0]  fmt_d;
    wire [7:0]  sppw_d;               // 64-byte wire words per packet
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(12))
    u_cfg_adc (.src_clk(s_axi_aclk), .src_in({r_ctrl[1:0], r_fmt, r_sppw}),
               .dest_clk(adc_clk), .dest_out({ctrl_d, fmt_d, sppw_d}));

    // Quasi-static configuration -> tx domain (header fields)
    wire [47:0] smac_t, dmac_t;
    wire [31:0] sip_t, dip_t, sid_t;
    wire [15:0] sport_t, dport_t;
    wire [7:0]  nports_t;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(232))
    u_cfg_tx (.src_clk(s_axi_aclk),
              .src_in({r_smac_hi[15:0], r_smac_lo, r_dmac_hi[15:0], r_dmac_lo,
                       r_sip, r_dip, r_sid, r_sport[15:0], r_dport[15:0], r_nports[7:0]}),
              .dest_clk(tx_clk),
              .dest_out({smac_t, dmac_t, sip_t, dip_t, sid_t, sport_t, dport_t, nports_t}));

    // Stream command -> adc domain
    wire [130:0] cmd_d;
    wire         cmd_req_d;
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3), .WIDTH(131))
    u_cmd (.src_clk(s_axi_aclk), .src_in(cmd_data_a), .src_send(cmd_send_a), .src_rcv(cmd_rcv_a),
           .dest_clk(adc_clk), .dest_req(cmd_req_d), .dest_ack(1'b0), .dest_out(cmd_d));

    // Time set -> adc domain
    wire [63:0] tset_d;
    wire        tset_req_d;
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3), .WIDTH(64))
    u_tset (.src_clk(s_axi_aclk), .src_in(tset_data_a), .src_send(tset_send_a), .src_rcv(tset_rcv_a),
            .dest_clk(adc_clk), .dest_req(tset_req_d), .dest_ack(1'b0), .dest_out(tset_d));

    // Clear-stats toggle -> both domains
    wire clr_tog_d, clr_tog_t;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_clr_d (.src_clk(s_axi_aclk), .src_in(clr_toggle_a), .dest_clk(adc_clk), .dest_out(clr_tog_d));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_clr_t (.src_clk(s_axi_aclk), .src_in(clr_toggle_a), .dest_clk(tx_clk), .dest_out(clr_tog_t));

    // Status -> axi domain
    wire        streaming_d;
    reg         rejected_d;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0))
    u_st0 (.src_clk(adc_clk), .src_in(streaming_d), .dest_clk(s_axi_aclk), .dest_out(streaming_a));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0))
    u_st1 (.src_clk(adc_clk), .src_in(cmac_rx_aligned), .dest_clk(s_axi_aclk), .dest_out(aligned_a));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0))
    u_st2 (.src_clk(adc_clk), .src_in(cmac_tx_ready), .dest_clk(s_axi_aclk), .dest_out(txrdy_a));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0))
    u_st3 (.src_clk(adc_clk), .src_in(rejected_d), .dest_clk(s_axi_aclk), .dest_out(rejected_a));

    // =========================================================================
    // ADC domain: timekeeper, command engine, packer, format converter
    // =========================================================================
    reg  [63:0] now_d;               // timestamp of the current beat's slot 0 (ticks)
    reg  [1:0]  st_d;
    localparam [1:0] S_IDLE = 2'd0, S_ARMED = 2'd1, S_RUN = 2'd2;

    reg  [1:0]  mode_d;              // latched command
    reg  [63:0] rem_d;               // slots left in a finite burst (multiple of the granularity)
    reg  [63:0] ctime_d;
    reg         finite_d, more_d, stop_req_d, first_pkt_d, drop_d;
    reg  [1:0]  beat_d;              // beat within the group (0..BPW-1; fc32 0..BPW/2-1)
    reg  [1:0]  unit_d;              // group within the conversion unit (sc8 0..1, sc12 0..3)
    reg  [7:0]  word_d;              // wire words of the packet completed so far
    reg  [GW-1:0] pack_d;
    reg  [63:0] pkt_tsf_d;
    reg         pkt_sob_d;

    reg  [511:0] dfifo_din;
    reg          dfifo_wr;
    wire [DCW-1:0] dfifo_wcount;
    wire         dfifo_full;
    reg  [74:0]  qfifo_din;           // {sob, eob, nwords[8:0], tsf[63:0]}
    reg          qfifo_wr;
    wire         qfifo_full;
    wire [5:0]   qfifo_wcount;
    wire         dfifo_wrb, qfifo_wrb;   // write-side reset busy
    wire         fifo_busy;              // any FIFO reset in progress

    reg  [31:0] ovf_d, hwm_d, cmds_d;
    reg         clr_tog_d_q;

    // Current beat's slots, or the test pattern keyed to their timestamps.
    wire [S_WIDTH-1:0] beat_data;
    genvar gi;
    generate for (gi = 0; gi < SLOTS; gi = gi + 1) begin : g_pat
        wire [15:0] pi = now_d[15:0] + gi * TICK_STEP;   // timestamp of slot gi
        assign beat_data[32*gi +: 32] = ctrl_d[1] ? {~pi, pi} : s_axis_tdata[32*gi +: 32];
    end endgenerate

    // The full group (512 bits; the 1024-bit beat at S_WIDTH 1024) on its
    // last beat: this beat on top of the ones already packed.
    wire [GW-1:0] word_data;
    generate if (BPW == 1) begin : g_word1
        assign word_data = beat_data;
    end else begin : g_wordn
        assign word_data = {beat_data, pack_d[512-S_WIDTH-1:0]};
    end endgenerate

    // fc32 half group (8 slots) on its last beat. Not available at S_WIDTH 512.
    localparam integer FC32_OK   = (S_WIDTH != 512);
    localparam [1:0]   HALF_LAST = (BPW >= 2) ? (BPW / 2 - 1) : 2'd0;
    wire [255:0] half_data;
    generate if (BPW >= 4) begin : g_half4
        assign half_data = {beat_data, pack_d[255-S_WIDTH:0]};
    end else begin : g_half2
        assign half_data = beat_data[255:0];
    end endgenerate

    // Format decode (fmt_d is quasi-static: only changed while idle; one more
    // register for its fan-out into the converter muxes).
    reg  [1:0]  fmt_q;
    always @(posedge adc_clk) fmt_q <= fmt_d;
    wire        is16 = (fmt_q == 2'd0);
    wire        is8  = (fmt_q == 2'd1);
    wire        is12 = (fmt_q == 2'd2);
    wire        isf  = (fmt_q == 2'd3);
    wire        half = isf && (FC32_OK != 0);             // 8-slot groups
    wire [1:0]  grp_lb  = half ? HALF_LAST : LAST_BEAT;    // last beat of a group
    wire [1:0]  unit_lb = (is8 && !WIDE) ? 2'd1 : is12 ? 2'd3 : 2'd0; // last group of a unit
    wire [63:0] grp_slots = WIDE ? 64'd32 : half ? 64'd8 : 64'd16;
    // Wire words this group completes: sc16 1, sc8 0/1 (S_WIDTH 1024: 1),
    // sc12 0/1/1/1, fc32 1 (2 for the unsupported S_WIDTH 512 case, whose
    // packets are all dropped).
    wire [1:0]  n_emit = is8  ? {1'b0, WIDE || unit_d == 2'd1} :
                         is12 ? {1'b0, unit_d != 2'd0} :
                         (isf && !half) ? 2'd2 : 2'd1;

    // Admission test: the whole packet must fit, with margin for the count lag
    // (and, outside sc16, for the words still in the converter pipeline).
    wire [DCW-1:0] need_words = sppw_d + (is16 ? 8'd4 : 8'd8);
    // Both counts lag writes still in flight (one packet's descriptor can be
    // pending when the next packet starts), hence the margins.
    wire           room       = (!isf || half) && (!WIDE || is8) &&
                                !fifo_busy && !dfifo_full &&
                                ((DATA_FIFO_DEPTH - dfifo_wcount) > need_words) &&
                                (qfifo_wcount < 6'd28);

    wire [1:0]  cmd_mode = cmd_d[129:128];
    wire        cmd_now  = cmd_d[130];
    wire [63:0] cmd_num  = cmd_d[127:64];
    wire [63:0] cmd_time = cmd_d[63:0];
    reg         cmd_req_d_q, tset_req_d_q;
    wire        cmd_new  = cmd_req_d  && !cmd_req_d_q;
    wire        tset_new = tset_req_d && !tset_req_d_q;


    // A beat is collected while running, or on the beat that contains the
    // armed start time (a late start begins at once). Timed starts therefore
    // carry TSF <= requested time, and the host trims the difference.
    wire        start_hit  = (st_d == S_ARMED) && (ctime_d < now_d + BEAT_TICKS);
    wire        at_pkt_start = (beat_d == 2'd0) && (word_d == 8'd0) && (unit_d == 2'd0);
    // A stop between packets ends the stream here, with no EOB frame.
    wire        stop_idle  = (st_d == S_RUN) && stop_req_d && at_pkt_start;
    wire        collect    = s_axis_tvalid && ctrl_d[0] && !stop_idle &&
                             ((st_d == S_RUN) || start_hit);

    // A packet or a burst ends only on a conversion-unit boundary (sc16 and
    // fc32: every group).
    wire        word_done  = (beat_d == grp_lb);                  // group complete
    wire        unit_end   = word_done && (unit_d == unit_lb);
    wire [8:0]  words_next = {1'b0, word_d} + {7'd0, n_emit};
    wire        last_word  = finite_d && (rem_d <= grp_slots);
    wire        pkt_full   = (words_next >= {1'b0, sppw_d});
    wire        pkt_end    = unit_end && (pkt_full || last_word || stop_req_d);
    wire        burst_end  = unit_end && (last_word || stop_req_d);

    // The packet's admission decision, TSF and SOB as they apply to the word
    // being completed this cycle. With S_WIDTH < 512 a word completes after
    // the packet's first beat, so these are just the registers. With
    // S_WIDTH = 512 the first beat IS a complete word, and the registers only
    // update at the end of this cycle: use the values being decided now.
    wire        drop_eff   = at_pkt_start ? !room       : drop_d;
    wire [63:0] tsf_eff    = at_pkt_start ? now_d       : pkt_tsf_d;
    wire        sob_eff    = at_pkt_start ? first_pkt_d : pkt_sob_d;

    // Converter stage 1 (written by the packer below): one group.
    reg          cv_v, cv_we;        // group valid; it completes a word to keep
    reg  [1:0]   cv_unit;
    reg  [GW-1:0] cv_d;              // sc16 group (fc32: half group in [255:0])
    wire [511:0] cvo_d;              // converter output word
    wire         cvo_wr;

    assign streaming_d = (st_d != S_IDLE);
    assign adc_time    = now_d;

    always @(posedge adc_clk) begin
        cmd_req_d_q  <= cmd_req_d;
        tset_req_d_q <= tset_req_d;
        clr_tog_d_q  <= clr_tog_d;
        dfifo_wr <= 1'b0;
        qfifo_wr <= 1'b0;
        cv_v     <= 1'b0;

        if (!adc_aresetn) begin
            now_d <= 64'd0; st_d <= S_IDLE; stop_req_d <= 1'b0;
            beat_d <= 2'd0; word_d <= 8'd0; unit_d <= 2'd0; drop_d <= 1'b0;
            ovf_d <= 32'd0; hwm_d <= 32'd0; cmds_d <= 32'd0; rejected_d <= 1'b0;
            finite_d <= 1'b0; more_d <= 1'b0; first_pkt_d <= 1'b0;
        end else begin
            if (tset_new)           now_d <= tset_d & ~(BEAT_TICKS - 64'd1);
            else if (s_axis_tvalid) now_d <= now_d + BEAT_TICKS;

            if (clr_tog_d != clr_tog_d_q) begin
                ovf_d <= 32'd0; hwm_d <= 32'd0; rejected_d <= 1'b0;
            end else if ({{(32-DCW){1'b0}}, dfifo_wcount} > hwm_d) begin
                hwm_d <= {{(32-DCW){1'b0}}, dfifo_wcount};
            end

            if (!ctrl_d[0]) begin
                st_d <= S_IDLE; stop_req_d <= 1'b0;
                beat_d <= 2'd0; word_d <= 8'd0; unit_d <= 2'd0;
            end else begin
                // ---- data first: a command never costs a beat
                if (stop_idle) begin
                    st_d <= S_IDLE; stop_req_d <= 1'b0;
                end else if (collect) begin
                    if (start_hit) st_d <= S_RUN;
                    if (at_pkt_start) begin
                        pkt_tsf_d   <= now_d;
                        pkt_sob_d   <= first_pkt_d;
                        first_pkt_d <= 1'b0;
                        drop_d      <= !room;
                        if (!room) ovf_d <= ovf_d + 32'd1;
                    end
                    pack_d[S_WIDTH*beat_d +: S_WIDTH] <= beat_data;
                    beat_d <= word_done ? 2'd0 : beat_d + 2'd1;

                    if (word_done) begin
                        // drop_eff: decided at this packet's beat 0
                        if (is16) begin                 // sc16: straight into the FIFO
                            dfifo_din <= word_data[511:0];
                            dfifo_wr  <= !drop_eff;
                        end
                        cv_v    <= !is16;               // other formats: converter
                        cv_we   <= !drop_eff && (n_emit != 2'd0);
                        cv_unit <= unit_d;
                        cv_d    <= half ? {{(GW-256){1'b0}}, half_data} : word_data;
                        unit_d  <= (unit_d == unit_lb) ? 2'd0 : unit_d + 2'd1;
                        if (finite_d) rem_d <= rem_d - grp_slots;
                        if (pkt_end) begin
                            word_d    <= 8'd0;
                            qfifo_din <= {sob_eff, burst_end & ~more_d, words_next, tsf_eff};
                            qfifo_wr  <= !drop_eff;
                            if (burst_end) begin
                                st_d <= S_IDLE;
                                stop_req_d <= 1'b0;
                            end
                        end else begin
                            word_d <= words_next[7:0];
                        end
                    end
                end

                // A FIFO reset mid-packet would leave data and descriptor
                // FIFOs out of step: drop the rest of the packet.
                if (fifo_busy) drop_d <= 1'b1;

                // ---- commands. Starts are only taken in IDLE, where nothing
                // is being collected; a stop only raises a flag the data path
                // honours at the next conversion-unit boundary.
                if (cmd_new && cmd_mode == 2'd0) begin
                    if (st_d == S_ARMED && !start_hit) st_d <= S_IDLE;
                    else if (st_d != S_IDLE) stop_req_d <= 1'b1;
                    cmds_d <= cmds_d + 32'd1;
                end else if (cmd_new && st_d != S_IDLE) begin
                    rejected_d <= 1'b1;             // one command in flight at a time
                end else if (cmd_new) begin
                    cmds_d <= cmds_d + 32'd1;
                    if (!(cmd_mode[1] && cmd_num == 64'd0)) begin   // zero-length: no-op
                        finite_d    <= cmd_mode[1];
                        more_d      <= (cmd_mode == 2'd3);
                        rem_d       <= is8  ? ((cmd_num + 64'd31) & ~64'd31) :
                                       is12 ? ((cmd_num + 64'd63) & ~64'd63) :
                                       half ? ((cmd_num + 64'd7)  & ~64'd7)  :
                                              ((cmd_num + 64'd15) & ~64'd15);
                        ctime_d     <= cmd_time;
                        st_d        <= cmd_now ? S_RUN : S_ARMED;
                        stop_req_d  <= 1'b0;
                        first_pkt_d <= 1'b1;
                        beat_d <= 2'd0; word_d <= 8'd0; unit_d <= 2'd0;
                    end
                end
            end

            // Converter output (formats other than sc16) into the data FIFO.
            if (!is16) begin
                dfifo_din <= cvo_d;
                dfifo_wr  <= cvo_wr && !fifo_busy;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Format converter (adc_clk): sc16 groups -> sc8 / sc12 / fc32 wire words.
    // Stage 2 rounds (sc8, sc12) or takes the magnitude (fc32); stage 3
    // assembles sc8/sc12 words, or half-normalises fc32; stage 4 finishes
    // fc32. Value k of a group is cv_d[16k +: 16] (I of slot k/2 for even k).
    // -------------------------------------------------------------------------
    wire [8*NV-1:0] c8_w;            // NV int8, byte k = value k
    wire [383:0] c12_w;              // 32 int12 in UHD sc12_item32_le order
    wire [383:0] q12;                // 32 int12, value k at [12k +: 12]
    wire [255:0] mag_w;              // fc32: 16 magnitudes
    wire [15:0]  sgn_w;
    genvar gk;
    generate for (gk = 0; gk < NV; gk = gk + 1) begin : g_rnd
        wire [15:0] x   = cv_d[16*gk +: 16];
        wire [15:0] t8  = x + 16'd128;      // round half up, then keep the MSBs;
        wire [15:0] t12 = x + 16'd8;        // a positive carry into bit 15 saturates
        assign c8_w[8*gk +: 8]  = (!x[15] && t8[15])  ? 8'h7F   : t8[15:8];
        if (gk < 32) begin : g_q12
            assign q12[12*gk +: 12] = (!x[15] && t12[15]) ? 12'h7FF : t12[15:4];
        end
    end endgenerate
    // UHD pack(): per 4 slots (8 values v0..v7) three LE 32-bit lines
    //   line0 = {v0, v1, v2[11:4]}  line1 = {v2[3:0], v3, v4, v5[11:8]}
    //   line2 = {v5[7:0], v6, v7}
    generate for (gk = 0; gk < 4; gk = gk + 1) begin : g_pk12
        wire [95:0] v = q12[96*gk +: 96];
        assign c12_w[96*gk +: 96] = {
            v[67:60], v[83:72], v[95:84],                      // line2
            v[27:24], v[47:36], v[59:48], v[71:68],            // line1
            v[11:0], v[23:12], v[35:28]};                      // line0
    end endgenerate
    generate for (gk = 0; gk < 16; gk = gk + 1) begin : g_mag
        wire [15:0] x = cv_d[16*gk +: 16];
        assign sgn_w[gk]          = x[15];
        assign mag_w[16*gk +: 16] = (x ^ {16{x[15]}}) + {15'd0, x[15]};   // |x|, 32768 fits
    end endgenerate

    reg          c2_v, c2_we;
    reg  [1:0]   c2_unit;
    reg  [8*NV-1:0] c2_8;
    reg  [383:0] c2_12;
    reg  [255:0] c2_mag;
    reg  [15:0]  c2_s;
    reg          c3_wr;
    reg  [511:0] c3_d;
    wire [511:0] c3_8;               // sc8 word from this group (and h8)
    reg  [255:0] h8;                 // sc8: first group of the pair
    reg  [383:0] acc12;              // sc12: bytes of the unit not yet in a word
    reg          f3_v;
    reg  [255:0] f3_b;
    reg  [15:0]  f3_s, f3_z8, f3_z4, f3_nz;
    reg          c4_wr;
    reg  [511:0] c4_d;

    // fc32 normalisation, part 1 (shift by 8, 4) and part 2 (2, 1). With the
    // total left shift L = 8*z8 + 4*z4 + 2*z2 + z1 the exponent is 127 - L =
    // {4'b0111, ~z8, ~z4, ~z2, ~z1}, and the mantissa the bits below the
    // leading one: value = |x| / 32768 exactly.
    wire [255:0] f3_b_w;
    wire [15:0]  f3_z8_w, f3_z4_w;
    wire [511:0] c4_w;
    generate for (gk = 0; gk < 16; gk = gk + 1) begin : g_flt
        wire [15:0] m  = c2_mag[16*gk +: 16];
        wire        z8 = (m[15:8] == 8'd0);
        wire [15:0] a  = z8 ? {m[7:0], 8'd0} : m;
        wire        z4 = (a[15:12] == 4'd0);
        assign f3_z8_w[gk] = z8;
        assign f3_z4_w[gk] = z4;
        assign f3_b_w[16*gk +: 16] = z4 ? {a[11:0], 4'd0} : a;

        wire [15:0] b  = f3_b[16*gk +: 16];
        wire        z2 = (b[15:14] == 2'd0);
        wire [15:0] c  = z2 ? {b[13:0], 2'd0} : b;
        wire        z1 = !c[15];
        wire [15:0] d  = z1 ? {c[14:0], 1'b0} : c;
        assign c4_w[32*gk +: 32] = f3_nz[gk] ?
            {f3_s[gk], 4'b0111, ~f3_z8[gk], ~f3_z4[gk], ~z2, ~z1, d[14:0], 8'd0} : 32'd0;
    end endgenerate

    generate if (WIDE) begin : g_c3w
        assign c3_8 = c2_8;
    end else begin : g_c3n
        assign c3_8 = {c2_8, h8};
    end endgenerate

    integer k12;
    always @(posedge adc_clk) begin
        if (!adc_aresetn) begin
            c2_v <= 1'b0; c3_wr <= 1'b0; f3_v <= 1'b0; c4_wr <= 1'b0;
        end else begin
            c2_v <= cv_v;
            c3_wr <= c2_v && c2_we && (is8 || is12);
            f3_v  <= c2_v && c2_we && isf;
            c4_wr <= f3_v;
        end
        c2_we <= cv_we; c2_unit <= cv_unit;
        c2_8 <= c8_w; c2_12 <= c12_w; c2_mag <= mag_w; c2_s <= sgn_w;

        // stage 3: sc8 pairs two groups into a word (S_WIDTH 1024: its
        // 32-slot group IS a word); sc12 cuts 4 groups
        // (192 bytes) into 3 words: {g1[127:0], g0}, {g2[255:0], g1[383:128]},
        // {g3, g2[383:256]}.
        if (c2_v) begin
            if (is8) begin
                if (c2_unit == 2'd0) h8 <= c2_8[255:0];
                c3_d <= c3_8;
            end else begin
                case (c2_unit)
                    2'd0: acc12 <= c2_12;
                    2'd1: begin
                        c3_d <= {c2_12[127:0], acc12[383:0]};
                        acc12[255:0] <= c2_12[383:128];
                    end
                    2'd2: begin
                        c3_d <= {c2_12[255:0], acc12[255:0]};
                        acc12[127:0] <= c2_12[383:256];
                    end
                    default: c3_d <= {c2_12, acc12[127:0]};
                endcase
            end
        end
        f3_b <= f3_b_w; f3_z8 <= f3_z8_w; f3_z4 <= f3_z4_w; f3_s <= c2_s;
        for (k12 = 0; k12 < 16; k12 = k12 + 1) f3_nz[k12] <= (c2_mag[16*k12 +: 16] != 16'd0);
        c4_d <= c4_w;
    end
    assign cvo_d  = isf ? c4_d  : c3_d;
    assign cvo_wr = isf ? c4_wr : c3_wr;

    // Time snapshot -> axi domain, refreshed continuously.
    reg         tsnap_send;
    wire        tsnap_rcv;
    reg  [63:0] tsnap_src;
    always @(posedge adc_clk) begin
        if (!adc_aresetn) tsnap_send <= 1'b0;
        else if (!tsnap_send && !tsnap_rcv) begin tsnap_src <= now_d; tsnap_send <= 1'b1; end
        else if (tsnap_send && tsnap_rcv) tsnap_send <= 1'b0;
    end
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3), .WIDTH(64))
    u_tsnap (.src_clk(adc_clk), .src_in(tsnap_src), .src_send(tsnap_send), .src_rcv(tsnap_rcv),
             .dest_clk(s_axi_aclk), .dest_req(), .dest_ack(1'b0), .dest_out(time_now_a));

    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_ovf (.src_clk(adc_clk), .src_in_bin(ovf_d), .dest_clk(s_axi_aclk), .dest_out_bin(ovf_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_cmds (.src_clk(adc_clk), .src_in_bin(cmds_d), .dest_clk(s_axi_aclk), .dest_out_bin(cmds_a));
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(32))
    u_hwm (.src_clk(adc_clk), .src_in(hwm_d), .dest_clk(s_axi_aclk), .dest_out(hwm_a));

    // =========================================================================
    // FIFOs adc -> tx
    // =========================================================================
    // tx_clk (the CMAC user clock) only starts once the GT refclk has been
    // programmed, after the bitstream is loaded. XPM async FIFOs must see a
    // reset while BOTH clocks run, so they are held in reset until the CMAC
    // user reset releases -- re-reset every time the link clock comes back.
    wire tx_rstn_adc;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(0))
    u_txrst (.src_arst(tx_aresetn), .dest_clk(adc_clk), .dest_arst(tx_rstn_adc));
    wire fifo_rst = !adc_aresetn || !tx_rstn_adc;
    assign fifo_busy = fifo_rst || dfifo_wrb || qfifo_wrb;
    wire [511:0] dfifo_dout;
    wire         dfifo_empty;
    reg          dfifo_rd;
    wire [DCW-1:0] dfifo_rcount;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(DATA_FIFO_DEPTH),
        .WRITE_DATA_WIDTH(512), .READ_DATA_WIDTH(512),
        .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .WR_DATA_COUNT_WIDTH(DCW), .RD_DATA_COUNT_WIDTH(DCW),
        .USE_ADV_FEATURES("0404"), .CDC_SYNC_STAGES(3), .ECC_MODE("no_ecc"),
        .RELATED_CLOCKS(0), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(0),
        .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
    ) u_dfifo (
        .rst(fifo_rst), .wr_clk(adc_clk), .wr_en(dfifo_wr), .din(dfifo_din),
        .full(dfifo_full), .wr_data_count(dfifo_wcount),
        .rd_clk(tx_clk), .rd_en(dfifo_rd), .dout(dfifo_dout), .empty(dfifo_empty),
        .rd_data_count(dfifo_rcount),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .almost_full(), .wr_ack(), .wr_rst_busy(dfifo_wrb),
        .underflow(), .prog_empty(), .almost_empty(), .data_valid(), .rd_rst_busy(),
        .sbiterr(), .dbiterr()
    );

    wire [74:0] qfifo_dout;
    wire        qfifo_empty;
    reg         qfifo_rd;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(32),
        .WRITE_DATA_WIDTH(75), .READ_DATA_WIDTH(75),
        .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .WR_DATA_COUNT_WIDTH(6), .USE_ADV_FEATURES("0004"), .CDC_SYNC_STAGES(3), .ECC_MODE("no_ecc"),
        .RELATED_CLOCKS(0), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(0),
        .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
    ) u_qfifo (
        .rst(fifo_rst), .wr_clk(adc_clk), .wr_en(qfifo_wr), .din(qfifo_din),
        .full(qfifo_full), .wr_data_count(qfifo_wcount),
        .rd_clk(tx_clk), .rd_en(qfifo_rd), .dout(qfifo_dout), .empty(qfifo_empty),
        .rd_data_count(),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .almost_full(), .wr_ack(), .wr_rst_busy(qfifo_wrb),
        .underflow(), .prog_empty(), .almost_empty(), .data_valid(), .rd_rst_busy(),
        .sbiterr(), .dbiterr()
    );

    // =========================================================================
    // TX domain: framer
    // =========================================================================
    localparam [2:0] T_IDLE = 3'd0, T_LEN = 3'd1, T_SUM = 3'd2, T_FOLD = 3'd3,
                     T_WAIT = 3'd4, T_SEND = 3'd5;
    reg  [2:0]  st_t;
    reg         sob_t, eob_t;
    reg  [8:0]  nw_t;                // payload words
    reg  [63:0] tsf_t;
    reg  [8:0]  beat_t;
    reg  [15:0] ip_len, udp_len, vrt_len, ip_id;
    reg  [3:0]  pkt_cnt;
    reg  [7:0]  port_k;
    reg  [15:0] dport_cur;
    reg  [19:0] sum_a;
    reg  [15:0] ip_csum;
    reg  [511:0] held_t;             // previous payload word
    reg  [31:0] pkts_t;
    reg         clr_tog_t_q;

    // Header bytes 0..57 as a little-endian byte vector (byte i at [8i+7:8i]).
    wire [31:0] vrt_w0 = {3'b000, 1'b1, 1'b0, 1'b0, sob_t, eob_t, 2'b00, 2'b01,
                          pkt_cnt, vrt_len};
    wire [463:0] hdr = {
        // bytes 57..42: VRT (little-endian words)
        tsf_t[31:0], tsf_t[63:32], sid_t, vrt_w0,
        // bytes 41..34: UDP (big-endian fields), written high byte last in this vector
        16'h0000, udp_len[7:0], udp_len[15:8], dport_cur[7:0], dport_cur[15:8],
        sport_t[7:0], sport_t[15:8],
        // bytes 33..14: IPv4
        dip_t[7:0], dip_t[15:8], dip_t[23:16], dip_t[31:24],
        sip_t[7:0], sip_t[15:8], sip_t[23:16], sip_t[31:24],
        ip_csum[7:0], ip_csum[15:8], 8'h11, 8'h40, 8'h00, 8'h40,
        ip_id[7:0], ip_id[15:8], ip_len[7:0], ip_len[15:8], 8'h00, 8'h45,
        // bytes 13..0: Ethernet
        8'h00, 8'h08,
        smac_t[7:0], smac_t[15:8], smac_t[23:16], smac_t[31:24], smac_t[39:32], smac_t[47:40],
        dmac_t[7:0], dmac_t[15:8], dmac_t[23:16], dmac_t[31:24], dmac_t[39:32], dmac_t[47:40]
    };

    // Beat j carries 58 bytes (header, or the tail of payload word j-1) and
    // then the first 6 bytes of payload word j.
    wire         data_beat = (beat_t != nw_t);
    wire [463:0] low58     = (beat_t == 9'd0) ? hdr : held_t[511:48];
    wire [47:0]  high6     = data_beat ? dfifo_dout[47:0] : 48'd0;

    assign m_axis_tdata  = {high6, low58};
    assign m_axis_tkeep  = data_beat ? {64{1'b1}} : {6'd0, {58{1'b1}}};
    assign m_axis_tlast  = (st_t == T_SEND) && !data_beat;
    assign m_axis_tvalid = (st_t == T_SEND) && (!data_beat || !dfifo_empty);
    assign m_axis_tuser  = 1'b0;

    always @(*) begin
        dfifo_rd = (st_t == T_SEND) && data_beat && m_axis_tready && !dfifo_empty;
        qfifo_rd = (st_t == T_IDLE) && !qfifo_empty;
    end

    always @(posedge tx_clk) begin
        clr_tog_t_q <= clr_tog_t;
        if (!tx_aresetn) begin
            st_t <= T_IDLE; pkt_cnt <= 4'd0; port_k <= 8'd0; ip_id <= 16'd0;
            pkts_t <= 32'd0; beat_t <= 9'd0;
        end else begin
            if (clr_tog_t != clr_tog_t_q) pkts_t <= 32'd0;
            case (st_t)
                T_IDLE: if (!qfifo_empty) begin
                    {sob_t, eob_t, nw_t, tsf_t} <= qfifo_dout;
                    st_t <= T_LEN;
                end
                T_LEN: begin
                    // payload bytes = 64*nw; UDP = 8 + 16 (VRT) + payload
                    udp_len   <= {1'b0, nw_t, 6'd0} + 16'd24;
                    ip_len    <= {1'b0, nw_t, 6'd0} + 16'd44;
                    vrt_len   <= {3'd0, nw_t, 4'd0} + 16'd4;
                    dport_cur <= dport_t + {8'd0, port_k};
                    st_t <= T_SUM;
                end
                T_SUM: begin
                    sum_a <= 20'h4500 + ip_len + ip_id + 20'h4000 + 20'h4011 +
                             sip_t[31:16] + sip_t[15:0] + dip_t[31:16] + dip_t[15:0];
                    st_t <= T_FOLD;
                end
                T_FOLD: begin
                    ip_csum <= ~(sum_a[15:0] + {12'd0, sum_a[19:16]} +
                                 ((({1'b0, sum_a[15:0]} + {13'd0, sum_a[19:16]}) >> 16)));
                    st_t <= T_WAIT;
                end
                T_WAIT: begin
                    // Every word of this packet must already be readable, so
                    // the frame can go out with no bubble.
                    beat_t <= 9'd0;
                    if (dfifo_rcount >= nw_t) st_t <= T_SEND;
                end
                T_SEND: if (m_axis_tvalid && m_axis_tready) begin
                    if (data_beat) held_t <= dfifo_dout;
                    if (!data_beat) begin
                        st_t    <= T_IDLE;
                        pkt_cnt <= pkt_cnt + 4'd1;
                        ip_id   <= ip_id + 16'd1;
                        port_k  <= (port_k + 8'd1 >= nports_t) ? 8'd0 : port_k + 8'd1;
                        pkts_t  <= pkts_t + 32'd1;
                    end
                    beat_t <= beat_t + 9'd1;
                end
                default: st_t <= T_IDLE;
            endcase
        end
    end

    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_pkts (.src_clk(tx_clk), .src_in_bin(pkts_t), .dest_clk(s_axi_aclk), .dest_out_bin(pkts_a));

endmodule

`default_nettype wire
