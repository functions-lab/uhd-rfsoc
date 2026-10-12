// udp_player -- host UDP/VRT sample packets from a CMAC -> RFDC DAC, plus ARP
// replies and async/flow-control status packets back to the host.
//
// The wire format is rfsoc_lib/uhd/PROTOCOL.md sections 6 (TX data plane) and 7
// (async status); that file is the contract with the UHD host module.
//
//   s_axis_rx  (tx_clk)  512-bit CMAC RX AXIS, byte 0 first on the wire, no
//                        tready (cannot be backpressured), tvalid may gap
//                        inside a frame, tuser on the tlast beat = bad FCS.
//   m_axis_ctl (tx_clk)  512-bit ARP replies and status packets, to be merged
//                        with udp_streamer's frames by axis_pkt_arb.
//   s_axis_dma (adc_clk) existing DMA DAC stream, passed through when dac_src=0.
//   m_axis_dac (adc_clk) M_WIDTH-bit (128, 256, 512 or 1024) converter stream, one
//                        32-bit slot (complex int16, I low, Q high) per 32
//                        bits, slot 0 from bit 0 (= sc16 LE wire order). With
//                        N channels (PROTOCOL.md 9) slot i is channel i%N,
//                        sample i/N; ch_interleave DIR=1 regroups it per
//                        channel for the block design's broadcaster.
//   adc_time   (adc_clk) udp_streamer's 64-bit timekeeper (+BEAT_TICKS per beat;
//                        the streamer's S_WIDTH must equal M_WIDTH).
//   s_axi      (s_axi_aclk) AXI4-Lite register file, map below.
//
// Data path:
//   tx_clk   parser -> URAM buffer (xpm_fifo_sync "ultra", TX_BUF_WORDS x 512)
//            + per-packet metadata FIFO. A packet is admitted only if the
//            buffer has room for all of it at its first beat (exact occupancy
//            counter, no margin); otherwise it is dropped whole and counted.
//            Payload words are written as they arrive, so a packet whose FCS
//            turns out bad is kept in the buffer but flagged: the mover pops
//            and discards its words (they still count as consumed, so the
//            host's credit stays exact).
//            mover: pops metadata, then the packet's words; every pop is one
//            consumed word (the host's flow-control credit). Words cross to
//            adc_clk in an async BRAM FIFO that carries per-word sideband
//            {first, last, sob, eob, timed, tsf}, so data and framing can
//            never disagree.
//            format conversion (FMT != sc16, PROTOCOL.md 10) is after the URAM
//            buffer, so the buffer, the credit and consumed_words all stay in
//            64-byte WIRE words: fc32 (2 words -> 1 group) in tx_clk before
//            the crossing FIFO, sc8 / sc12 (1 -> 2, 3 -> 4) in adc_clk after
//            it -- the crossing FIFO always carries the narrower stream.
//   adc_clk  playout engine: IDLE outputs zeros; the first packet of a burst
//            (SOB, or the first after idle) waits for its TSF if timed (w0
//            [21:20]==1) and starts on the (M_WIDTH/32)-slot beat containing it
//            (TIME_ERROR if that beat has passed; it then starts at once).
//            Beats play back-to-back; a dry buffer inside a burst outputs
//            zeros (UNDERFLOW once per episode) and resumes when data comes.
//            The EOB packet's last beat ends the burst (BURST_ACK).
//   tx_clk   status sender: adc events, sequence errors and flow-control
//            updates become 66-byte Ethernet/IPv4/UDP frames (PROTOCOL.md 7).
//            FC update (code 0) whenever consumed has advanced >= FC_INTERVAL
//            since the last status packet, and once after the last word of an
//            EOB packet is consumed.
//
// Register map (byte offsets):
//   0x00 ID           RO  0x5A503031 'ZP01'
//   0x04 CTRL         RW  [0] enable [1] dac_src (0 DMA pass-through, 1 player)
//                         [2] clear stats (self-clearing)
//                         [3] flush TX buffer (strobe; consumed stays monotonic,
//                             see below)
//   0x08/0x0C MY_MAC lo[31:0]/hi[15:0]   0x10 MY_IP   0x14 TX_PORT (49900)
//   0x18/0x1C HOST_MAC lo/hi              0x20 HOST_IP
//   0x24 ASYNC_PORT (49826)   0x28 SRC_PORT (49801)
//   0x2C FC_INTERVAL words (TX_BUF_WORDS/8)
//   0x30 TX_BUF_WORDS RO  host credit in 64-byte words (buffer depth minus
//                         TX_BUF_RESERVE)
//   0x34 SID (0x5A170000)
//   0x74 FMT          RW  [1:0] over-the-wire sample format (PROTOCOL.md 10):
//                         0 sc16, 1 sc8, 2 sc12, 3 fc32. Quasi-static: write
//                         it only while idle (before stream_setup_tx's flush).
//   0x78 USTART       RW  [23:0] untimed-start gate, in 64-byte words (0 = off,
//                         the reset value): a packet that starts an untimed
//                         burst (SOB, not timed) stays in the URAM until the
//                         buffer holds USTART words, or an EOB packet is in it
//                         (the whole burst has arrived), or UTIMEOUT passed.
//                         An untimed burst plays from its first word on, and
//                         at full rate the host can refill barely faster than
//                         the DAC drains, so without a lead its start
//                         underflows. Quasi-static, like FMT.
//   0x7C UTIMEOUT     RW  tx_clk cycles the gate holds at most (0 = no limit)
//   0x80 UGATED       RO  untimed starts the gate held (cleared with the stats)
//   0x84 UTIMEOUTS    RO  ... of them released by UTIMEOUT
//   stats RO: 0x40 rx_frames 0x44 rx_bad_fcs 0x48 arp_replies
//             0x4C udp_accepted 0x50 udp_dropped_overflow 0x54 seq_errors
//             0x58 underflows 0x5C late 0x60 bursts_acked 0x64 consumed_words
//             0x68 status [0] playing [1] buffer_empty
//             0x6C udp_malformed (sample packets for us with a bad length /
//                  header, or truncated)   0x70 status_pkts sent
//
// Flow-control credit (consumed_words, 0x64 and status word 5) is a free-
// running count that only a reset clears. It advances by one for every word
// popped from the URAM buffer (played, or discarded because its packet failed
// the FCS or was truncated), and it also absorbs every word the host sent that
// never reaches the buffer, so the host's in-flight count (sent - consumed)
// cannot leak:
//   * a sample packet for us (MAC, IP and TX_PORT match) that is rejected at
//     its first beat -- no room, bad length/header, player disabled, flush in
//     progress -- adds floor((w0[15:0]-4)/16), i.e. nsamps/16;
//   * a packet cut short adds the words that never arrived;
//   * a flush adds the buffer occupancy plus the unreceived rest of a packet
//     in flight, so after a flush consumed equals everything sent so far.
// The host therefore takes the consumed value at stream_setup_tx as its
// baseline instead of assuming it restarts at 0.
//
// Time is udp_streamer's tick: the timestamp of slot 0 of the ADC beat in
// the same adc_clk cycle. One slot is TICK_STEP ticks (F/2 for converter
// factor F on a single-channel build, 1 on a multi-channel build; must equal
// udp_streamer's TICK_STEP), one beat is BEAT_TICKS = (M_WIDTH/32)*TICK_STEP
// ticks. A DAC beat presented on m_axis_dac in the cycle where adc_time == T
// carries the slots of ticks T, T+TICK_STEP, .., T+BEAT_TICKS-TICK_STEP; a
// timed burst starts on the beat with T <= TSF < T + BEAT_TICKS. A 512-bit
// buffer word is always 16 slots and is played as 512/M_WIDTH beats.
//
// Over-the-wire formats (FMT; PROTOCOL.md 10). The play-out engine always
// plays 16-slot sc16 groups (512 bits); conversion happens after the URAM
// buffer, on words the mover pops (packets dropped for bad FCS / truncation
// never reach it):
//   sc16  1 word  -> 1 group   the original path, cycle for cycle
//   sc8   1 word  -> 2 groups  int16 = v * 256                    } adc_clk, after the
//   sc12  3 words -> 4 groups  int16 = v * 16, UHD sc12_item32_le } crossing FIFO
//                              unpacking (4 slots in 3 LE 32-bit lines)
//   fc32  2 words -> 1 group   int16 = round-half-even(v * 32768) saturated to
//                              [-32768, 32767]; +-inf saturate, NaN -> 0
//                              (tx_clk, 6 register stages, before the FIFO)
// sc8 / sc12 cross as wire words and the adc_clk expander feeds the engine one
// group per cycle straight from the FIFO head, so a 512-bit DAC beat every
// adc_clk cycle (4.8 GS/s at 300 MHz) plays without a bubble while the
// crossing carries only 1/2 (sc8) or 3/4 (sc12) of a word per cycle. fc32
// halves the stream before the crossing instead.
// M_WIDTH = 1024 (the sc8max builds, PROTOCOL.md 9) plays sc8 ONLY: one sc8
// word (32 slots) expands into one whole 1024-bit DAC beat, so the crossing
// FIFO delivers one word per adc_clk cycle (96 Gb/s at 187.5 MHz). sc16, sc12
// and fc32 would need more than a word per cycle: with any of them the
// play-out engine is held (zeros to the DAC, nothing consumed), and the
// daemon refuses them.
// A sample packet is well formed when its payload is 1..128 whole wire words
// (16 VRT words each) -- and, for sc12, a multiple of 3 words; otherwise it is
// counted in udp_malformed. The rejected-packet credit stays floor((w0[15:0]-4)
// /16) wire words in every format. fc32 pairs words across packet boundaries
// within a burst (fc32 packets may be an odd number of words, 8-slot
// granularity); an EOB packet ending on half a group is padded with 8 zero
// slots, so its BURST_ACK is stamped at the end of that padded group. A half
// group still pending when a new SOB packet arrives (a burst without EOB) is
// discarded.
// TX_BUF_WORDS up to 32768 (2 MiB of URAM) is supported: occupancy is 24 bits,
// consumed_words 32 bits, and 0x30 reports TX_BUF_WORDS - TX_BUF_RESERVE.
// CHAIN_STAGES x CHAIN_DEPTH words of block RAM (tx_clk) sit between the
// mover and the crossing FIFO: more play-out buffer behind the URAM. The
// host's credit still counts the URAM only (words are consumed when the mover
// pops them), so the FPGA holds TX_BUF_WORDS + CHAIN_STAGES x CHAIN_DEPTH +
// XFER_DEPTH words of samples in all. It is written in tx_clk (~1.7x the
// drain rate at a 512-bit beat), so it fills ahead of the DAC, and split into
// small stages so each one's enables reach only its own ~72 block RAMs (one
// 32768-deep FIFO missed 322 MHz).

`timescale 1ns / 1ps
`default_nettype none

module udp_player #(
    parameter integer TX_BUF_WORDS    = 16384,  // URAM buffer depth, 512-bit words (power of 2)
    parameter integer TX_BUF_RESERVE  = 16,     // depth not advertised as credit
    parameter integer META_DEPTH      = 2048,   // packets in the buffer (power of 2): with the
                                                // default credit, any packet of >= 144 samples fits
    parameter integer XFER_DEPTH      = 512,    // tx->adc FIFO, words (power of 2, >= 32)
    parameter integer CHAIN_STAGES    = 0,      // deep play-out buffer: block-RAM FIFOs in series
    parameter integer CHAIN_DEPTH     = 4096,   // words per stage (power of 2, >= 64)
    parameter integer URAM_RD_LATENCY = 4,      // raised to 5 when TX_BUF_WORDS > 16384
    parameter integer TICK_STEP       = 1,      // ticks per slot = F/2 (1 ch) (= udp_streamer's)
    parameter integer M_WIDTH         = 128     // m_axis_dac / s_axis_dma width: 128, 256, 512 or 1024 (sc8 only)
) (
    // ---- CMAC side (tx_clk = gt_txusrclk2; the CMAC RX AXIS is on it too)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis_rx:m_axis_ctl, ASSOCIATED_RESET tx_aresetn, FREQ_HZ 322265625" *)
    input  wire         tx_clk,
    input  wire         tx_aresetn,
    input  wire [511:0] s_axis_rx_tdata,
    input  wire [63:0]  s_axis_rx_tkeep,
    input  wire         s_axis_rx_tvalid,
    input  wire         s_axis_rx_tlast,
    input  wire         s_axis_rx_tuser,
    output wire [511:0] m_axis_ctl_tdata,
    output wire [63:0]  m_axis_ctl_tkeep,
    output wire         m_axis_ctl_tvalid,
    output wire         m_axis_ctl_tlast,
    output wire         m_axis_ctl_tuser,
    input  wire         m_axis_ctl_tready,

    // ---- converter side
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 adc_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis_dma:m_axis_dac, ASSOCIATED_RESET adc_aresetn" *)
    input  wire         adc_clk,
    input  wire         adc_aresetn,
    input  wire [63:0]  adc_time,
    input  wire [M_WIDTH-1:0] s_axis_dma_tdata,
    input  wire         s_axis_dma_tvalid,
    output wire         s_axis_dma_tready,
    output wire [M_WIDTH-1:0] m_axis_dac_tdata,
    output wire         m_axis_dac_tvalid,
    input  wire         m_axis_dac_tready,

    // ---- AXI4-Lite
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,
    input  wire [15:0]  s_axi_awaddr,     // only [7:0] decoded
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

    localparam [31:0] ID      = 32'h5A503031;
    localparam [31:0] CREDIT  = TX_BUF_WORDS - TX_BUF_RESERVE;
    // A buffer deeper than 16384 words cascades more URAMs: Vivado wants a
    // third output pipeline stage there (Synth 8-6013), i.e. latency >= 5.
    localparam integer UL     = (TX_BUF_WORDS > 16384 && URAM_RD_LATENCY < 5) ? 5 : URAM_RD_LATENCY;
    localparam integer XW     = 512 + 69;            // crossing FIFO width
    localparam integer MW     = 76;                  // metadata width
    localparam integer WIDE   = (M_WIDTH == 1024);   // sc8 only: one wire word per beat
    localparam integer GW     = WIDE ? 1024 : 512;   // play-out group width (bits)
    localparam integer BPW    = WIDE ? 1 : 512 / M_WIDTH;  // DAC beats per group
    localparam [63:0]  BEAT_TICKS = (M_WIDTH / 32) * TICK_STEP;   // adc_time advance per beat
    localparam [1:0]   LAST_BEAT  = BPW - 1;

    // Elaboration-time check: an unsupported width instantiates a module that
    // does not exist, so the build fails instead of mis-unpacking.
    generate if (M_WIDTH != 128 && M_WIDTH != 256 && M_WIDTH != 512 && M_WIDTH != 1024) begin : g_bad_width
        udp_player_M_WIDTH_must_be_128_256_512_or_1024 u_bad ();
    end endgenerate

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // Byte-order helpers: a big-endian field placed at the low end of a
    // little-endian byte vector (byte 0 = most significant byte).
    function [47:0] be48(input [47:0] x);
        be48 = {x[7:0], x[15:8], x[23:16], x[31:24], x[39:32], x[47:40]};
    endfunction
    function [31:0] be32(input [31:0] x);
        be32 = {x[7:0], x[15:8], x[23:16], x[31:24]};
    endfunction
    function [15:0] be16(input [15:0] x);
        be16 = {x[7:0], x[15:8]};
    endfunction

    // =========================================================================
    // AXI4-Lite register file (s_axi_aclk)
    // =========================================================================
    reg  [31:0] r_ctrl, r_mymac_lo, r_mymac_hi, r_myip, r_txport;
    reg  [31:0] r_hmac_lo, r_hmac_hi, r_hip, r_aport, r_sport, r_fcint, r_sid;
    reg  [1:0]  r_fmt;
    reg  [23:0] r_ustart;
    reg  [31:0] r_uto;
    reg         clr_toggle_a, flush_toggle_a;

    wire [31:0] st_rxf_a, st_fcs_a, st_arp_a, st_acc_a, st_ovf_a, st_seq_a;
    wire [31:0] st_und_a, st_late_a, st_ack_a, st_cons_a, st_mal_a, st_spk_a;
    wire        playing_a, bufempty_t_a, bufempty_d_a;
    wire [31:0] st_ugh_a, st_uto_a;

    reg  [7:0]  wr_addr;
    reg  [31:0] wr_data;
    reg         aw_seen, w_seen;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
            aw_seen <= 1'b0; w_seen <= 1'b0;
            r_ctrl <= 32'd0;
            r_mymac_lo <= 32'h43323136; r_mymac_hi <= 32'h0000025A;  // 02:5a:43:32:31:36
            r_myip <= 32'hC0A80502; r_txport <= 32'd49900;
            r_hmac_lo <= 32'hFFFFFFFF; r_hmac_hi <= 32'h0000FFFF;
            r_hip <= 32'hC0A80501; r_aport <= 32'd49826; r_sport <= 32'd49801;
            r_fcint <= TX_BUF_WORDS / 8; r_sid <= 32'h5A170000; r_fmt <= 2'd0;
            r_ustart <= 24'd0; r_uto <= 32'd0;
            clr_toggle_a <= 1'b0; flush_toggle_a <= 1'b0;
        end else begin
            // Accept address and data independently, act once both are held.
            if (s_axi_awvalid && !aw_seen) begin
                aw_seen <= 1'b1; wr_addr <= s_axi_awaddr[7:0]; s_axi_awready <= 1'b1;
            end else s_axi_awready <= 1'b0;
            if (s_axi_wvalid && !w_seen) begin
                w_seen <= 1'b1; wr_data <= s_axi_wdata; s_axi_wready <= 1'b1;
            end else s_axi_wready <= 1'b0;

            if (aw_seen && w_seen && !s_axi_bvalid) begin
                aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
                case (wr_addr[7:2])
                    6'h01: begin
                        r_ctrl <= wr_data & 32'h3;
                        if (wr_data[2]) clr_toggle_a   <= ~clr_toggle_a;
                        if (wr_data[3]) flush_toggle_a <= ~flush_toggle_a;
                    end
                    6'h02: r_mymac_lo <= wr_data;
                    6'h03: r_mymac_hi <= wr_data & 32'hFFFF;
                    6'h04: r_myip     <= wr_data;
                    6'h05: r_txport   <= wr_data & 32'hFFFF;
                    6'h06: r_hmac_lo  <= wr_data;
                    6'h07: r_hmac_hi  <= wr_data & 32'hFFFF;
                    6'h08: r_hip      <= wr_data;
                    6'h09: r_aport    <= wr_data & 32'hFFFF;
                    6'h0A: r_sport    <= wr_data & 32'hFFFF;
                    6'h0B: r_fcint    <= (wr_data == 32'd0) ? 32'd1 : wr_data;
                    6'h0D: r_sid      <= wr_data;
                    6'h1D: r_fmt      <= wr_data[1:0];
                    6'h1E: r_ustart   <= wr_data[23:0];
                    6'h1F: r_uto      <= wr_data;
                    default: ;
                endcase
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    reg  [7:0] rd_addr;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0;
        end else if (!s_axi_arready && !s_axi_rvalid && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;            // address handshake completes next edge
            rd_addr       <= s_axi_araddr[7:0];
        end else if (s_axi_arready) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b1;
            case (rd_addr[7:2])
                6'h00: s_axi_rdata <= ID;
                6'h01: s_axi_rdata <= r_ctrl;
                6'h02: s_axi_rdata <= r_mymac_lo;
                6'h03: s_axi_rdata <= r_mymac_hi;
                6'h04: s_axi_rdata <= r_myip;
                6'h05: s_axi_rdata <= r_txport;
                6'h06: s_axi_rdata <= r_hmac_lo;
                6'h07: s_axi_rdata <= r_hmac_hi;
                6'h08: s_axi_rdata <= r_hip;
                6'h09: s_axi_rdata <= r_aport;
                6'h0A: s_axi_rdata <= r_sport;
                6'h0B: s_axi_rdata <= r_fcint;
                6'h0C: s_axi_rdata <= CREDIT;
                6'h0D: s_axi_rdata <= r_sid;
                6'h10: s_axi_rdata <= st_rxf_a;
                6'h11: s_axi_rdata <= st_fcs_a;
                6'h12: s_axi_rdata <= st_arp_a;
                6'h13: s_axi_rdata <= st_acc_a;
                6'h14: s_axi_rdata <= st_ovf_a;
                6'h15: s_axi_rdata <= st_seq_a;
                6'h16: s_axi_rdata <= st_und_a;
                6'h17: s_axi_rdata <= st_late_a;
                6'h18: s_axi_rdata <= st_ack_a;
                6'h19: s_axi_rdata <= st_cons_a;
                6'h1A: s_axi_rdata <= {30'd0, bufempty_t_a & bufempty_d_a, playing_a};
                6'h1B: s_axi_rdata <= st_mal_a;
                6'h1C: s_axi_rdata <= st_spk_a;
                6'h1D: s_axi_rdata <= {30'd0, r_fmt};
                6'h1E: s_axi_rdata <= {8'd0, r_ustart};
                6'h1F: s_axi_rdata <= r_uto;
                6'h20: s_axi_rdata <= st_ugh_a;
                6'h21: s_axi_rdata <= st_uto_a;
                default: s_axi_rdata <= 32'd0;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Clock-domain crossings of configuration and strobes
    // =========================================================================
    // Quasi-static configuration -> tx domain
    wire [47:0] mymac_t, hmac_t;
    wire [31:0] myip_t, hip_t, sid_t, fcint_t;
    wire [15:0] txport_t, aport_t, sport_t;
    wire        en_t;
    wire [1:0]  fmt_t;
    wire [23:0] ustart_t;
    wire [31:0] uto_t;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(331))
    u_cfg_tx (.src_clk(s_axi_aclk),
              .src_in({r_mymac_hi[15:0], r_mymac_lo, r_hmac_hi[15:0], r_hmac_lo,
                       r_myip, r_hip, r_sid, r_fcint, r_txport[15:0], r_aport[15:0],
                       r_sport[15:0], r_ctrl[0], r_fmt, r_ustart, r_uto}),
              .dest_clk(tx_clk),
              .dest_out({mymac_t, hmac_t, myip_t, hip_t, sid_t, fcint_t, txport_t,
                         aport_t, sport_t, en_t, fmt_t, ustart_t, uto_t}));

    // -> adc domain: {dac_src, enable}
    wire        src_d, en_d;
    wire [1:0]  fmt_d;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .WIDTH(4))
    u_cfg_adc (.src_clk(s_axi_aclk), .src_in({r_fmt, r_ctrl[1:0]}),
               .dest_clk(adc_clk), .dest_out({fmt_d, src_d, en_d}));

    // Clear-stats and flush toggles -> both domains
    wire clr_tog_t, clr_tog_d, fl_tog_t, fl_tog_d;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_clr_t (.src_clk(s_axi_aclk), .src_in(clr_toggle_a), .dest_clk(tx_clk), .dest_out(clr_tog_t));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_clr_d (.src_clk(s_axi_aclk), .src_in(clr_toggle_a), .dest_clk(adc_clk), .dest_out(clr_tog_d));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_fl_t (.src_clk(s_axi_aclk), .src_in(flush_toggle_a), .dest_clk(tx_clk), .dest_out(fl_tog_t));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_fl_d (.src_clk(s_axi_aclk), .src_in(flush_toggle_a), .dest_clk(adc_clk), .dest_out(fl_tog_d));

    // adc_time snapshot -> tx domain (time of tx-side events), refreshed continuously
    reg         tsnap_send;
    wire        tsnap_rcv;
    reg  [63:0] tsnap_src;
    wire [63:0] tnow_t;
    always @(posedge adc_clk) begin
        if (!adc_aresetn) tsnap_send <= 1'b0;
        else if (!tsnap_send && !tsnap_rcv) begin tsnap_src <= adc_time; tsnap_send <= 1'b1; end
        else if (tsnap_send && tsnap_rcv) tsnap_send <= 1'b0;
    end
    xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .SRC_SYNC_FF(3), .WIDTH(64))
    u_tsnap (.src_clk(adc_clk), .src_in(tsnap_src), .src_send(tsnap_send), .src_rcv(tsnap_rcv),
             .dest_clk(tx_clk), .dest_req(), .dest_ack(1'b0), .dest_out(tnow_t));

    // =========================================================================
    // Resets and flush sequencing
    // =========================================================================
    // tx_clk (the CMAC user clock) only runs once software has programmed the
    // GT reference clock, while adc_clk and s_axi_aclk run from the start. An
    // XPM async FIFO must see its reset while both of its clocks run, so every
    // FIFO here is held in reset until BOTH tx_aresetn and adc_aresetn have
    // released (each crossed to the other domain with xpm_cdc_async_rst). The
    // DMA pass-through (dac_src=0) is pure adc_clk logic and needs no tx_clk.
    wire tx_rstn_d, adc_rstn_t;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(0))
    u_txrst (.src_arst(tx_aresetn), .dest_clk(adc_clk), .dest_arst(tx_rstn_d));
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4), .RST_ACTIVE_HIGH(0))
    u_adcrst (.src_arst(adc_aresetn), .dest_clk(tx_clk), .dest_arst(adc_rstn_t));

    // tx side: a flush strobe, or either reset, holds the tx-written FIFOs in
    // reset for 32 cycles and the rest of the tx logic idle until every FIFO
    // reports it is out of reset. A packet being received at that moment is
    // dropped whole (its tail is never written), and admission waits for the
    // end of every wr_rst_busy.
    reg  [5:0]  fl_cnt_t;
    reg         fl_tog_t_q, clr_tog_t_q, adc_rstn_t_q;
    wire        buf_wr_busy, meta_wr_busy, x_wr_busy;
    wire        chain_busy;      // the deep play-out chain's FIFOs still in reset
    wire        fifo_rst_t = fl_cnt_t[5];
    wire        flush_busy = (fl_cnt_t != 6'd0) || buf_wr_busy || meta_wr_busy || x_wr_busy || chain_busy;
    wire        clr_t      = (clr_tog_t != clr_tog_t_q);
    // An adc-side reset while running loses the words already in the crossing
    // FIFO, so it flushes the tx side too (same credit accounting as a flush).
    wire        fl_edge    = (fl_tog_t != fl_tog_t_q) || (adc_rstn_t_q && !adc_rstn_t);
    always @(posedge tx_clk) begin
        fl_tog_t_q   <= fl_tog_t;
        clr_tog_t_q  <= clr_tog_t;
        adc_rstn_t_q <= adc_rstn_t;
        if (!tx_aresetn || !adc_rstn_t) fl_cnt_t <= 6'd63;
        else if (fl_edge)               fl_cnt_t <= 6'd63;
        else if (fl_cnt_t != 6'd0)      fl_cnt_t <= fl_cnt_t - 6'd1;
    end

    // =========================================================================
    // TX domain: RX parser
    // =========================================================================
    // Stage 1: register the CMAC beat; track start of frame.
    reg          r1_v, r1_last, r1_user, r1_sof, r1_k57, sof_t;
    reg  [511:0] r1_d;
    always @(posedge tx_clk) begin
        if (!tx_aresetn) begin
            r1_v <= 1'b0; sof_t <= 1'b1;
        end else begin
            r1_v <= s_axis_rx_tvalid;
            if (s_axis_rx_tvalid) sof_t <= s_axis_rx_tlast;
        end
        r1_d    <= s_axis_rx_tdata;
        r1_last <= s_axis_rx_tlast;
        r1_user <= s_axis_rx_tuser;
        r1_k57  <= s_axis_rx_tkeep[57];
        r1_sof  <= sof_t;
    end

    // Stage 2: header decode of beat 0 (every header this block needs is in it).
    wire [7:0] rb [0:63];
    genvar gb;
    generate for (gb = 0; gb < 64; gb = gb + 1) begin : g_rb
        assign rb[gb] = r1_d[8*gb +: 8];
    end endgenerate

    wire [47:0] h_dmac  = {rb[0], rb[1], rb[2], rb[3], rb[4], rb[5]};
    wire [15:0] h_etype = {rb[12], rb[13]};
    wire [15:0] h_iplen = {rb[16], rb[17]};
    wire [15:0] h_frag  = {rb[20], rb[21]};
    wire [31:0] h_dip   = {rb[30], rb[31], rb[32], rb[33]};
    wire [15:0] h_dport = {rb[36], rb[37]};
    wire [15:0] h_ulen  = {rb[38], rb[39]};
    wire [31:0] h_w0    = {rb[45], rb[44], rb[43], rb[42]};
    wire [63:0] h_tsf   = {rb[53], rb[52], rb[51], rb[50], rb[57], rb[56], rb[55], rb[54]};
    wire [15:0] h_vlen  = h_w0[15:0];
    wire [15:0] h_vbytes = {h_vlen[13:0], 2'b00};

    reg          r2_v, r2_last, r2_user, r2_sof, r2_k57;
    reg  [511:0] r2_d;
    reg          f_mac, f_arp, f_udp, f_len, f_m3;
    reg  [7:0]   f_nw;
    reg  [11:0]  f_rejw;             // nsamps/16 as the host counts it, for rejects
    reg  [3:0]   f_pcnt;
    reg          f_sob, f_eob, f_timed;
    reg  [63:0]  f_tsf;
    reg  [47:0]  f_sha;
    reg  [31:0]  f_spa;
    always @(posedge tx_clk) begin
        if (!tx_aresetn) r2_v <= 1'b0;
        else             r2_v <= r1_v;
        r2_d <= r1_d; r2_last <= r1_last; r2_user <= r1_user; r2_sof <= r1_sof; r2_k57 <= r1_k57;

        f_mac  <= (h_dmac == mymac_t) || (h_dmac == 48'hFFFFFFFFFFFF);
        f_arp  <= (h_etype == 16'h0806) && ({rb[14], rb[15]} == 16'h0001) &&
                  ({rb[16], rb[17]} == 16'h0800) && (rb[18] == 8'd6) && (rb[19] == 8'd4) &&
                  ({rb[20], rb[21]} == 16'h0001) &&
                  ({rb[38], rb[39], rb[40], rb[41]} == myip_t);
        f_udp  <= (h_etype == 16'h0800) && (rb[14] == 8'h45) && (rb[23] == 8'h11) &&
                  ((h_frag & 16'h3FFF) == 16'h0000) && (h_dip == myip_t) &&
                  (h_dport == txport_t);
        // VRT: IF data with SID, no class ID, no trailer; 4-word header and
        // a multiple of 16 samples, 16..2048; UDP and IP lengths consistent.
        f_len  <= (h_w0[31:28] == 4'h1) && (h_w0[27:26] == 2'b00) &&
                  (h_vlen[3:0] == 4'h4) && (h_vlen[15:4] != 12'd0) && (h_vlen[15:4] <= 12'd128) &&
                  (h_ulen == h_vbytes + 16'd8) && (h_iplen == h_vbytes + 16'd28);
        f_m3    <= (h_vlen[11:4] % 8'd3) == 8'd0;    // sc12: whole 3-word units
        f_nw    <= h_vlen[11:4];
        f_rejw  <= (h_vlen < 16'd4) ? 12'd0 : h_vlen[15:4] - {11'd0, (h_vlen[3:0] < 4'd4)};
        f_pcnt  <= h_w0[19:16];
        f_sob   <= h_w0[25];
        f_eob   <= h_w0[24];
        f_timed <= (h_w0[21:20] == 2'b01);
        f_tsf   <= h_tsf;
        f_sha   <= {rb[22], rb[23], rb[24], rb[25], rb[26], rb[27]};
        f_spa   <= {rb[28], rb[29], rb[30], rb[31]};
    end

    // Stage 3: frame FSM, buffer writes.
    localparam [1:0] K_NONE = 2'd0, K_DATA = 2'd1, K_ARP = 2'd2;
    reg  [1:0]  kind;
    reg         seqk;
    reg  [7:0]  nw_r, wc_r;
    reg         short_r;
    reg  [47:0] prev6;
    reg  [3:0]  pcnt_r;
    reg         sob_r, eob_r, timed_r;
    reg  [63:0] tsf_r;
    reg  [3:0]  exp_pcnt;
    reg         have_exp;

    reg  [23:0] occ_t;                // words written (or being written) and not yet popped
    reg  [15:0] meta_cnt;
    wire        buf_rd, meta_rd;

    wire        is_data  = f_udp && f_mac && en_t && !flush_busy;
    wire        f_ok     = f_len && (fmt_t != 2'd2 || f_m3);   // length valid for FMT
    wire        room     = ({8'd0, occ_t} + {24'd0, f_nw} <= CREDIT) &&
                           (meta_cnt < META_DEPTH - 8);
    wire [1:0]  new_kind = (f_arp && f_mac) ? K_ARP :
                           (is_data && f_ok && room) ? K_DATA : K_NONE;
    wire [1:0]  kind_eff = r2_sof ? new_kind : kind;
    wire        seqk_eff = r2_sof ? (is_data && f_ok) : seqk;
    wire [3:0]  pcnt_eff = r2_sof ? f_pcnt : pcnt_r;

    wire        wr_now   = r2_v && !r2_sof && (kind == K_DATA) && (wc_r != nw_r) && !flush_busy;
    wire [7:0]  wc_next  = wc_r + {7'd0, wr_now};
    wire        short_now = short_r || (wr_now && (wc_r + 8'd1 == nw_r) && !r2_k57);
    wire        fin      = r2_v && r2_last;
    wire        fin_data = fin && !r2_sof && (kind == K_DATA) && !flush_busy;
    wire        fin_bad  = r2_user || (wc_next != nw_r) || short_now;
    wire        meta_push = fin_data && (wc_next != 8'd0);
    // Words the host counted as sent that will never be popped (see header).
    wire        rej_sof  = r2_v && r2_sof && f_udp && f_mac && (new_kind != K_DATA);
    wire [11:0] rej_now  = rej_sof ? f_rejw :
                           (fin_data && !fl_edge) ? {4'd0, nw_r - wc_next} : 12'd0;
    wire [7:0]  rx_pend  = (kind == K_DATA) ? (nw_r - wc_r) : 8'd0;
    reg  [11:0] rej_add;

    // buffer write port, one register stage
    reg          bw_en, mw_en;
    reg  [511:0] bw_din;
    reg  [MW-1:0] mw_din;            // {drop, sob, eob, timed, tsf[63:0], nwords[7:0]}

    // stats and pulses to the status sender
    reg  [31:0] c_rxf, c_fcs, c_acc, c_ovf, c_seq, c_mal;
    reg         arp_new, seq_new;
    reg  [47:0] arp_new_sha, sha_r;
    reg  [31:0] arp_new_spa, spa_r;

    always @(posedge tx_clk) begin
        bw_en   <= wr_now;
        bw_din  <= {r2_d[463:0], prev6};
        mw_en   <= meta_push;
        mw_din  <= {fin_bad, sob_r, eob_r, timed_r, tsf_r, wc_next};
        rej_add <= tx_aresetn ? rej_now : 12'd0;
        arp_new <= 1'b0;
        seq_new <= 1'b0;

        if (!tx_aresetn) begin
            kind <= K_NONE; seqk <= 1'b0; have_exp <= 1'b0;
            c_rxf <= 32'd0; c_fcs <= 32'd0; c_acc <= 32'd0; c_ovf <= 32'd0;
            c_seq <= 32'd0; c_mal <= 32'd0;
        end else begin
            if (r2_v) begin
                prev6 <= r2_d[511:464];
                if (r2_sof) begin
                    kind    <= new_kind;
                    seqk    <= is_data && f_ok;
                    nw_r    <= f_nw;
                    wc_r    <= 8'd0;
                    short_r <= 1'b0;
                    pcnt_r  <= f_pcnt;
                    sob_r   <= f_sob;
                    eob_r   <= f_eob;
                    timed_r <= f_timed;
                    tsf_r   <= f_tsf;
                    sha_r   <= f_sha;
                    spa_r   <= f_spa;
                    if (is_data && !f_ok)       c_mal <= c_mal + 32'd1;
                    else if (is_data && !room)  c_ovf <= c_ovf + 32'd1;
                end else begin
                    wc_r    <= wc_next;
                    short_r <= short_now;
                end
                if (fin) begin
                    kind <= K_NONE;
                    seqk <= 1'b0;
                    c_rxf <= c_rxf + 32'd1;
                    if (r2_user) c_fcs <= c_fcs + 32'd1;
                    if (fin_data) begin
                        if (!fin_bad)                         c_acc <= c_acc + 32'd1;
                        else if (!r2_user)                    c_mal <= c_mal + 32'd1;
                    end
                    if (kind_eff == K_ARP && !r2_user) begin
                        arp_new     <= 1'b1;
                        arp_new_sha <= r2_sof ? f_sha : sha_r;   // header beat's fields
                        arp_new_spa <= r2_sof ? f_spa : spa_r;
                    end
                    // Packet-count continuity over every well-formed sample
                    // packet for us that arrived intact (dropped or not).
                    if (seqk_eff && !r2_user) begin
                        if (have_exp && pcnt_eff != exp_pcnt) begin
                            c_seq   <= c_seq + 32'd1;
                            seq_new <= 1'b1;
                        end
                        exp_pcnt <= pcnt_eff + 4'd1;
                        have_exp <= 1'b1;
                    end
                end
            end
            if (flush_busy) begin
                kind <= K_NONE; seqk <= 1'b0; have_exp <= 1'b0;
            end
            if (clr_t) begin
                c_rxf <= 32'd0; c_fcs <= 32'd0; c_acc <= 32'd0; c_ovf <= 32'd0;
                c_seq <= 32'd0; c_mal <= 32'd0;
            end
        end
    end

    // =========================================================================
    // TX buffer (URAM) and packet metadata
    // =========================================================================
    wire [511:0]   buf_dout;
    wire           buf_empty;
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("ultra"), .FIFO_WRITE_DEPTH(TX_BUF_WORDS),
        .WRITE_DATA_WIDTH(512), .READ_DATA_WIDTH(512),
        .READ_MODE("std"), .FIFO_READ_LATENCY(UL),
        .USE_ADV_FEATURES("0000"), .ECC_MODE("no_ecc"),
        .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(0),
        .PROG_FULL_THRESH(10), .PROG_EMPTY_THRESH(10),
        .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1),
        .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
    ) u_buf (
        .rst(!tx_aresetn || fifo_rst_t), .wr_clk(tx_clk),
        .wr_en(bw_en), .din(bw_din), .full(), .wr_rst_busy(buf_wr_busy),
        .rd_en(buf_rd), .dout(buf_dout), .empty(buf_empty), .rd_rst_busy(),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(),
        .underflow(), .prog_empty(), .rd_data_count(), .almost_empty(), .data_valid(),
        .sbiterr(), .dbiterr()
    );

    wire [MW-1:0]  meta_dout;
    wire           meta_empty;
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(META_DEPTH),
        .WRITE_DATA_WIDTH(MW), .READ_DATA_WIDTH(MW),
        .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES("0000"), .ECC_MODE("no_ecc"),
        .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(0),
        .PROG_FULL_THRESH(10), .PROG_EMPTY_THRESH(10),
        .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1),
        .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
    ) u_meta (
        .rst(!tx_aresetn || fifo_rst_t), .wr_clk(tx_clk),
        .wr_en(mw_en), .din(mw_din), .full(), .wr_rst_busy(meta_wr_busy),
        .rd_en(meta_rd), .dout(meta_dout), .empty(meta_empty), .rd_rst_busy(),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(),
        .underflow(), .prog_empty(), .rd_data_count(), .almost_empty(), .data_valid(),
        .sbiterr(), .dbiterr()
    );

    // =========================================================================
    // TX domain: mover (URAM -> crossing FIFO), consumed-word count
    // =========================================================================
    reg          mv_act, mv_drop, mv_sob, mv_eob, mv_timed, mv_first;
    reg  [63:0]  mv_tsf;
    reg  [7:0]   mv_cnt;
    reg  [31:0]  consumed_t;
    reg          eob_hit;
    wire         x_pfull;

    // Untimed-start gate (USTART / UTIMEOUT): the metadata FIFO head starts an
    // untimed burst ({drop, sob, eob, timed, ...}: sob, not timed, not
    // dropped); hold it until the URAM holds USTART words, an EOB packet is in
    // the FIFO (its words are all in the URAM: metadata is written after the
    // packet's last word), or UTIMEOUT cycles have passed.
    reg  [15:0]  eob_pend;               // non-dropped EOB packets in the metadata FIFO
    reg  [31:0]  ug_cnt;                 // cycles the head has been held
    reg  [31:0]  c_ugh, c_uto;           // gated starts / released by the timeout
    wire         ug_on    = (ustart_t != 24'd0);
    wire         ug_head  = !meta_empty && meta_dout[MW-2] && !meta_dout[MW-4] && !meta_dout[MW-1];
    wire         ug_fill  = (occ_t >= ustart_t) || (eob_pend != 16'd0);
    wire         ug_tout  = (uto_t != 32'd0) && (ug_cnt >= uto_t);
    wire         ug_pass  = !ug_on || !ug_head || ug_fill || ug_tout;
    assign meta_rd = !mv_act && !meta_empty && !flush_busy && ug_pass;

    always @(posedge tx_clk) begin
        if (!tx_aresetn || flush_busy) begin
            eob_pend <= 16'd0; ug_cnt <= 32'd0;
        end else begin
            eob_pend <= eob_pend + {15'd0, mw_en && mw_din[MW-3] && !mw_din[MW-1]}
                                 - {15'd0, meta_rd && meta_dout[MW-3] && !meta_dout[MW-1]};
            ug_cnt   <= (!mv_act && ug_on && ug_head && !meta_rd) ? ug_cnt + 32'd1 : 32'd0;
        end
        if (!tx_aresetn || clr_t) begin
            c_ugh <= 32'd0; c_uto <= 32'd0;
        end else if (meta_rd && ug_on && ug_head) begin
            c_ugh <= c_ugh + 32'd1;
            if (!ug_fill) c_uto <= c_uto + 32'd1;
        end
    end
    wire   mv_issue = mv_act && !buf_empty && (mv_drop || !x_pfull) && !flush_busy;
    assign buf_rd   = mv_issue;

    // Sideband travels alongside the URAM read latency.
    reg  [UL-1:0]  pv;
    reg  [68:0]    pf [0:UL-1];        // {tsf, timed, eob, sob, last, first}
    integer        pi;

    always @(posedge tx_clk) begin
        eob_hit <= 1'b0;
        pv <= {pv[UL-2:0], mv_issue && !mv_drop};
        pf[0] <= {mv_tsf, mv_timed, mv_eob, mv_sob, (mv_cnt == 8'd1), mv_first};
        for (pi = 1; pi < UL; pi = pi + 1) pf[pi] <= pf[pi-1];

        if (!tx_aresetn)
            consumed_t <= 32'd0;
        else if (fl_edge)      // occ_t already holds a word popped this cycle
            consumed_t <= consumed_t + {8'd0, occ_t} + {24'd0, rx_pend} + {20'd0, rej_add};
        else
            consumed_t <= consumed_t + {31'd0, mv_issue} + {20'd0, rej_add};

        if (!tx_aresetn || flush_busy) begin
            mv_act <= 1'b0; pv <= {UL{1'b0}};
            occ_t <= 24'd0; meta_cnt <= 16'd0;
        end else begin
            occ_t    <= occ_t + {23'd0, wr_now} - {23'd0, buf_rd};
            meta_cnt <= meta_cnt + {15'd0, mw_en} - {15'd0, meta_rd};   // the FIFO's own write
            if (meta_rd) begin
                mv_act   <= 1'b1;
                {mv_drop, mv_sob, mv_eob, mv_timed, mv_tsf, mv_cnt} <= meta_dout;
                mv_first <= 1'b1;
            end
            if (mv_issue) begin
                mv_cnt     <= mv_cnt - 8'd1;
                mv_first   <= 1'b0;

                if (mv_cnt == 8'd1) begin
                    mv_act <= 1'b0;
                    if (mv_eob && !mv_drop) eob_hit <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // fc32 converter (tx_clk): two wire words -> one sc16 group, before the
    // crossing FIFO (it halves what crosses). sc8 / sc12 cross as wire words
    // and are expanded in adc_clk (below). Input: the URAM word in the cycle
    // pv[UL-1] is set, sideband pf[UL-1] = {tsf[63:0], timed, eob, sob, last,
    // first}.
    // -------------------------------------------------------------------------
    wire          isf_t = (fmt_t == 2'd3);

    reg          c1_v;
    reg  [511:0] c1_d;
    reg  [68:0]  c1_sb;
    reg          o_v;                // output group
    reg  [511:0] o_d;
    reg  [68:0]  o_sb;

    // float32 -> int16 in five stages. With e the biased exponent,
    // |v * 32768| = {1, m} * 2^(e - 135): e >= 127 saturates, e < 111 is < 0.5
    // and gives 0, else the integer part is {1, m} >> (135 - e) (9..24).
    reg          f1_v, f2_v, f3_v, f4_v, f5_v;
    reg  [68:0]  f1_sb, f2_sb, f3_sb, f4_sb, f5_sb;
    reg  [15:0]  f1_s, f1_nan, f1_big, f1_small;
    reg  [79:0]  f1_sh;              // 16 x 5
    reg  [383:0] f1_m;               // 16 x 24
    reg  [15:0]  f2_s, f2_zero, f2_big;
    reg  [47:0]  f2_sh;              // 16 x 3
    reg  [767:0] f2_t;               // 16 x 48
    reg  [15:0]  f3_s, f3_zero, f3_big, f3_inc;
    reg  [255:0] f3_mag;
    reg  [15:0]  f4_s, f4_zero, f4_big;
    reg  [255:0] f4_r;
    reg  [255:0] f5_d;               // 8 slots of sc16
    reg          fp_v;               // half group waiting for its partner
    reg  [255:0] fp_d;
    reg  [68:0]  fp_sb;

    genvar gf;
    generate for (gf = 0; gf < 16; gf = gf + 1) begin : g_f2i
        wire [31:0] f  = c1_d[32*gf +: 32];
        wire [7:0]  e  = f[30:23];
        wire [4:0]  sh = 8'd135 - e;
        wire [47:0] t2 = f2_t[48*gf +: 48] >> f2_sh[3*gf +: 3];
        wire [15:0] mg = t2[39:24];
        wire        gd = t2[23];
        wire        st = |t2[22:0];
        wire [15:0] r  = f4_r[16*gf +: 16];
        always @(posedge tx_clk) begin
            f1_s[gf]     <= f[31];
            f1_nan[gf]   <= (e == 8'hFF) && (f[22:0] != 23'd0);
            f1_big[gf]   <= (e >= 8'd127) && !((e == 8'hFF) && (f[22:0] != 23'd0));
            f1_small[gf] <= (e < 8'd111);
            f1_sh[5*gf +: 5]   <= sh;
            f1_m[24*gf +: 24]  <= {1'b1, f[22:0]};

            f2_s[gf]    <= f1_s[gf];
            f2_zero[gf] <= f1_nan[gf] || f1_small[gf];
            f2_big[gf]  <= f1_big[gf];
            f2_sh[3*gf +: 3]  <= f1_sh[5*gf +: 3];
            f2_t[48*gf +: 48] <= {f1_m[24*gf +: 24], 24'd0} >> {f1_sh[5*gf + 3 +: 2], 3'd0};

            f3_s[gf] <= f2_s[gf]; f3_zero[gf] <= f2_zero[gf]; f3_big[gf] <= f2_big[gf];
            f3_mag[16*gf +: 16] <= mg;
            f3_inc[gf] <= gd && (st || mg[0]);           // round half to even

            f4_s[gf] <= f3_s[gf]; f4_zero[gf] <= f3_zero[gf]; f4_big[gf] <= f3_big[gf];
            f4_r[16*gf +: 16] <= f3_mag[16*gf +: 16] + {15'd0, f3_inc[gf]};   // <= 32768

            f5_d[16*gf +: 16] <= f4_zero[gf] ? 16'h0000 :
                                 (f4_big[gf] || (!f4_s[gf] && r[15])) ? (f4_s[gf] ? 16'h8000 : 16'h7FFF) :
                                 f4_s[gf] ? (~r + 16'd1) : r;
        end
    end endgenerate

    always @(posedge tx_clk) begin
        c1_d <= buf_dout; c1_sb <= pf[UL-1];
        f1_sb <= c1_sb; f2_sb <= f1_sb; f3_sb <= f2_sb; f4_sb <= f3_sb; f5_sb <= f4_sb;
        if (!tx_aresetn || flush_busy) begin
            c1_v <= 1'b0; o_v <= 1'b0; fp_v <= 1'b0;
            f1_v <= 1'b0; f2_v <= 1'b0; f3_v <= 1'b0; f4_v <= 1'b0; f5_v <= 1'b0;
        end else begin
            c1_v <= pv[UL-1] && isf_t;
            f1_v <= c1_v;
            f2_v <= f1_v; f3_v <= f2_v; f4_v <= f3_v; f5_v <= f4_v;
            o_v  <= 1'b0;
            if (f5_v) begin                                    // pairing
                if (fp_v && !(f5_sb[0] && f5_sb[2])) begin
                    o_v  <= 1'b1;
                    o_d  <= {f5_d, fp_d};
                    o_sb <= {fp_sb[68:4], f5_sb[3], fp_sb[2], f5_sb[1], fp_sb[0]};
                    fp_v <= 1'b0;
                end else if (f5_sb[1] && f5_sb[3]) begin       // EOB packet ends on half a group
                    o_v  <= 1'b1;
                    o_d  <= {256'd0, f5_d};
                    o_sb <= f5_sb;
                    fp_v <= 1'b0;
                end else begin
                    fp_v <= 1'b1; fp_d <= f5_d; fp_sb <= f5_sb;
                end
            end
        end
    end

    // What the mover / converter emits, with per-word sideband.
    wire          x_wr   = isf_t ? o_v : pv[UL-1];
    wire [XW-1:0] x_din  = isf_t ? {o_sb, o_d} : {pf[UL-1], buf_dout};

    // Deep play-out buffer (CHAIN_STAGES fwft FIFOs in series, tx_clk), then
    // the crossing FIFO. x_pfull throttles the mover on the chain's head.
    wire          xx_wr;            // into the crossing FIFO
    wire [XW-1:0] xx_din;
    wire          xx_pfull;         // the crossing FIFO's prog_full
    wire          chain_empty;
    generate if (CHAIN_STAGES == 0) begin : g_nochain
        assign xx_wr       = x_wr;
        assign xx_din      = x_din;
        assign x_pfull     = xx_pfull;
        assign chain_empty = 1'b1;
        assign chain_busy  = 1'b0;
    end else begin : g_chain
        // Registered between stages (and on the chain's input and output): a
        // stage's block-RAM output reaches the next stage's (or the crossing
        // FIFO's) input through one flop, not a long route between RAMs. A
        // stage reads only while the next one was below prog_full a cycle ago
        // (16 words of slack), so the words in flight always fit.
        wire [CHAIN_STAGES-1:0] st_empty, st_full, st_pfull, st_wbusy, st_rbusy, st_rd;
        wire [XW-1:0]           st_dout [0:CHAIN_STAGES-1];
        reg  [CHAIN_STAGES:0]   q_v;                    // q[k]: into stage k (k = STAGES: crossing FIFO)
        reg  [XW-1:0]           q_d [0:CHAIN_STAGES];
        wire                    c_rst = !tx_aresetn || fifo_rst_t;
        // one registered reset copy per stage: the flush reset otherwise fans
        // out from fl_cnt_t to every block RAM of the chain in one cycle
        // (missed 322 MHz); a cycle later is harmless, flush_busy waits for
        // the stages' reset-busy flags anyway
        (* max_fanout = 64 *) reg [CHAIN_STAGES-1:0] c_rst_q;
        always @(posedge tx_clk) c_rst_q <= {CHAIN_STAGES{c_rst}};
        integer                 qi;
        always @(posedge tx_clk) begin
            q_d[0] <= x_din;
            for (qi = 1; qi <= CHAIN_STAGES; qi = qi + 1) q_d[qi] <= st_dout[qi-1];
            if (c_rst) q_v <= {(CHAIN_STAGES+1){1'b0}};
            else       q_v <= {st_rd, x_wr};
        end
        genvar k;
        for (k = 0; k < CHAIN_STAGES; k = k + 1) begin : g_st
            // "the next FIFO has room", registered: the next stage's
            // prog_full / reset-busy reached this stage's block-RAM read
            // enable combinationally, across two RAM sites (4ch F=3 missed
            // 322 MHz by 0.14 ns on it). One cycle late is covered by the
            // 16 words of slack below prog_full.
            reg nx_ok;
            if (k < CHAIN_STAGES - 1) begin : g_next
                always @(posedge tx_clk) nx_ok <= !c_rst && !st_pfull[k+1] && !st_wbusy[k+1];
            end else begin : g_last
                always @(posedge tx_clk) nx_ok <= !c_rst && !xx_pfull && !x_wr_busy;
            end
            assign st_rd[k] = !st_empty[k] && !st_rbusy[k] && nx_ok;
            xpm_fifo_sync #(
                .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(CHAIN_DEPTH),
                .WRITE_DATA_WIDTH(XW), .READ_DATA_WIDTH(XW),
                .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
                .USE_ADV_FEATURES("0002"), .PROG_FULL_THRESH(CHAIN_DEPTH - 16),
                .PROG_EMPTY_THRESH(10), .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1),
                .ECC_MODE("no_ecc"), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1),
                .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
            ) u_st (
                .rst(c_rst_q[k]), .wr_clk(tx_clk),
                .wr_en(q_v[k]), .din(q_d[k]), .full(st_full[k]), .prog_full(st_pfull[k]),
                .wr_rst_busy(st_wbusy[k]), .rd_en(st_rd[k]), .dout(st_dout[k]),
                .empty(st_empty[k]), .rd_rst_busy(st_rbusy[k]),
                .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
                .overflow(), .wr_data_count(), .almost_full(), .wr_ack(),
                .underflow(), .prog_empty(), .rd_data_count(), .almost_empty(), .data_valid(),
                .sbiterr(), .dbiterr()
            );
        end
        assign xx_wr       = q_v[CHAIN_STAGES];
        assign xx_din      = q_d[CHAIN_STAGES];
        assign x_pfull     = st_pfull[0] || st_wbusy[0];
        // busy / empty registered: they only gate flush and the empty status,
        // where clearing a cycle late is conservative (the wide OR of the
        // stages' reset-busy flags otherwise sat in u_meta's write enable)
        reg cb_q, ce_q;
        always @(posedge tx_clk) begin
            cb_q <= (|st_wbusy) || (|st_rbusy);
            ce_q <= (&st_empty) && !(|q_v);
        end
        assign chain_empty = ce_q;
        assign chain_busy  = cb_q;
    end endgenerate
    wire [XW-1:0] xq_dout;
    wire          xq_empty, xq_rd, xf_rd, x_rd, x_rd_busy;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(XFER_DEPTH),
        .WRITE_DATA_WIDTH(XW), .READ_DATA_WIDTH(XW),
        .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES("0002"), .PROG_FULL_THRESH(XFER_DEPTH - 16),
        .PROG_EMPTY_THRESH(10), .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1),
        .CDC_SYNC_STAGES(3), .ECC_MODE("no_ecc"), .RELATED_CLOCKS(0),
        .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1), .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
    ) u_xfer (
        .rst(!tx_aresetn || fifo_rst_t), .wr_clk(tx_clk), .wr_en(xx_wr), .din(xx_din),
        .full(), .prog_full(xx_pfull), .wr_rst_busy(x_wr_busy),
        .rd_clk(adc_clk), .rd_en(xq_rd), .dout(xq_dout), .empty(xq_empty), .rd_rst_busy(x_rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .wr_data_count(), .almost_full(), .wr_ack(),
        .underflow(), .prog_empty(), .rd_data_count(), .almost_empty(), .data_valid(),
        .sbiterr(), .dbiterr()
    );

    // =========================================================================
    // ADC domain: playout engine
    // =========================================================================
    localparam [1:0] P_IDLE = 2'd0, P_WAIT = 2'd1, P_PLAY = 2'd2;
    reg  [1:0]   pst;
    reg  [1:0]   bi;                   // beat within the head word (0..BPW-1)
    reg  [63:0]  w_tsf;
    reg          starving;
    reg  [M_WIDTH-1:0] dac_q;
    reg  [63:0]  t_cmp, t_cmp4;
    reg  [7:0]   fl_cnt_d;
    reg          fl_tog_d_q, clr_tog_d_q;
    reg  [31:0]  c_und, c_late, c_ack;
    reg          ev_wr;
    reg  [71:0]  ev_din;               // {code[7:0], time[63:0]}

    // -------------------------------------------------------------------------
    // sc8 / sc12 expander (adc_clk): the crossing FIFO holds wire words; the
    // play-out engine below reads 16-slot sc16 groups (x_*, x_rd), one per
    // cycle at most. sc8: one word = two groups (e_h selects the half), the
    // word is popped with its second group. sc12: 3 words = 4 groups; each
    // pop keeps the word's unused tail in e_hr, so the fourth group comes from
    // e_hr alone and the unit pops 3 words for 4 groups. Both sustain a group
    // every cycle from the FIFO head (FWFT) with no bubble. sc16 and fc32 (the
    // tx-side converter already wrote groups) pass straight through.
    // -------------------------------------------------------------------------
    function [511:0] exp8(input [255:0] b);          // 16 slots of {Q8, I8}
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1)
                exp8[32*j +: 32] = {b[16*j + 8 +: 8], 8'd0, b[16*j +: 8], 8'd0};
        end
    endfunction
    // UHD unpack (convert_sc12_item32_3_to_star_4, integer output): per 3 LE
    // lines, I0 = l0[31:20] Q0 = l0[19:8] I1 = {l0[7:0], l1[31:28]}
    // Q1 = l1[27:16] I2 = l1[15:4] Q2 = {l1[3:0], l2[31:24]} I3 = l2[23:12]
    // Q3 = l2[11:0]; int16 = v << 4.
    function [511:0] unp12(input [383:0] g);
        integer j;
        reg [31:0] l0, l1, l2;
        begin
            for (j = 0; j < 4; j = j + 1) begin
                l0 = g[96*j +: 32]; l1 = g[96*j + 32 +: 32]; l2 = g[96*j + 64 +: 32];
                unp12[128*j      +: 32] = {l0[19:8], 4'd0, l0[31:20], 4'd0};
                unp12[128*j + 32 +: 32] = {l1[27:16], 4'd0, l0[7:0], l1[31:28], 4'd0};
                unp12[128*j + 64 +: 32] = {l1[3:0], l2[31:24], 4'd0, l1[15:4], 4'd0};
                unp12[128*j + 96 +: 32] = {l2[11:0], 4'd0, l2[23:12], 4'd0};
            end
        end
    endfunction

    // sc8 / sc12 read the FIFO through a one-word prefetch register, so the
    // expander and the play-out decisions start from flip-flops rather than
    // the BRAM output (one more cycle of latency; it still loads a word every
    // cycle, more than the 1/2 or 3/4 word per cycle those formats need).
    // sc16 and fc32 read the FIFO head directly, as before.
    reg          is8_d, is12_d, use_pf;   // quasi-static FMT, decoded into flops
    always @(posedge adc_clk) begin
        is8_d  <= (fmt_d == 2'd1);
        is12_d <= (fmt_d == 2'd2);
        use_pf <= (fmt_d == 2'd1) || (fmt_d == 2'd2);
    end
    wire         xq_avail = !xq_empty && !x_rd_busy;
    reg          pf_v;
    reg  [XW-1:0] pf_q;
    wire         pf_load = use_pf && xq_avail && (!pf_v || xf_rd);
    assign       xq_rd   = use_pf ? pf_load : xf_rd;
    // expander inputs: the prefetched word (sc8 / sc12 only)
    wire [511:0] xf_data  = pf_q[511:0];
    wire [68:0]  xf_sb    = pf_q[580:512];         // {tsf, timed, eob, sob, last, first}
    reg          e_h;                // sc8: the head word's second group is next
    reg  [1:0]   e_q;                // sc12: group within the 4-group unit
    reg  [383:0] e_hr;               // sc12: bytes of the unit not yet played
    reg  [68:0]  e_sb3;              // sc12: sideband of the unit's third word
    // a packet's first word always starts a unit (packets are whole units)
    wire [1:0]   e_qe = (e_q != 2'd3 && xf_sb[0]) ? 2'd0 : e_q;
    wire [383:0] e_g12 = (e_qe == 2'd0) ? xf_data[383:0] :
                         (e_qe == 2'd1) ? {xf_data[255:0], e_hr[127:0]} :
                         (e_qe == 2'd2) ? {xf_data[127:0], e_hr[255:0]} : e_hr;
    wire [68:0]  e_sb = (is8_d && WIDE) ? xf_sb :
                        is8_d ? {xf_sb[68:2], xf_sb[1] & e_h, xf_sb[0] & !e_h} :
                        (e_qe == 2'd3) ? {e_sb3[68:2], e_sb3[1], 1'b0} :
                                         {xf_sb[68:2], 1'b0, xf_sb[0] & (e_qe == 2'd0)};
    wire [GW-1:0] e_data;
    generate if (WIDE) begin : g_e_wide        // the whole word, 32 slots
        assign e_data = {exp8(xf_data[511:256]), exp8(xf_data[255:0])};
    end else begin : g_e_norm
        assign e_data = is8_d ? exp8(e_h ? xf_data[511:256] : xf_data[255:0]) : unp12(e_g12);
    end endgenerate
    wire         e_avail = pf_v || (is12_d && e_q == 2'd3);

    // what the play-out engine sees: the expander, or (sc16, fc32) the FIFO
    // head directly -- one 2:1 mux on the original path
    wire         x_avail = use_pf ? e_avail : xq_avail;
    wire [GW-1:0] x_data;
    generate if (WIDE) begin : g_x_wide      // (only sc8 plays at 1024)
        assign x_data = e_data;
    end else begin : g_x_norm
        assign x_data = use_pf ? e_data : xq_dout[511:0];
    end endgenerate
    wire [68:0]  x_sbw   = use_pf ? e_sb    : xq_dout[580:512];
    wire         x_first = x_sbw[0];
    wire         x_last  = x_sbw[1];
    wire         x_sob   = x_sbw[2];
    wire         x_eob   = x_sbw[3];
    wire         x_timed = x_sbw[4];
    wire [63:0]  x_tsf   = x_sbw[68:5];
    // the FIFO pops with the word's last group
    assign xf_rd = x_rd && (!use_pf || (is8_d ? (e_h || WIDE) : (e_qe != 2'd3)));

    always @(posedge adc_clk) begin
        if (pf_load) pf_q <= xq_dout;
        if (!adc_aresetn || !tx_rstn_d || (fl_cnt_d != 8'd0) || x_rd_busy || !use_pf)
            pf_v <= 1'b0;
        else if (pf_load)
            pf_v <= 1'b1;
        else if (xf_rd)
            pf_v <= 1'b0;
        if (!adc_aresetn || !tx_rstn_d || (fl_cnt_d != 8'd0) || x_rd_busy) begin
            e_h <= 1'b0; e_q <= 2'd0;
        end else if (x_rd) begin
            e_h <= !e_h;
            e_q <= (e_qe == 2'd3) ? 2'd0 : e_qe + 2'd1;
        end
        if (x_rd && is12_d) begin
            if (e_qe == 2'd0) e_hr[127:0] <= xf_data[511:384];
            if (e_qe == 2'd1) e_hr[255:0] <= xf_data[511:256];
            if (e_qe == 2'd2) begin e_hr <= xf_data[511:128]; e_sb3 <= xf_sb; end
        end
    end

    // (M_WIDTH 1024 plays sc8 only: any other FMT holds the engine)
    wire         hold  = !en_d || !tx_rstn_d || (fl_cnt_d != 8'd0) || x_rd_busy ||
                         (WIDE && !is8_d);
    wire         adv   = !src_d || m_axis_dac_tready;
    // t_cmp is the tick of the beat that the decision made in this cycle
    // puts on m_axis_dac (one output register, one register on adc_time).
    wire         t_hit  = (w_tsf < t_cmp4);
    wire         t_late = (w_tsf < t_cmp);

    reg          emit;
    always @(*) begin
        emit = 1'b0;
        if (!hold && adv) case (pst)
            P_IDLE: emit = x_avail && !(x_first && x_timed);
            P_WAIT: emit = x_avail && t_hit;
            P_PLAY: emit = x_avail && !(x_first && x_sob && x_timed && bi == 2'd0);
            default: emit = 1'b0;
        endcase
    end
    assign x_rd = emit && (bi == LAST_BEAT);

    always @(posedge adc_clk) begin
        fl_tog_d_q  <= fl_tog_d;
        clr_tog_d_q <= clr_tog_d;
        t_cmp  <= adc_time + 2 * BEAT_TICKS;      // two beats of pipeline
        t_cmp4 <= adc_time + 3 * BEAT_TICKS;      // end of that beat
        ev_wr  <= 1'b0;

        if (!adc_aresetn || !tx_rstn_d)  fl_cnt_d <= 8'd255;
        else if (fl_tog_d != fl_tog_d_q) fl_cnt_d <= 8'd255;
        else if (fl_cnt_d != 8'd0)       fl_cnt_d <= fl_cnt_d - 8'd1;

        if (!adc_aresetn) begin
            pst <= P_IDLE; bi <= 2'd0; starving <= 1'b0; dac_q <= {M_WIDTH{1'b0}};
            c_und <= 32'd0; c_late <= 32'd0; c_ack <= 32'd0;
        end else begin
            if (hold) begin
                pst <= P_IDLE; bi <= 2'd0; starving <= 1'b0;
                if (adv) dac_q <= {M_WIDTH{1'b0}};
            end else if (adv) begin
                if (emit) begin
                    dac_q    <= x_data[M_WIDTH*bi +: M_WIDTH];
                    bi       <= (bi == LAST_BEAT) ? 2'd0 : bi + 2'd1;
                    starving <= 1'b0;
                end else begin
                    dac_q    <= {M_WIDTH{1'b0}};
                end
                case (pst)
                    P_IDLE: if (x_avail) begin
                        if (x_first && x_timed) begin
                            w_tsf <= x_tsf;
                            pst   <= P_WAIT;
                        end else begin
                            pst   <= P_PLAY;
                        end
                    end
                    P_WAIT: if (emit) begin
                        pst <= P_PLAY;
                        if (t_late) begin
                            c_late <= c_late + 32'd1;
                            ev_wr  <= 1'b1;
                            ev_din <= {8'h08, t_cmp};
                        end
                    end
                    P_PLAY: if (!x_avail) begin
                        starving <= 1'b1;
                        if (!starving) begin
                            c_und  <= c_und + 32'd1;
                            ev_wr  <= 1'b1;
                            ev_din <= {8'h02, t_cmp};
                        end
                    end else if (!emit) begin
                        // SOB+timed without a preceding EOB: a new timed burst
                        w_tsf    <= x_tsf;
                        pst      <= P_WAIT;
                        starving <= 1'b0;
                    end
                    default: pst <= P_IDLE;
                endcase
                if (x_rd && x_last && x_eob) begin
                    pst    <= P_IDLE;
                    c_ack  <= c_ack + 32'd1;
                    ev_wr  <= 1'b1;
                    ev_din <= {8'h01, t_cmp};
                end
            end
            if (clr_tog_d != clr_tog_d_q) begin
                c_und <= 32'd0; c_late <= 32'd0; c_ack <= 32'd0;
            end
        end
    end

    assign m_axis_dac_tdata  = src_d ? dac_q : s_axis_dma_tdata;
    assign m_axis_dac_tvalid = src_d ? 1'b1  : s_axis_dma_tvalid;
    assign s_axis_dma_tready = src_d ? 1'b1  : m_axis_dac_tready;   // drained while the player owns the DAC

    // Events adc -> tx
    wire [71:0] ev_dout;
    wire        ev_empty, ev_full, ev_wr_busy, ev_rd_busy;
    reg         ev_rd;
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16),
        .WRITE_DATA_WIDTH(72), .READ_DATA_WIDTH(72),
        .READ_MODE("fwft"), .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES("0000"), .CDC_SYNC_STAGES(3), .ECC_MODE("no_ecc"),
        .RELATED_CLOCKS(0), .DOUT_RESET_VALUE("0"), .FULL_RESET_VALUE(1),
        .PROG_FULL_THRESH(10), .PROG_EMPTY_THRESH(10),
        .WR_DATA_COUNT_WIDTH(1), .RD_DATA_COUNT_WIDTH(1),
        .SIM_ASSERT_CHK(0), .WAKEUP_TIME(0)
    ) u_ev (
        .rst(!adc_aresetn || !tx_rstn_d), .wr_clk(adc_clk),
        .wr_en(ev_wr && !ev_full && !ev_wr_busy), .din(ev_din),
        .full(ev_full), .wr_rst_busy(ev_wr_busy),
        .rd_clk(tx_clk), .rd_en(ev_rd), .dout(ev_dout), .empty(ev_empty), .rd_rst_busy(ev_rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .overflow(), .prog_full(), .wr_data_count(), .almost_full(), .wr_ack(),
        .underflow(), .prog_empty(), .rd_data_count(), .almost_empty(), .data_valid(),
        .sbiterr(), .dbiterr()
    );

    // =========================================================================
    // TX domain: ARP replies and status packets on m_axis_ctl
    // =========================================================================
    localparam [2:0] C_IDLE = 3'd0, C_SUM = 3'd1, C_FOLD = 3'd2, C_B0 = 3'd3,
                     C_B1 = 3'd4, C_ARP = 3'd5;
    reg  [2:0]  st_c;
    reg         arp_pend, seq_pend, eob_fc;
    reg  [47:0] arp_tha;
    reg  [31:0] arp_tpa;
    reg  [63:0] seq_time;
    reg  [7:0]  s_code;
    reg  [63:0] s_tsf;
    reg  [31:0] s_cons, last_rep;
    reg  [15:0] ip_id_c, csum_c;
    reg  [19:0] sum_c;
    reg  [31:0] c_arp, c_spk;

    // fc_need is registered (the 32-bit subtract and compare would otherwise
    // sit in front of the status FSM's enables); it is one cycle old, which
    // only delays an FC update by a cycle: the FSM spends >= 4 cycles per
    // status packet, so a stale value can never send one twice.
    wire [31:0] cons_diff = consumed_t - last_rep;
    reg         fc_need;
    always @(posedge tx_clk)
        fc_need <= (consumed_t != last_rep) && ((cons_diff >= fcint_t) || eob_fc);
    wire        ev_avail  = !ev_empty && !ev_rd_busy;
    wire        go_ev     = en_t && ev_avail;
    wire        go_seq    = en_t && !go_ev && seq_pend;
    wire        go_fc     = en_t && !go_ev && !seq_pend && fc_need && !flush_busy;
    wire        go_st     = (st_c == C_IDLE) && !arp_pend && (go_ev || go_seq || go_fc);

    // = go_st && go_ev, written without the flow-control terms it cannot
    // depend on (keeps the consumed-count compare off the FIFO read enable)
    always @(*) ev_rd = (st_c == C_IDLE) && !arp_pend && go_ev;

    // Status frame, 66 bytes, byte 0 at bits [7:0].
    wire [527:0] sp = {
        s_cons, {24'd0, s_code}, s_tsf[31:0], s_tsf[63:32], sid_t, 32'h5A17A5C0,  // 65..42
        16'h0000, be16(16'd32), be16(aport_t), be16(sport_t),                        // 41..34 UDP
        be32(hip_t), be32(myip_t), be16(csum_c), 8'h11, 8'h40, be16(16'h4000),       // 33..20
        be16(ip_id_c), be16(16'd52), 8'h00, 8'h45,                                   // 19..14
        be16(16'h0800), be48(mymac_t), be48(hmac_t)                                  // 13..0
    };
    // ARP reply, 60 bytes.
    wire [479:0] ap = {
        144'd0,                                                                    // 59..42 pad
        be32(arp_tpa), be48(arp_tha), be32(myip_t), be48(mymac_t),                 // 41..22
        be16(16'h0002), 8'h04, 8'h06, be16(16'h0800), be16(16'h0001),              // 21..14
        be16(16'h0806), be48(mymac_t), be48(arp_tha)                               // 13..0
    };

    assign m_axis_ctl_tvalid = (st_c == C_B0) || (st_c == C_B1) || (st_c == C_ARP);
    assign m_axis_ctl_tlast  = (st_c == C_B1) || (st_c == C_ARP);
    assign m_axis_ctl_tuser  = 1'b0;
    assign m_axis_ctl_tdata  = (st_c == C_ARP) ? {32'd0, ap} :
                               (st_c == C_B1)  ? {496'd0, sp[527:512]} : sp[511:0];
    assign m_axis_ctl_tkeep  = (st_c == C_ARP) ? {4'h0, {60{1'b1}}} :
                               (st_c == C_B1)  ? 64'h3 : {64{1'b1}};
    wire   ctl_hs = m_axis_ctl_tvalid && m_axis_ctl_tready;

    always @(posedge tx_clk) begin
        if (!tx_aresetn) begin
            st_c <= C_IDLE; arp_pend <= 1'b0; seq_pend <= 1'b0; eob_fc <= 1'b0;
            last_rep <= 32'd0; ip_id_c <= 16'd0; c_arp <= 32'd0; c_spk <= 32'd0;
        end else begin
            if (arp_new && !arp_pend) begin   // one outstanding reply; ARP retries
                arp_pend <= 1'b1; arp_tha <= arp_new_sha; arp_tpa <= arp_new_spa;
            end
            if (seq_new) begin seq_pend <= 1'b1; seq_time <= tnow_t; end
            if (eob_hit) eob_fc <= 1'b1;

            case (st_c)
                C_IDLE: begin
                    if (arp_pend) st_c <= C_ARP;
                    else if (go_st) begin
                        s_code <= go_ev ? ev_dout[71:64] : go_seq ? 8'h04 : 8'h00;
                        s_tsf  <= go_ev ? ev_dout[63:0]  : go_seq ? seq_time : tnow_t;
                        s_cons   <= consumed_t;
                        last_rep <= consumed_t;
                        if (!eob_hit) eob_fc <= 1'b0;
                        if (go_seq && !seq_new) seq_pend <= 1'b0;
                        st_c <= C_SUM;
                    end
                end
                C_SUM: begin
                    sum_c <= 20'h4500 + 20'd52 + {4'd0, ip_id_c} + 20'h4000 + 20'h4011 +
                             {4'd0, myip_t[31:16]} + {4'd0, myip_t[15:0]} +
                             {4'd0, hip_t[31:16]} + {4'd0, hip_t[15:0]};
                    st_c <= C_FOLD;
                end
                C_FOLD: begin
                    csum_c <= ~(sum_c[15:0] + {12'd0, sum_c[19:16]} +
                                {15'd0, (({1'b0, sum_c[15:0]} + {13'd0, sum_c[19:16]}) >> 16)});
                    st_c <= C_B0;
                end
                C_B0:  if (ctl_hs) st_c <= C_B1;
                C_B1:  if (ctl_hs) begin
                    st_c <= C_IDLE; ip_id_c <= ip_id_c + 16'd1; c_spk <= c_spk + 32'd1;
                end
                C_ARP: if (ctl_hs) begin
                    st_c <= C_IDLE; arp_pend <= 1'b0; c_arp <= c_arp + 32'd1;
                end
                default: st_c <= C_IDLE;
            endcase

            if (flush_busy) begin
                eob_fc <= 1'b0; seq_pend <= 1'b0;
            end
            if (clr_t) begin c_arp <= 32'd0; c_spk <= 32'd0; end
        end
    end

    // =========================================================================
    // Stats and status -> axi domain
    // =========================================================================
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s0 (.src_clk(tx_clk), .src_in_bin(c_rxf), .dest_clk(s_axi_aclk), .dest_out_bin(st_rxf_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s1 (.src_clk(tx_clk), .src_in_bin(c_fcs), .dest_clk(s_axi_aclk), .dest_out_bin(st_fcs_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s2 (.src_clk(tx_clk), .src_in_bin(c_arp), .dest_clk(s_axi_aclk), .dest_out_bin(st_arp_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s3 (.src_clk(tx_clk), .src_in_bin(c_acc), .dest_clk(s_axi_aclk), .dest_out_bin(st_acc_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s4 (.src_clk(tx_clk), .src_in_bin(c_ovf), .dest_clk(s_axi_aclk), .dest_out_bin(st_ovf_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s5 (.src_clk(tx_clk), .src_in_bin(c_seq), .dest_clk(s_axi_aclk), .dest_out_bin(st_seq_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s6 (.src_clk(adc_clk), .src_in_bin(c_und), .dest_clk(s_axi_aclk), .dest_out_bin(st_und_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s7 (.src_clk(adc_clk), .src_in_bin(c_late), .dest_clk(s_axi_aclk), .dest_out_bin(st_late_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s8 (.src_clk(adc_clk), .src_in_bin(c_ack), .dest_clk(s_axi_aclk), .dest_out_bin(st_ack_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s9 (.src_clk(tx_clk), .src_in_bin(consumed_t), .dest_clk(s_axi_aclk), .dest_out_bin(st_cons_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s10 (.src_clk(tx_clk), .src_in_bin(c_mal), .dest_clk(s_axi_aclk), .dest_out_bin(st_mal_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s11 (.src_clk(tx_clk), .src_in_bin(c_spk), .dest_clk(s_axi_aclk), .dest_out_bin(st_spk_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s12 (.src_clk(tx_clk), .src_in_bin(c_ugh), .dest_clk(s_axi_aclk), .dest_out_bin(st_ugh_a));
    xpm_cdc_gray #(.DEST_SYNC_FF(3), .WIDTH(32), .REG_OUTPUT(1))
    u_s13 (.src_clk(tx_clk), .src_in_bin(c_uto), .dest_clk(s_axi_aclk), .dest_out_bin(st_uto_a));

    wire playing_d = (pst != P_IDLE);
    wire bufempty_d = xq_empty && !pf_v && !(is12_d && e_q == 2'd3);
    reg  bufempty_t;
    // (the format converter's registers count too: an fc32 half group waits
    // there for its partner)
    wire conv_busy = c1_v || f1_v || f2_v || f3_v || f4_v || f5_v || o_v || fp_v;
    always @(posedge tx_clk) bufempty_t <= (occ_t == 24'd0) && (meta_cnt == 16'd0) && !mv_act &&
                                           !conv_busy && chain_empty;
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_st0 (.src_clk(adc_clk), .src_in(playing_d), .dest_clk(s_axi_aclk), .dest_out(playing_a));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1))
    u_st1 (.src_clk(adc_clk), .src_in(bufempty_d), .dest_clk(s_axi_aclk), .dest_out(bufempty_d_a));
    xpm_cdc_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(0))
    u_st2 (.src_clk(tx_clk), .src_in(bufempty_t), .dest_clk(s_axi_aclk), .dest_out(bufempty_t_a));

endmodule

`default_nettype wire
