################################################################
# zcu208_uhd_v49.tcl -- the ZCU208 as a UHD device over 100 GbE
# (rfsoc_lib/uhd): the v49 block design for every channel count
# N = 1, 2, factor F and sample rate fs.
#
# Self-contained: this file and zcu208_uhd_v49.xdc in the same directory are
# the whole design. Sourced into a Vivado 2021.1 project for the ZCU208
# (xczu48dr-fsvg1517-2-e) whose IP repository path holds the packaged UHD
# cores user.org:uhd:*:1.0 (hw_design/ip/uhd_ip, `make package` in
# hw_design/ip_design/uhd_ip) and the dual RF-ADC I/Q joiners
# user.org:user:dual_rf_adc_iq_merger:1.0 (N = 1) and
# user.org:user:dual_channel_rf_adc_iq_packer:1.0 (N = 2) (hw_design/ip/iprepo);
# everything else is Xilinx IP. The CMAC and its GT cannot sit in a block
# design: the RTL top that scripts/v49_build.tcl generates instantiates
# hw_design/ip_design/cmac_100g next to it.
#
# Parameters (Tcl globals, set before sourcing; scripts/v49_build.tcl sets them):
#   V49_NCH          channel count N: 1 or 2 (required)
#   V49_FACTOR       RFDC converter factor F, a v49_geometry row of N
#                    (default: N's first row)
#   V49_FS           converter sample rate fs, MS/s (default 5000)
#   V49_DEFINE_ONLY  1: define the v49_* procs and return without building
# The block design is named zcu208_v49_<N>ch_qsfp.
#
# The ZCU208's RF-ADC tiles are DUAL: in I/Q mode each converter delivers I
# and Q on two AXIS streams (m<t><2k> = I, m<t><2k+1> = Q, Data_Width samples
# each). The rfdc hierarchy joins them into one complex stream, I in
# the low 16 bits of each 32-bit slot: dual_rf_adc_iq_merger (N = 1) or
# dual_channel_rf_adc_iq_packer (N = 2, channel-major: channel 0's slots, then
# channel 1's), both width-generic (C_S_AXIS_TDATA_WIDTH = 16 x samples). The
# DACs take I/Q interleaved on one stream (Data_Width = 2 x samples): N = 1
# feeds DAC tile 2 block 0 directly, N = 2 splits the channel-major beat with
# axis_broadcaster_0. Channel map (the converter cabling):
#   channel 0: DAC tile 2 block 0 (s20, vout20)  <-  ADC tile 2 (m20 I, m21 Q, vin2_01)
#   channel 1: DAC tile 0 block 0 (s00, vout00)  <-  ADC tile 0 (m02 I, m03 Q, vin0_23)
#
# eth100g sits on rfdc/M_ADC_AXIS and rfdc/S_DAC_AXIS (channel-major for N =
# 2), with the ch_interleave IP re-ordering the 32-bit slots to/from the
# sample-major wire order:
#
#   rfdc/M_ADC_AXIS -> rx_beamformer -> adc_c2s (DIR 0) -> udp_streamer
#   udp_player      -> dac_s2c (DIR 1) -> tx_beamformer -> rfdc/S_DAC_AXIS
#
# Both beamformers (rfsoc_lib/uhd/PROTOCOL.md section 11; IP user.org:uhd:
# {tx,rx}_beamformer:1.0, sources ip_design/uhd_ip/src) work on the
# channel-major beat, bypass by default:
#   tx_beamformer  channel 0 x w[c] to every DAC c. AXI-Lite 0x8006_0000.
#                  PIPE = 1 (pipelined math, 5-cycle latency) above a 150 MHz
#                  converter clock, 0 (the v47 IP unchanged, 3 cycles)
#                  otherwise: v49_geometry bf_pipe.
#   rx_beamformer  channel 0 = sat16(round(sum_c x_c w[c] >> (15+SHIFT))),
#                  channels 1..N-1 unchanged. AXI-Lite 0x8007_0000. Latency
#                  7 + log2(N) cycles.
# (N = 1: no interleave, no beamformers.) The interleave permutes whenever a beat holds more
# than one sample per channel (Data_Width 4 or 8 with N > 1); with one sample
# per channel per beat the two layouts coincide and it is wires. The cores'
# pass-through ports are tied off: udp_streamer m_axis_adc (a copy of the ADC
# stream) is unused with tready = 1, udp_player s_axis_dma (an alternative
# DAC source) is idle with tvalid = 0, so dac_src = 0 plays silence.
#
#   udp_streamer (ADC frames) + udp_player (ARP/status) -> axis_pkt_arb -> cmac_100g TX
#   cmac_100g RX -> udp_player (ARP requests, TX sample packets)
#
# Wire format and control: rfsoc_lib/uhd/PROTOCOL.md. Addresses (AXI-Lite, pl_clk0):
#   0x8002_0000  eth100g/udp_streamer   ADC -> UDP (map in udp_streamer.v)
#   0x8003_0000  eth100g/udp_player     UDP -> DAC, ARP, flow control (udp_player.v)
# udp_streamer, udp_player, axis_pkt_arb and ch_interleave are packaged IP
# (user.org:uhd:<core>:1.0) in hw_design/ip/uhd_ip; their sources, testbenches
# and packaging script are in hw_design/ip_design/uhd_ip.
#   0x8004_0000  eth100g/cmac_gpio      ch1 = cmac ctl (out, default 0xF003: GT held
#                                        in reset), ch2 = cmac status (in); bits in
#                                        ip_design/cmac_100g/cmac_100g.v
#   0x8005_0000  eth100g/cmac_freq      ch1 = GT refclk kHz, ch2 = CMAC user clock kHz
#                                        (expect 156250 and 322266 once the 8A34001 runs)
#   0x8006_0000  eth100g/tx_beamformer  N >= 2 only: TX beamformer (PROTOCOL.md 11)
#   0x8007_0000  eth100g/rx_beamformer  N >= 2 only: RX beamformer (PROTOCOL.md 11)
# The CMAC and its split-quad GT wizard cannot live in the block design:
# neither cmac_usplus nor gtwizard_ultrascale may sit inside a module
# reference (filemgmt 56-181), and the GT sites the board needs are outside
# what the IP's "GT in core" can reach. So ip_design/cmac_100g/cmac_100g.v is instantiated in
# the RTL top (generated by v49_build.tcl's v49_gen_top from the BD wrapper) and the BD exports:
#   cmac_usr_clk / cmac_usr_rstn   CMAC user clock and reset (in)
#   cmac_tx / cmac_rx              512-bit AXIS to / from the CMAC
#   cmac_ctl / cmac_status         the GPIO words (bits in cmac_100g.v)
#   cmac_init_clk                  pl_clk0, the CMAC init/DRP clock (out)
#
# Clocks: adc_clk = MTS_block/dac_clk (= adc_clk: one MTS_clk_wiz output; the converter
# AXIS clock fs/F/S, v49_geometry), tx_clk = CMAC
# gt_txusrclk2 (322.265625 MHz, runs only once the 8A34001 refclk is valid),
# s_axi/init = pl_clk0 (100 MHz).
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

# FPGA TX sample buffer of udp_player (URAM, 512-bit words): 32768 words =
# 2 MiB = 64 of the xczu48dr's 80 URAM288. META_DEPTH scales with it so the
# packet-count limit stays where the default sizing put it (any packet of
# >= 144 sc16 samples can fill the whole credit).
# XFER_DEPTH: the tx_clk -> converter-clock crossing FIFO (512 words).
# CHAIN_STAGES x CHAIN_DEPTH: udp_player's deep play-out chain of block-RAM
# FIFOs between the URAM and the crossing FIFO, in tx_clk. The host's credit
# still counts the URAM only, so the chain adds play-out buffer behind it. The
# Every build gets 8 x 4096 words = 2 MiB more (~576 of the 1080 BRAM36):
# 4 MiB in all, ~350 us at 96 Gb/s against host stalls instead of ~175 us.
# One 32768-deep crossing FIFO instead missed timing (its enables span ~576
# block RAMs: -1.1 ns at 300/322 MHz); small stages keep each one local. The
# chain runs on tx_clk (322 MHz), so the converter clock does not matter.
proc v49_tx_buffer {} {
  set chain 8
  return [dict create TX_BUF_WORDS 32768 META_DEPTH 4096 XFER_DEPTH 512 \
              CHAIN_STAGES $chain CHAIN_DEPTH 4096]
}

proc create_hier_cell_eth100g { parentCell nameHier {nch 1} {beat_w 128} {bf_pipe 0} } {
  set oldCurInst [current_bd_instance .]
  current_bd_instance [get_bd_cells $parentCell]
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # ---- hierarchy pins
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_ADC
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_DAC
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_STREAMER
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_PLAYER
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_GPIO
  create_bd_pin -dir I -type clk adc_clk
  create_bd_pin -dir I -type rst adc_aresetn
  create_bd_pin -dir I -type clk s_axi_aclk
  create_bd_pin -dir I -type rst s_axi_aresetn
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_CMAC_TX
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_CMAC_RX
  create_bd_pin -dir I -type clk usr_clk
  create_bd_pin -dir I -type rst usr_rstn
  create_bd_pin -dir O -from 31 -to 0 cmac_ctl
  create_bd_pin -dir I -from 31 -to 0 cmac_status
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_FREQ
  create_bd_pin -dir I -from 31 -to 0 refclk_khz
  create_bd_pin -dir I -from 31 -to 0 usrclk_khz

  # ---- cells
  set us   [create_bd_cell -type ip -vlnv user.org:uhd:udp_streamer:1.0 udp_streamer]
  set up   [create_bd_cell -type ip -vlnv user.org:uhd:udp_player:1.0   udp_player]
  set arb  [create_bd_cell -type ip -vlnv user.org:uhd:axis_pkt_arb:1.0 axis_pkt_arb]
  set tb [v49_tx_buffer]
  set_property -dict [list CONFIG.TX_BUF_WORDS [dict get $tb TX_BUF_WORDS] \
                           CONFIG.META_DEPTH   [dict get $tb META_DEPTH] \
                           CONFIG.XFER_DEPTH   [dict get $tb XFER_DEPTH] \
                           CONFIG.CHAIN_STAGES [dict get $tb CHAIN_STAGES] \
                           CONFIG.CHAIN_DEPTH  [dict get $tb CHAIN_DEPTH]] $up

  set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 cmac_gpio]
  set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_DOUT_DEFAULT {0x0000F003} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1} \
  ] $gpio

  # Measured GT refclk / CMAC user clock (kHz): ch1 refclk, ch2 usr_clk
  set fgpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 cmac_freq]
  set_property -dict [list CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1}] $fgpio
  connect_bd_intf_net [get_bd_intf_pins S_AXI_FREQ] [get_bd_intf_pins cmac_freq/S_AXI]
  connect_bd_net [get_bd_pins refclk_khz] [get_bd_pins cmac_freq/gpio_io_i]
  connect_bd_net [get_bd_pins usrclk_khz] [get_bd_pins cmac_freq/gpio2_io_i]

  # (no zSFP28 TX_DISABLE_B: the ZCU208 board files do not give those pins. A
  # passive DAC cable ignores it; an optical module would need them driven high.)

  # ---- streams
  # beat width of the combined converter stream (PROTOCOL.md section 9)
  set_property CONFIG.S_WIDTH $beat_w [get_bd_cells udp_streamer]
  set_property CONFIG.M_WIDTH $beat_w [get_bd_cells udp_player]
  if {$nch == 1} {
    connect_bd_intf_net [get_bd_intf_pins S_AXIS_ADC] [get_bd_intf_pins udp_streamer/s_axis]
    connect_bd_intf_net [get_bd_intf_pins udp_player/m_axis_dac] [get_bd_intf_pins M_AXIS_DAC]
  } else {
    # channel-major (rfdc joiner/broadcaster) <-> sample-major
    # (udp_streamer / udp_player, the wire order)
    foreach {name dir} {adc_c2s 0 dac_s2c 1} {
      set c [create_bd_cell -type ip -vlnv user.org:uhd:ch_interleave:1.0 $name]
      set_property -dict [list CONFIG.N_CH $nch CONFIG.BEAT_W $beat_w CONFIG.DIR $dir] $c
      connect_bd_net [get_bd_pins adc_clk] [get_bd_pins $name/aclk]
    }
    # RX beamformer on the channel-major beat, between the ADC combiner and
    # the interleave
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_RBF
    set rbf [create_bd_cell -type ip -vlnv user.org:uhd:rx_beamformer:1.0 rx_beamformer]
    set_property -dict [list CONFIG.N_CH $nch CONFIG.BEAT_W $beat_w] $rbf
    connect_bd_intf_net [get_bd_intf_pins S_AXIS_ADC]            [get_bd_intf_pins rx_beamformer/s_axis]
    connect_bd_intf_net [get_bd_intf_pins rx_beamformer/m_axis]  [get_bd_intf_pins adc_c2s/s_axis]
    connect_bd_intf_net [get_bd_intf_pins S_AXI_RBF]             [get_bd_intf_pins rx_beamformer/s_axi]
    connect_bd_net [get_bd_pins adc_clk]       [get_bd_pins rx_beamformer/aclk]
    connect_bd_net [get_bd_pins adc_aresetn]   [get_bd_pins rx_beamformer/aresetn]
    connect_bd_net [get_bd_pins s_axi_aclk]    [get_bd_pins rx_beamformer/s_axi_aclk]
    connect_bd_net [get_bd_pins s_axi_aresetn] [get_bd_pins rx_beamformer/s_axi_aresetn]
    connect_bd_intf_net [get_bd_intf_pins adc_c2s/m_axis]        [get_bd_intf_pins udp_streamer/s_axis]
    connect_bd_intf_net [get_bd_intf_pins udp_player/m_axis_dac] [get_bd_intf_pins dac_s2c/s_axis]
    # TX beamformer on the channel-major beat, between the player and the
    # DAC broadcaster
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_BF
    set bf [create_bd_cell -type ip -vlnv user.org:uhd:tx_beamformer:1.0 tx_beamformer]
    set_property -dict [list CONFIG.N_CH $nch CONFIG.BEAT_W $beat_w CONFIG.PIPE $bf_pipe] $bf
    connect_bd_intf_net [get_bd_intf_pins dac_s2c/m_axis]        [get_bd_intf_pins tx_beamformer/s_axis]
    connect_bd_intf_net [get_bd_intf_pins tx_beamformer/m_axis]  [get_bd_intf_pins M_AXIS_DAC]
    connect_bd_intf_net [get_bd_intf_pins S_AXI_BF]              [get_bd_intf_pins tx_beamformer/s_axi]
    connect_bd_net [get_bd_pins adc_clk]       [get_bd_pins tx_beamformer/aclk]
    connect_bd_net [get_bd_pins adc_aresetn]   [get_bd_pins tx_beamformer/aresetn]
    connect_bd_net [get_bd_pins s_axi_aclk]    [get_bd_pins tx_beamformer/s_axi_aclk]
    connect_bd_net [get_bd_pins s_axi_aresetn] [get_bd_pins tx_beamformer/s_axi_aresetn]
  }
  # pass-through ports unused: no ADC copy sink, no alternative DAC source
  set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 adc_tready_one]
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
  set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 dma_tvalid_zero]
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $zero
  connect_bd_net [get_bd_pins adc_tready_one/dout]  [get_bd_pins udp_streamer/m_axis_adc_tready]
  connect_bd_net [get_bd_pins dma_tvalid_zero/dout] [get_bd_pins udp_player/s_axis_dma_tvalid]
  connect_bd_intf_net [get_bd_intf_pins udp_streamer/m_axis] [get_bd_intf_pins axis_pkt_arb/s0_axis]
  connect_bd_intf_net [get_bd_intf_pins udp_player/m_axis_ctl] [get_bd_intf_pins axis_pkt_arb/s1_axis]
  connect_bd_intf_net [get_bd_intf_pins axis_pkt_arb/m_axis] [get_bd_intf_pins M_AXIS_CMAC_TX]
  connect_bd_intf_net [get_bd_intf_pins S_AXIS_CMAC_RX] [get_bd_intf_pins udp_player/s_axis_rx]
  connect_bd_intf_net [get_bd_intf_pins S_AXI_STREAMER] [get_bd_intf_pins udp_streamer/s_axi]
  connect_bd_intf_net [get_bd_intf_pins S_AXI_PLAYER]   [get_bd_intf_pins udp_player/s_axi]
  connect_bd_intf_net [get_bd_intf_pins S_AXI_GPIO]     [get_bd_intf_pins cmac_gpio/S_AXI]

  # ---- clocks and resets
  connect_bd_net [get_bd_pins adc_clk] [get_bd_pins udp_streamer/adc_clk] [get_bd_pins udp_player/adc_clk]
  connect_bd_net [get_bd_pins adc_aresetn] [get_bd_pins udp_streamer/adc_aresetn] [get_bd_pins udp_player/adc_aresetn]
  connect_bd_net [get_bd_pins s_axi_aclk] [get_bd_pins udp_streamer/s_axi_aclk] [get_bd_pins udp_player/s_axi_aclk] \
                 [get_bd_pins cmac_gpio/s_axi_aclk] [get_bd_pins cmac_freq/s_axi_aclk]
  connect_bd_net [get_bd_pins s_axi_aresetn] [get_bd_pins udp_streamer/s_axi_aresetn] [get_bd_pins udp_player/s_axi_aresetn] \
                 [get_bd_pins cmac_gpio/s_axi_aresetn] [get_bd_pins cmac_freq/s_axi_aresetn]
  connect_bd_net [get_bd_pins usr_clk] [get_bd_pins udp_streamer/tx_clk] [get_bd_pins udp_player/tx_clk] \
                 [get_bd_pins axis_pkt_arb/clk]
  connect_bd_net [get_bd_pins usr_rstn] [get_bd_pins udp_streamer/tx_aresetn] [get_bd_pins udp_player/tx_aresetn] \
                 [get_bd_pins axis_pkt_arb/aresetn]

  # ---- shared time base, CMAC control/status
  connect_bd_net [get_bd_pins udp_streamer/adc_time] [get_bd_pins udp_player/adc_time]
  connect_bd_net [get_bd_pins cmac_gpio/gpio_io_o] [get_bd_pins cmac_ctl]
  connect_bd_net [get_bd_pins cmac_status] [get_bd_pins cmac_gpio/gpio2_io_i]
  set aligned [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 cmac_aligned]
  set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0}] $aligned
  set txen [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 cmac_txen]
  set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {27} CONFIG.DIN_TO {27}] $txen
  connect_bd_net [get_bd_pins cmac_status] [get_bd_pins cmac_aligned/Din] [get_bd_pins cmac_txen/Din]
  connect_bd_net [get_bd_pins cmac_aligned/Dout] [get_bd_pins udp_streamer/cmac_rx_aligned]
  connect_bd_net [get_bd_pins cmac_txen/Dout] [get_bd_pins udp_streamer/cmac_tx_ready]


  current_bd_instance $oldCurInst
}

# The eth100g AXI-Lite slaves, in the order they follow the four base
# masters on axi_interconnect_pl (and the address map: 0x8002_0000 ..)
proc v49_eth100g_slaves {nch} {
  set s {S_AXI_STREAMER S_AXI_PLAYER S_AXI_GPIO S_AXI_FREQ}
  if {$nch > 1} { lappend s S_AXI_BF S_AXI_RBF }
  return $s
}

# Converter geometry per channel count N (rfsoc_lib/uhd/PROTOCOL.md section 9).
# The factor F is a BLOCK DESIGN parameter (never a run-time one), set on
# EVERY ADC and DAC slice. S = complex samples per
# channel per converter clock:
#   ADC (dual tile, I/Q on two streams)  Data_Width = S per stream
#   DAC (I/Q interleaved on one stream)  Data_Width = 2 S
#   Fabric_Freq = fs / F / S  ==  MTS_clk_wiz clk_out1, the converter AXIS
#   clock of the whole design; beat_w = N x 32 x S, the S_WIDTH / M_WIDTH of
#   udp_streamer / udp_player.
# Converters sample at fs = V49_FS (5000 MS/s on every v49 ZCU208 build: the
# dual RF-ADC's maximum; DACs at the same fs), tile PLLs bypassed: every tile
# takes the fs MHz LMX2594 output (rfsoc_lib/xrfclk/ZCU208/LMX2594_250.0_5000.0.txt).
#
#   N  family   F                                  S  beat   fabric = fs/F/S   per-channel rate
#   1  normal   2 3 4 5 6 8 10 12 16 20 24 40       8  256 b  312.5 .. 15.6 MHz  2500 .. 125 MS/s
#   2  normal   4 5 6 8 10 12 16 20 24 40           4  256 b  312.5 .. 31.3 MHz  1250 .. 125 MS/s
#   2  sc8max   2                                   8  512 b  312.5 MHz          2500 MS/s, sc8 only
#
# The normal family's top rate is the highest whose sc16 stream fits the 100G
# link (1ch 2500 MS/s and 2ch 2 x 1250 MS/s: 80 Gb/s each); sc8max is 2x the
# 2ch maximum in sc8 (80 Gb/s). Builds are named
# zcu208_v49_<N>ch_qsfp_f<F>_fs<fs> (scripts/v49_ladder.sh lists them).
# TICK_STEP 1 on every build: one tick is one 32-bit slot time.
proc v49_fs {} {
  expr {[info exists ::V49_FS] ? double($::V49_FS) : 5000.0}
}

proc v49_geometry {nch {F ""}} {
  # N -> list of {F S}, the default (first) row is the max-rate build
  set rows [dict create \
    1 {{2 8} {3 8} {4 8} {5 8} {6 8} {8 8} {10 8} {12 8} {16 8} {20 8} {24 8} {40 8}} \
    2 {{4 4} {2 8} {5 4} {6 4} {8 4} {10 4} {12 4} {16 4} {20 4} {24 4} {40 4}} ]
  set fs [v49_fs]
  if {![dict exists $rows $nch]} { error "v49 (ZCU208): no geometry for $nch channels (1 or 2)" }
  set row ""
  set factors {}
  foreach r [dict get $rows $nch] {
    lappend factors [lindex $r 0]
    if {$row eq "" && ($F eq "" || [lindex $r 0] == $F)} { set row $r }
  }
  if {$row eq ""} { error "v49 (ZCU208): $nch channels is built at factor [join $factors {, }] only, not $F" }
  lassign $row F S
  set beat [expr {$nch * 32 * $S}]
  if {$beat != 128 && $beat != 256 && $beat != 512 && $beat != 1024} { error "v49: N=$nch S=$S gives a $beat-bit beat" }
  set fab [expr {$fs / $F / $S}]
  if {$fab > 312.5} { error "v49: N=$nch F=$F S=$S at $fs MS/s needs a $fab MHz fabric (max 312.5)" }
  set pipe [expr {$fab > 150.0 ? 1 : 0}]
  return [dict create F $F S $S adc_dw $S dac_dw [expr {2 * $S}] beat_w $beat fabric $fab \
              tick_step 1 bf_pipe $pipe fs $fs]
}

# The values create_hier_cell_rfdc puts into the rfdc creation dict, so the
# IP is created consistent with the build: sampling rate and reference (fs,
# PLLs bypassed), per-slice factor and widths, and the derived fabric clock.
# Outclk (the RFDC's unused clk_adc/clk_dac outputs) is fs/128. Both clocks are written
# to 3 decimals rounded half UP, as the IP lists them (5000/128 = 39.0625 ->
# 39.063; Tcl's format alone would round half to even, 39.062, which the IP
# rejects).
proc v49_rfdc_creation {nch F} {
  set g [v49_geometry $nch $F]
  set fs [dict get $g fs]
  return [dict merge $g [dict create fs_gsps [format %g [expr {$fs / 1000.0}]] \
      fs_mhz [format %.3f $fs] fabric_s [format %.3f [expr {[dict get $g fabric] + 1e-9}]] \
      outclk_s [format %.3f [expr {$fs / 128.0 + 1e-9}]]]]
}

# The clk_wiz solver only approximates some fabric frequencies of the rate
# ladder, and the converter AXIS clock must equal Fabric_Freq. An MMCM gets
# every ladder frequency exactly from the 300 MHz input: VCO = 300 x M / D,
# f = VCO / O with M and the CLKOUT0 divide O in 1/8 steps, VCO 800..1600 MHz,
# PFD >= 10 MHz. When the solver misses (> 1 kHz), write the first exact
# solution as an override.
proc v49_clk_exact {fout} {
  set cw [get_bd_cells MTS_block/MTS_clk_wiz]
  set got [expr {[get_property CONFIG.FREQ_HZ [get_bd_pins $cw/clk_out1]] / 1e6}]
  if {abs($got - $fout) <= 0.001} return
  set fin [get_property CONFIG.PRIM_IN_FREQ $cw]
  for {set d 1} {$d <= 30 && $fin / $d >= 10.0} {incr d} {
    for {set o8 8} {$o8 <= 1024} {incr o8} {
      set vco [expr {$fout * $o8 / 8.0}]
      if {$vco < 800.0 || $vco > 1600.0} continue
      set m8 [expr {$vco * $d * 8.0 / $fin}]
      if {abs($m8 - round($m8)) > 1e-6 || $m8 < 16 || $m8 > 1024} continue
      set m [format %.3f [expr {round($m8) / 8.0}]]
      set o [format %.3f [expr {$o8 / 8.0}]]
      set_property -dict [list CONFIG.OVERRIDE_MMCM {true} CONFIG.MMCM_DIVCLK_DIVIDE $d \
          CONFIG.MMCM_CLKFBOUT_MULT_F $m CONFIG.MMCM_CLKOUT0_DIVIDE_F $o] $cw
      set got [expr {[get_property CONFIG.FREQ_HZ [get_bd_pins $cw/clk_out1]] / 1e6}]
      puts "V49_CLK exact $fout MHz: D $d M $m O $o (VCO $vco MHz) -> clk_out1 $got MHz"
      return
    }
  }
  error "v49: no exact MMCM setting for $fout MHz from $fin MHz"
}

# rfdc slice properties that exist on this IP configuration
proc v49_rfdc_props {rfdc pattern} {
  lsearch -all -inline -regexp [list_property $rfdc] "^CONFIG\\.$pattern\$"
}

proc apply_geometry {nch g} {
  dict with g {}
  puts "V49_GEOMETRY (ZCU208) N=$nch fs $fs MS/s factor $F S $S (ADC Data_Width $adc_dw, DAC $dac_dw)\
        -> [expr {$fs / $F}] MS/s per channel, fabric $fabric MHz, beat $beat_w b"
  set_property -dict [list CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %g $fabric]] \
      [get_bd_cells MTS_block/MTS_clk_wiz]
  v49_clk_exact $fabric
  set rfdc [get_bd_cells rfdc/usp_rf_data_converter]
  for {set t 0} {$t < 4} {incr t} {
    foreach k {ADC DAC} {
      if {[get_property CONFIG.${k}${t}_Enable $rfdc] != 1} continue
      set sr [get_property CONFIG.${k}${t}_Sampling_Rate $rfdc]
      if {abs($sr - $fs / 1000.0) > 1e-6} { error "v49: ${k}${t}_Sampling_Rate is $sr GS/s, expected [expr {$fs / 1000.0}] (v49_rfdc_creation)" }
    }
  }
  set cfg {}
  foreach {pat v} [list {ADC_Decimation_Mode[0-3][0-3]} $F {ADC_Data_Width[0-3][0-3]} $adc_dw \
                        {DAC_Interpolation_Mode[0-3][0-3]} $F {DAC_Data_Width[0-3][0-3]} $dac_dw] {
    foreach p [v49_rfdc_props $rfdc $pat] { lappend cfg $p $v }
  }
  # re-asserted in the SAME dict: writing a converter mode makes the IP
  # recompute dependents and drop MTS back to false
  foreach p [v49_rfdc_props $rfdc {(ADC|DAC)[0-3]_Multi_Tile_Sync}] { lappend cfg $p true }
  set_property -dict $cfg $rfdc
  foreach c {eth100g/udp_streamer eth100g/udp_player} {
    set_property CONFIG.TICK_STEP $tick_step [get_bd_cells $c]
  }
  v49_converter_streams $nch $S $beat_w
  set_property USER_COMMENTS.comment_1 "[current_bd_design] (ZCU208 v49)
- $nch DACs + $nch ADCs @ [format %g [expr {$fs / 1000.0}]] GSPS, factor $F, $S samples/clock -> [format %g [expr {$fs / $F}]] MS/s per channel
- converter AXIS [format %g $fabric] MHz, combined beat $beat_w b
- 100GbE UHD data plane: eth100g (udp_streamer, udp_player, axis_pkt_arb)" [current_bd_design]
}

# The rfdc hierarchy's stream glue, set from the geometry: the ADC I/Q
# joiner (merger for N = 1, packer for N = 2) at 16 x S bits per stream, and
# for N = 2 the DAC broadcaster (channel c = bits [c*W +: W], W = beat_w/2,
# M00 -> s20 channel 0, M01 -> s00 channel 1). Only values that differ are
# written.
proc v49_stream_cells {nch} {
  if {$nch == 1} {
    set j [get_bd_cells rfdc/dual_rf_adc_iq_merger]
    if {[llength $j] != 1} { error "v49: rfdc/dual_rf_adc_iq_merger missing" }
    return [list $j ""]
  }
  set j [get_bd_cells rfdc/adc_iq_packer]
  set b [get_bd_cells rfdc/axis_broadcaster_0]
  if {[llength $j] != 1 || [llength $b] != 1} { error "v49: rfdc/adc_iq_packer or rfdc/axis_broadcaster_0 missing" }
  return [list $j $b]
}

proc v49_converter_streams {nch S beat_w} {
  lassign [v49_stream_cells $nch] j b
  set w [expr {16 * $S}]
  if {[get_property CONFIG.C_S_AXIS_TDATA_WIDTH $j] != $w} {
    puts "V49_GEOMETRY $j C_S_AXIS_TDATA_WIDTH $w"
    set_property CONFIG.C_S_AXIS_TDATA_WIDTH $w $j
  }
  if {$nch == 2} {
    set cw [expr {$beat_w / 2}]
    set want [list CONFIG.NUM_MI 2 CONFIG.S_TDATA_NUM_BYTES [expr {$beat_w / 8}] \
                   CONFIG.M_TDATA_NUM_BYTES [expr {$cw / 8}] \
                   CONFIG.M00_TDATA_REMAP "tdata\[[expr {$cw - 1}]:0\]" \
                   CONFIG.M01_TDATA_REMAP "tdata\[[expr {2 * $cw - 1}]:$cw\]"]
    set cfg {}
    foreach {k v} $want { if {[get_property $k $b] ne $v} { lappend cfg $k $v } }
    if {[llength $cfg]} { puts "V49_GEOMETRY $b: $cfg"; set_property -dict $cfg $b }
  }
}

# The converter slices each channel streams (the converter cabling):
#   channel 0: DAC 20, ADC 20 (I) + 21 (Q);  channel 1: DAC 00, ADC 02 (I) + 03 (Q)
proc v49_channel_slices {} {
  return [dict create 0 {dac 20 adc_i 20 adc_q 21} 1 {dac 00 adc_i 02 adc_q 03}]
}

# Errors on any mismatch between the compiled block design and v49_geometry:
# factor and Data_Width on EVERY enabled ADC and DAC slice, the channel slices
# enabled, MTS / sampling rate / bypassed-PLL reference / Fabric_Freq on every
# enabled tile, the clock the BD propagates from MTS_clk_wiz, the stream glue
# (joiner widths and its four (two) ADC inputs, the DAC fan-out and remap),
# the eth100g widths / TICK_STEP / TX buffer / pass-through tie-offs, the
# beamformers (N = 2) and the PS address map.
proc verify_rate_variant {F {nch 1}} {
  set g [v49_geometry $nch $F]
  dict with g {}
  set rfdc [get_bd_cells rfdc/usp_rf_data_converter]
  set nslice 0
  for {set t 0} {$t < 4} {incr t} {
    for {set b 0} {$b < 4} {incr b} {
      foreach {k mode dw} [list ADC Decimation $adc_dw DAC Interpolation $dac_dw] {
        set en [get_property -quiet CONFIG.${k}_Slice${t}${b}_Enable $rfdc]
        if {$en ne "true"} continue
        incr nslice
        set v [get_property CONFIG.${k}_${mode}_Mode${t}${b} $rfdc]
        if {$v ne $F} { error "v49: ${k}_${mode}_Mode${t}${b} is '$v', expected $F on every tile and slice" }
        set v [get_property CONFIG.${k}_Data_Width${t}${b} $rfdc]
        if {$v ne $dw} { error "v49: ${k}_Data_Width${t}${b} is '$v', expected $dw on every slice" }
      }
    }
    foreach k {ADC DAC} {
      if {[get_property CONFIG.${k}${t}_Enable $rfdc] != 1} continue
      if {[get_property CONFIG.${k}${t}_Multi_Tile_Sync $rfdc] ne "true"} { error "v49: ${k}${t}_Multi_Tile_Sync dropped to false" }
      set sr [get_property CONFIG.${k}${t}_Sampling_Rate $rfdc]
      if {abs($sr - $fs / 1000.0) > 1e-6} { error "v49: ${k}${t}_Sampling_Rate is $sr GS/s, expected [expr {$fs / 1000.0}]" }
      set rc [get_property CONFIG.${k}${t}_Refclk_Freq $rfdc]
      if {[get_property CONFIG.${k}${t}_PLL_Enable $rfdc] ne "true" && abs($rc - $fs) > 1e-3} { error "v49: ${k}${t}_Refclk_Freq is $rc MHz with the tile PLL bypassed, expected fs $fs" }
      set v [get_property CONFIG.${k}${t}_Fabric_Freq $rfdc]
      if {abs($v - $fabric) > 0.01} { error "v49: ${k}${t}_Fabric_Freq is $v MHz, expected $fabric" }
    }
  }
  dict for {c sl} [v49_channel_slices] {
    if {$c >= $nch} continue
    dict with sl {}
    foreach {k s} [list DAC $dac ADC $adc_i ADC $adc_q] {
      if {[get_property CONFIG.${k}_Slice${s}_Enable $rfdc] ne "true"} { error "v49: channel $c needs ${k} slice $s, which is disabled" }
    }
  }
  set hz [get_property CONFIG.FREQ_HZ [get_bd_pins MTS_block/MTS_clk_wiz/clk_out1]]
  set clk [expr {$hz / 1e6}]
  if {abs($clk - $fabric) > 0.01} { error "v49: MTS_clk_wiz clk_out1 is $clk MHz, expected $fabric" }
  if {[get_property CONFIG.USE_DYN_RECONFIG [get_bd_cells MTS_block/MTS_clk_wiz]] ne "true"} { error "v49: MTS_clk_wiz has no dynamic reconfiguration (run-time rate change)" }
  foreach pin {rfdc/M_ADC_AXIS rfdc/S_DAC_AXIS eth100g/udp_streamer/s_axis eth100g/udp_player/m_axis_dac} {
    set nb [get_property CONFIG.TDATA_NUM_BYTES [get_bd_intf_pins $pin]]
    if {$nb ne "" && $nb * 8 != $beat_w} { error "v49: $pin is [expr {$nb*8}] bits, expected $beat_w" }
  }
  foreach {c p} {eth100g/udp_streamer S_WIDTH eth100g/udp_player M_WIDTH} {
    set v [get_property CONFIG.TICK_STEP [get_bd_cells $c]]
    if {$v != $tick_step} { error "v49: $c TICK_STEP is $v, expected $tick_step" }
    set v [get_property CONFIG.$p [get_bd_cells $c]]
    if {$v != $beat_w} { error "v49: $c $p is $v, expected $beat_w" }
  }
  set tbuf [v49_tx_buffer]
  foreach k {TX_BUF_WORDS META_DEPTH XFER_DEPTH CHAIN_STAGES CHAIN_DEPTH} {
    set v [get_property CONFIG.$k [get_bd_cells eth100g/udp_player]]
    if {$v != [dict get $tbuf $k]} { error "v49: eth100g/udp_player $k is $v, expected [dict get $tbuf $k]" }
  }
  # stream glue: joiner width and inputs, DAC fan-out
  lassign [v49_stream_cells $nch] j b
  if {[get_property CONFIG.C_S_AXIS_TDATA_WIDTH $j] != 16 * $S} { error "v49: $j C_S_AXIS_TDATA_WIDTH is [get_property CONFIG.C_S_AXIS_TDATA_WIDTH $j], expected [expr {16 * $S}]" }
  set conv rfdc/usp_rf_data_converter
  if {$nch == 1} {
    set ins [list $j/s_i_axis $conv/m20_axis $j/s_q_axis $conv/m21_axis \
                  rfdc/axis_register_slice_1/M_AXIS $conv/s20_axis]
  } else {
    set ins [list $j/s_ch0_i_axis $conv/m20_axis $j/s_ch0_q_axis $conv/m21_axis \
                  $j/s_ch1_i_axis $conv/m02_axis $j/s_ch1_q_axis $conv/m03_axis \
                  $b/M00_AXIS $conv/s20_axis $b/M01_AXIS $conv/s00_axis]
    set cw [expr {$beat_w / 2}]
    foreach {k v} [list M00_TDATA_REMAP "tdata\[[expr {$cw - 1}]:0\]" M01_TDATA_REMAP "tdata\[[expr {2 * $cw - 1}]:$cw\]"] {
      if {[get_property CONFIG.$k $b] ne $v} { error "v49: $b $k is '[get_property CONFIG.$k $b]', expected $v" }
    }
  }
  foreach {a z} $ins {
    set na [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $a]]
    set nz [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $z]]
    if {$na eq "" || $na ne $nz} { error "v49: $a is not wired to $z" }
  }
  # the eth100g pass-through ports: tied off
  foreach {pin val} {eth100g/udp_streamer/m_axis_adc_tready 1 eth100g/udp_player/s_axis_dma_tvalid 0} {
    set src [get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins $pin]] -filter {DIR == O}]
    if {[llength $src] != 1 || [get_property CONFIG.CONST_VAL [get_bd_cells -of_objects $src]] != $val} { error "v49: $pin is not tied to $val" }
  }
  # beamformers: N = 2 only, sized to the row
  foreach {cell params} [list eth100g/tx_beamformer [list N_CH $nch BEAT_W $beat_w PIPE $bf_pipe] \
                              eth100g/rx_beamformer [list N_CH $nch BEAT_W $beat_w]] {
    set c [get_bd_cells -quiet $cell]
    if {$nch == 1} {
      if {$c ne ""} { error "v49: the 1-channel build has $cell" }
      continue
    }
    if {$c eq ""} { error "v49: $cell is missing" }
    foreach {k v} $params {
      if {[get_property CONFIG.$k $c] != $v} { error "v49: $c $k is [get_property CONFIG.$k $c], expected $v" }
    }
  }
  if {$nch == 2} {
    foreach {name dir} {adc_c2s 0 dac_s2c 1} {
      set c [get_bd_cells eth100g/$name]
      foreach {k v} [list N_CH $nch BEAT_W $beat_w DIR $dir] {
        if {[get_property CONFIG.$k $c] != $v} { error "v49: $c $k is [get_property CONFIG.$k $c], expected $v" }
      }
    }
  }
  # converter streams straight into / out of eth100g
  foreach {a z} {rfdc/M_ADC_AXIS eth100g/S_AXIS_ADC rfdc/S_DAC_AXIS eth100g/M_AXIS_DAC} {
    set na [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $a]]
    if {$na eq "" || $na ne [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $z]]} { error "v49: $a is not wired to $z" }
  }
  # the PS address map: the same as the ZCU216 builds
  set amap [dict create \
    rfdc/usp_rf_data_converter/s_axi/Reg 0x80280000  MTS_block/MTS_clk_wiz/s_axi_lite/Reg 0x80200000 \
    axi_gpio_led/S_AXI/Reg 0x80230000  axi_intp/S_AXI/Reg 0x80240000 \
    eth100g/udp_streamer/s_axi/reg0 0x80020000  eth100g/udp_player/s_axi/reg0 0x80030000 \
    eth100g/cmac_gpio/S_AXI/Reg 0x80040000  eth100g/cmac_freq/S_AXI/Reg 0x80050000]
  if {$nch > 1} {
    foreach {cell off} {tx_beamformer 0x80060000 rx_beamformer 0x80070000} {
      set bseg [get_bd_addr_segs eth100g/$cell/s_axi/*]
      if {[llength $bseg] != 1} { error "v49: $cell has [llength $bseg] address blocks" }
      dict set amap [string trimleft $bseg /] $off
    }
  }
  set seen {}
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e/Data]] {
    set slave [string trimleft [get_bd_addr_segs -of_objects $seg] /]
    if {![dict exists $amap $slave]} { error "v49: unexpected PS address segment $seg -> $slave" }
    if {[get_property OFFSET $seg] != [dict get $amap $slave]} { error "v49: $slave at [get_property OFFSET $seg], expected [dict get $amap $slave]" }
    lappend seen $slave
  }
  foreach slave [dict keys $amap] {
    if {$slave ni $seen} { error "v49: $slave is not mapped in the PS address space" }
  }
  puts "V49_RATE verified (ZCU208): N=$nch, factor $F on all $nslice enabled slices (ADC Data_Width $adc_dw,\
        DAC $dac_dw), fabric $fabric MHz on every tile, clk_wiz $clk MHz, beat $beat_w b, TICK_STEP $tick_step,\
        TX buffer [dict get $tbuf TX_BUF_WORDS] words,\
        [expr {$nch > 1 ? "beamformers N_CH $nch PIPE $bf_pipe" : "no beamformers"}], PS address map as on ZCU216"
}

if {[info exists ::V49_DEFINE_ONLY] && $::V49_DEFINE_ONLY} { return }

################################################################
# Parameters
################################################################
if {![info exists ::V49_NCH]} { error "zcu208_uhd_v49: set V49_NCH (1 or 2) before sourcing" }
set v49_nch $::V49_NCH
if {![info exists ::V49_FACTOR] || $::V49_FACTOR eq ""} { set ::V49_FACTOR [dict get [v49_geometry $v49_nch] F] }
# (v49_geometry errors on an N or F it has no row for)
set v49_F [dict get [v49_geometry $v49_nch $::V49_FACTOR] F]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2021.1
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}
   return 1
}

################################################################
# START
################################################################
set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xczu48dr-fsvg1517-2-e
   set_property BOARD_PART xilinx.com:zcu208:part0:2.0 [current_project]
}
# ZCU208 ONLY: a netlist for another die would build without complaint.
if { [get_property PART [current_project]] ne "xczu48dr-fsvg1517-2-e" } {
   error "zcu208_uhd_v49 targets the ZCU208 (xczu48dr-fsvg1517-2-e), not [get_property PART [current_project]]"
}

variable design_name
set design_name zcu208_v49_${v49_nch}ch_qsfp
if { [get_files -quiet ${design_name}.bd] ne "" } {
   error "Design <$design_name> already exists in the project"
}
create_bd_design $design_name
current_bd_design $design_name

##################################################################
# CHECK IPs
##################################################################
set list_check_ips {
xilinx.com:ip:axi_gpio:2.0
xilinx.com:ip:smartconnect:1.0
xilinx.com:ip:axi_intc:4.1
xilinx.com:ip:proc_sys_reset:5.0
xilinx.com:ip:xlconcat:2.1
xilinx.com:ip:clk_wiz:6.0
xilinx.com:ip:util_ds_buf:2.2
xilinx.com:ip:xpm_cdc_gen:1.0
xilinx.com:ip:zynq_ultra_ps_e:3.3
xilinx.com:ip:axis_register_slice:1.1
xilinx.com:ip:axis_broadcaster:1.1
xilinx.com:ip:usp_rf_data_converter:2.5
xilinx.com:ip:xlconstant:1.1
xilinx.com:ip:xlslice:1.0
user.org:user:dual_rf_adc_iq_merger:1.0
user.org:user:dual_channel_rf_adc_iq_packer:1.0
user.org:uhd:udp_streamer:1.0
user.org:uhd:udp_player:1.0
user.org:uhd:axis_pkt_arb:1.0
user.org:uhd:ch_interleave:1.0
user.org:uhd:tx_beamformer:1.0
user.org:uhd:rx_beamformer:1.0
}
set list_ips_missing {}
foreach ip_vlnv $list_check_ips {
   if { [get_ipdefs -all $ip_vlnv] eq "" } { lappend list_ips_missing $ip_vlnv }
}
if { $list_ips_missing ne "" } {
   error "zcu208_uhd_v49: IPs not in the catalog: $list_ips_missing (user.org:uhd:*: run 'make package' in hw_design/ip_design/uhd_ip and add hw_design/ip/uhd_ip to ip_repo_paths; the I/Q joiners: hw_design/ip/iprepo)"
}

##################################################################
# DESIGN PROCs
##################################################################

proc create_hier_cell_MTS_block { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_MTS_block() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 PL_CLK

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 PL_SYSREF

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi_lite


  # Create pins
  create_bd_pin -dir O -type clk adc_clk
  create_bd_pin -dir O -type clk dac_clk
  create_bd_pin -dir O -type intr interrupt
  create_bd_pin -dir O locked
  create_bd_pin -dir I -type rst pl_aresetn
  create_bd_pin -dir I -type clk pl_clk
  create_bd_pin -dir O -type clk pl_ref_clk
  create_bd_pin -dir O -from 0 -to 0 sysref_raw

  # Create instance: BUFG_PL_CLK, and set properties
  set BUFG_PL_CLK [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 BUFG_PL_CLK ]
  set_property -dict [ list \
   CONFIG.C_BUF_TYPE {BUFG} \
 ] $BUFG_PL_CLK

  # Create instance: IBUFDS_PL_CLK, and set properties
  set IBUFDS_PL_CLK [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 IBUFDS_PL_CLK ]
  set_property -dict [ list \
   CONFIG.C_BUF_TYPE {IBUFDS} \
 ] $IBUFDS_PL_CLK

  # Create instance: IBUFDS_SYSREF, and set properties
  set IBUFDS_SYSREF [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 IBUFDS_SYSREF ]
  set_property -dict [ list \
   CONFIG.C_BUF_TYPE {IBUFDS} \
 ] $IBUFDS_SYSREF

  # Create instance: MTS_clk_wiz, and set properties
  # USE_DYN_RECONFIG: the daemon retunes clk_out1 (the converter AXIS clock)
  # at run time over s_axi_lite (register file at 0x200, shared with the
  # clock monitor), so one bitstream serves every factor F of its row. The
  # build is timed at the clk_out1 it is generated with: the highest.
  set MTS_clk_wiz [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 MTS_clk_wiz ]
  set_property -dict [ list \
   CONFIG.CLKIN1_JITTER_PS {100.0} \
   CONFIG.CLKOUT1_DRIVES {Buffer} \
   CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {300} \
   CONFIG.CLKOUT2_DRIVES {Buffer} \
   CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100} \
   CONFIG.CLKOUT2_USED {true} \
   CONFIG.CLKOUT3_DRIVES {Buffer} \
   CONFIG.CLKOUT4_DRIVES {Buffer} \
   CONFIG.CLKOUT5_DRIVES {Buffer} \
   CONFIG.CLKOUT6_DRIVES {Buffer} \
   CONFIG.CLKOUT7_DRIVES {Buffer} \
   CONFIG.ENABLE_CLOCK_MONITOR {true} \
   CONFIG.JITTER_SEL {Min_O_Jitter} \
   CONFIG.MMCM_BANDWIDTH {HIGH} \
   CONFIG.MMCM_CLKFBOUT_MULT_F {5.000} \
   CONFIG.MMCM_CLKIN1_PERIOD {3.333} \
   CONFIG.MMCM_CLKIN2_PERIOD {10.0} \
   CONFIG.MMCM_CLKOUT0_DIVIDE_F {5.000} \
   CONFIG.MMCM_DIVCLK_DIVIDE {1} \
   CONFIG.PRIMITIVE {MMCM} \
   CONFIG.PRIM_IN_FREQ {300} \
   CONFIG.PRIM_SOURCE {Global_buffer} \
   CONFIG.SECONDARY_SOURCE {Single_ended_clock_capable_pin} \
   CONFIG.USE_DYN_RECONFIG {true} \
   CONFIG.USE_PHASE_ALIGNMENT {true} \
 ] $MTS_clk_wiz

  # Create interface connections
  connect_bd_intf_net -intf_net PL_CLK_1 [get_bd_intf_pins PL_CLK] [get_bd_intf_pins IBUFDS_PL_CLK/CLK_IN_D]
  connect_bd_intf_net -intf_net PL_SYSREF_1 [get_bd_intf_pins PL_SYSREF] [get_bd_intf_pins IBUFDS_SYSREF/CLK_IN_D]
  connect_bd_intf_net -intf_net axi_interconnect_pl_M04_AXI [get_bd_intf_pins s_axi_lite] [get_bd_intf_pins MTS_clk_wiz/s_axi_lite]

  # Create port connections
  connect_bd_net -net BUFG_PL_CLK_BUFG_O [get_bd_pins pl_ref_clk] [get_bd_pins BUFG_PL_CLK/BUFG_O] [get_bd_pins MTS_clk_wiz/clk_in1]
  connect_bd_net -net IBUFDS_PL_CLK_IBUF_OUT [get_bd_pins BUFG_PL_CLK/BUFG_I] [get_bd_pins IBUFDS_PL_CLK/IBUF_OUT]
  connect_bd_net -net IBUFDS_SYSREF_IBUF_OUT [get_bd_pins sysref_raw] [get_bd_pins IBUFDS_SYSREF/IBUF_OUT]
  connect_bd_net -net MTS_clk_wiz_interrupt [get_bd_pins interrupt] [get_bd_pins MTS_clk_wiz/interrupt]
  connect_bd_net -net MTS_clk_wiz_locked [get_bd_pins locked] [get_bd_pins MTS_clk_wiz/locked]
  connect_bd_net -net dac_adc_axis_aclk [get_bd_pins adc_clk] [get_bd_pins dac_clk] [get_bd_pins MTS_clk_wiz/clk_out1]
  connect_bd_net -net rst_ps8_99M_peripheral_aresetn [get_bd_pins pl_aresetn] [get_bd_pins MTS_clk_wiz/s_axi_aresetn]
  connect_bd_net -net zynq_ultra_ps_e_pl_clk1 [get_bd_pins pl_clk] [get_bd_pins MTS_clk_wiz/ref_clk] [get_bd_pins MTS_clk_wiz/s_axi_aclk]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# Hierarchical cell: rfdc -- the RF data converter (dual RF-ADC tiles in I/Q
# mode, every DAC tile's block 0) and its combined converter streams. The
# channel map (the converter cabling, v49_channel_slices):
#   channel 0: DAC tile 2 block 0 (s20, vout20)  <-  ADC tile 2 (m20 I, m21 Q, vin2_01)
#   channel 1: DAC tile 0 block 0 (s00, vout00)  <-  ADC tile 0 (m02 I, m03 Q, vin0_23)
# M_ADC_AXIS: the I/Q streams joined into complex 32-bit slots, I low
# (N = 1 dual_rf_adc_iq_merger, N = 2 adc_iq_packer, channel-major).
# S_DAC_AXIS: N = 1 straight to s20; N = 2 split by axis_broadcaster_0 (lower
# half channel 0 -> s20, upper half channel 1 -> s00). Both through an
# axis_register_slice.
proc create_hier_cell_rfdc { parentCell nameHier nch } {
  set oldCurInst [current_bd_instance .]
  current_bd_instance [get_bd_cells $parentCell]
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_ADC_AXIS
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_DAC_AXIS
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 adc2_clk
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 dac2_clk
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:display_usp_rf_data_converter:diff_pins_rtl:1.0 sysref_in
  foreach v [v49_vins] {
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 $v
  }
  foreach v [v49_vouts] {
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 $v
  }

  # Create pins
  # In MTS mode, both RFDC AXIS domains are driven by the MTS_clk_wiz clock
  # synchronized to PL SYSREF. RFDC clk_adc2/clk_dac2 are only converter
  # reference outputs and must not drive AXIS directly.
  create_bd_pin -dir I -type clk adc_axis_clk
  create_bd_pin -dir I -type rst adc_axis_aresetn
  create_bd_pin -dir I -type clk dac_axis_clk
  create_bd_pin -dir I -type rst dac_axis_aresetn
  create_bd_pin -dir O -type intr irq
  create_bd_pin -dir I -type clk s_axi_aclk
  create_bd_pin -dir I -type rst s_axi_aresetn
  create_bd_pin -dir I user_sysref_adc
  create_bd_pin -dir I user_sysref_dac

  set S [dict get [v49_rfdc_creation $nch $::V49_FACTOR] S]
  if {$nch == 1} {
    # A dual RF-ADC emits simultaneous I and Q streams. The merger keeps both
    # RFDC TREADY inputs high and interleaves {Q3,I3,...,Q0,I0}.
    set joiner [ create_bd_cell -type ip -vlnv user.org:user:dual_rf_adc_iq_merger:1.0 dual_rf_adc_iq_merger ]
  } else {
    # Split the channel-major DAC beat into the two DAC channel beats (widths
    # and remap: v49_converter_streams). Lower half channel 0 -> S20, upper
    # half channel 1 -> S00. Each half is {Q1,I1,Q0,I0}, int16.
    set axis_broadcaster_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_broadcaster:1.1 axis_broadcaster_0 ]
    set_property -dict [ list \
     CONFIG.M00_TDATA_REMAP {tdata[63:0]} \
     CONFIG.M01_TDATA_REMAP {tdata[127:64]} \
     CONFIG.M_TDATA_NUM_BYTES {8} \
     CONFIG.S_TDATA_NUM_BYTES {16} \
   ] $axis_broadcaster_0
    # A dual RF-ADC emits separate, continuously-valid I and Q AXIS streams.
    # Statelessly reshuffle all four streams sample-by-sample. The packer has no
    # FIFO or handshake state: every input TREADY and output TVALID is tied high.
    set joiner [ create_bd_cell -type ip -vlnv user.org:user:dual_channel_rf_adc_iq_packer:1.0 adc_iq_packer ]
  }
  set_property -dict [list CONFIG.C_S_AXIS_TDATA_WIDTH [expr {16 * $S}]] $joiner
  set jn [get_property NAME $joiner]

  # Create instance: axis_register_slice_0 (ADC) and _1 (DAC)
  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_register_slice_0
  create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_register_slice_1

  # Create instance: usp_rf_data_converter, and set properties
  # The rfdc is created at the build's geometry (v49_rfdc_creation): fs =
  # V49_FS on every tile with the tile PLLs bypassed (Refclk = fs), factor
  # V49_FACTOR and the Data_Width of S samples/clock on every slice, and the
  # Fabric/Outclk values they imply.
  set v49c [v49_rfdc_creation $nch $::V49_FACTOR]
  set usp_rf_data_converter [ create_bd_cell -type ip -vlnv xilinx.com:ip:usp_rf_data_converter:2.5 usp_rf_data_converter ]
  set_property -dict [ list \
   CONFIG.ADC0_Clock_Dist {0} \
   CONFIG.ADC0_Clock_Source {2} \
   CONFIG.ADC0_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.ADC0_Multi_Tile_Sync {true} \
   CONFIG.ADC0_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.ADC0_PLL_Enable {false} \
   CONFIG.ADC0_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.ADC0_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.ADC1_Clock_Source {2} \
   CONFIG.ADC1_Enable {1} \
   CONFIG.ADC1_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.ADC1_Multi_Tile_Sync {true} \
   CONFIG.ADC1_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.ADC1_PLL_Enable {false} \
   CONFIG.ADC1_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.ADC1_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.ADC2_Clock_Dist {1} \
   CONFIG.ADC2_Enable {1} \
   CONFIG.ADC2_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.ADC2_Multi_Tile_Sync {true} \
   CONFIG.ADC2_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.ADC2_PLL_Enable {false} \
   CONFIG.ADC2_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.ADC2_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.ADC3_Clock_Source {2} \
   CONFIG.ADC3_Enable {1} \
   CONFIG.ADC3_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.ADC3_Multi_Tile_Sync {true} \
   CONFIG.ADC3_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.ADC3_PLL_Enable {false} \
   CONFIG.ADC3_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.ADC3_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.ADC_CalOpt_Mode00 {2} \
   CONFIG.ADC_CalOpt_Mode01 {2} \
   CONFIG.ADC_CalOpt_Mode02 {2} \
   CONFIG.ADC_CalOpt_Mode03 {2} \
   CONFIG.ADC_CalOpt_Mode10 {2} \
   CONFIG.ADC_CalOpt_Mode11 {2} \
   CONFIG.ADC_CalOpt_Mode20 {2} \
   CONFIG.ADC_CalOpt_Mode21 {2} \
   CONFIG.ADC_CalOpt_Mode22 {2} \
   CONFIG.ADC_CalOpt_Mode23 {2} \
   CONFIG.ADC_CalOpt_Mode30 {1} \
   CONFIG.ADC_CalOpt_Mode31 {1} \
   CONFIG.ADC_Coarse_Mixer_Freq00 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq01 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq02 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq03 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq10 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq11 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq20 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq21 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq22 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq23 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq30 {0} \
   CONFIG.ADC_Coarse_Mixer_Freq31 {0} \
   CONFIG.ADC_Data_Type00 {1} \
   CONFIG.ADC_Data_Type01 {1} \
   CONFIG.ADC_Data_Type02 {1} \
   CONFIG.ADC_Data_Type03 {1} \
   CONFIG.ADC_Data_Type10 {1} \
   CONFIG.ADC_Data_Type11 {1} \
   CONFIG.ADC_Data_Type20 {1} \
   CONFIG.ADC_Data_Type21 {1} \
   CONFIG.ADC_Data_Type22 {1} \
   CONFIG.ADC_Data_Type23 {1} \
   CONFIG.ADC_Data_Type30 {1} \
   CONFIG.ADC_Data_Type31 {1} \
   CONFIG.ADC_Data_Width00 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width01 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width02 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width03 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width10 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width11 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width20 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width21 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width22 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width23 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width30 [dict get $v49c adc_dw] \
   CONFIG.ADC_Data_Width31 [dict get $v49c adc_dw] \
   CONFIG.ADC_Decimation_Mode00 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode01 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode02 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode03 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode10 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode11 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode20 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode21 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode22 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode23 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode30 [dict get $v49c F] \
   CONFIG.ADC_Decimation_Mode31 [dict get $v49c F] \
   CONFIG.ADC_Mixer_Mode00 {0} \
   CONFIG.ADC_Mixer_Mode01 {0} \
   CONFIG.ADC_Mixer_Mode02 {0} \
   CONFIG.ADC_Mixer_Mode03 {0} \
   CONFIG.ADC_Mixer_Mode10 {0} \
   CONFIG.ADC_Mixer_Mode11 {0} \
   CONFIG.ADC_Mixer_Mode20 {0} \
   CONFIG.ADC_Mixer_Mode21 {0} \
   CONFIG.ADC_Mixer_Mode22 {0} \
   CONFIG.ADC_Mixer_Mode23 {0} \
   CONFIG.ADC_Mixer_Mode30 {0} \
   CONFIG.ADC_Mixer_Mode31 {0} \
   CONFIG.ADC_Mixer_Type00 {2} \
   CONFIG.ADC_Mixer_Type01 {2} \
   CONFIG.ADC_Mixer_Type02 {2} \
   CONFIG.ADC_Mixer_Type03 {2} \
   CONFIG.ADC_Mixer_Type10 {2} \
   CONFIG.ADC_Mixer_Type11 {2} \
   CONFIG.ADC_Mixer_Type20 {2} \
   CONFIG.ADC_Mixer_Type21 {2} \
   CONFIG.ADC_Mixer_Type22 {2} \
   CONFIG.ADC_Mixer_Type23 {2} \
   CONFIG.ADC_Mixer_Type30 {2} \
   CONFIG.ADC_Mixer_Type31 {2} \
   CONFIG.ADC_OBS12 {false} \
   CONFIG.ADC_OBS22 {false} \
   CONFIG.ADC_OBS32 {false} \
   CONFIG.ADC_RESERVED_1_00 {false} \
   CONFIG.ADC_RESERVED_1_02 {false} \
   CONFIG.ADC_RESERVED_1_10 {false} \
   CONFIG.ADC_RESERVED_1_12 {false} \
   CONFIG.ADC_RESERVED_1_20 {false} \
   CONFIG.ADC_RESERVED_1_22 {false} \
   CONFIG.ADC_RESERVED_1_30 {false} \
   CONFIG.ADC_RESERVED_1_32 {false} \
   CONFIG.ADC_Slice02_Enable {true} \
   CONFIG.ADC_Slice03_Enable {true} \
   CONFIG.ADC_Slice10_Enable {true} \
   CONFIG.ADC_Slice11_Enable {true} \
   CONFIG.ADC_Slice20_Enable {true} \
   CONFIG.ADC_Slice21_Enable {true} \
   CONFIG.ADC_Slice22_Enable {true} \
   CONFIG.ADC_Slice23_Enable {true} \
   CONFIG.ADC_Slice30_Enable {true} \
   CONFIG.ADC_Slice31_Enable {true} \
   CONFIG.DAC0_Clock_Dist {0} \
   CONFIG.DAC0_Clock_Source {6} \
   CONFIG.DAC0_Enable {1} \
   CONFIG.DAC0_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.DAC0_Multi_Tile_Sync {true} \
   CONFIG.DAC0_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.DAC0_PLL_Enable {false} \
   CONFIG.DAC0_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.DAC0_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.DAC1_Clock_Source {6} \
   CONFIG.DAC1_Enable {1} \
   CONFIG.DAC1_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.DAC1_Multi_Tile_Sync {true} \
   CONFIG.DAC1_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.DAC1_PLL_Enable {false} \
   CONFIG.DAC1_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.DAC1_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.DAC2_Clock_Dist {1} \
   CONFIG.DAC2_Enable {1} \
   CONFIG.DAC2_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.DAC2_Multi_Tile_Sync {true} \
   CONFIG.DAC2_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.DAC2_PLL_Enable {false} \
   CONFIG.DAC2_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.DAC2_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.DAC3_Clock_Source {6} \
   CONFIG.DAC3_Enable {1} \
   CONFIG.DAC3_Fabric_Freq [dict get $v49c fabric_s] \
   CONFIG.DAC3_Multi_Tile_Sync {true} \
   CONFIG.DAC3_Outclk_Freq [dict get $v49c outclk_s] \
   CONFIG.DAC3_PLL_Enable {false} \
   CONFIG.DAC3_Refclk_Freq [dict get $v49c fs_mhz] \
   CONFIG.DAC3_Sampling_Rate [dict get $v49c fs_gsps] \
   CONFIG.DAC_Coarse_Mixer_Freq00 {3} \
   CONFIG.DAC_Coarse_Mixer_Freq10 {3} \
   CONFIG.DAC_Coarse_Mixer_Freq20 {3} \
   CONFIG.DAC_Coarse_Mixer_Freq30 {3} \
   CONFIG.DAC_Data_Width00 [dict get $v49c dac_dw] \
   CONFIG.DAC_Data_Width10 [dict get $v49c dac_dw] \
   CONFIG.DAC_Data_Width20 [dict get $v49c dac_dw] \
   CONFIG.DAC_Data_Width30 [dict get $v49c dac_dw] \
   CONFIG.DAC_Interpolation_Mode00 [dict get $v49c F] \
   CONFIG.DAC_Interpolation_Mode10 [dict get $v49c F] \
   CONFIG.DAC_Interpolation_Mode20 [dict get $v49c F] \
   CONFIG.DAC_Interpolation_Mode30 [dict get $v49c F] \
   CONFIG.DAC_Invsinc_Ctrl00 {true} \
   CONFIG.DAC_Invsinc_Ctrl10 {true} \
   CONFIG.DAC_Invsinc_Ctrl20 {true} \
   CONFIG.DAC_Invsinc_Ctrl30 {false} \
   CONFIG.DAC_Mixer_Mode00 {0} \
   CONFIG.DAC_Mixer_Mode10 {0} \
   CONFIG.DAC_Mixer_Mode20 {0} \
   CONFIG.DAC_Mixer_Mode30 {0} \
   CONFIG.DAC_Mixer_Type00 {2} \
   CONFIG.DAC_Mixer_Type10 {2} \
   CONFIG.DAC_Mixer_Type20 {2} \
   CONFIG.DAC_Mixer_Type30 {2} \
   CONFIG.DAC_RESERVED_1_00 {false} \
   CONFIG.DAC_RESERVED_1_01 {false} \
   CONFIG.DAC_RESERVED_1_02 {false} \
   CONFIG.DAC_RESERVED_1_03 {false} \
   CONFIG.DAC_RESERVED_1_10 {false} \
   CONFIG.DAC_RESERVED_1_11 {false} \
   CONFIG.DAC_RESERVED_1_12 {false} \
   CONFIG.DAC_RESERVED_1_13 {false} \
   CONFIG.DAC_RESERVED_1_20 {false} \
   CONFIG.DAC_RESERVED_1_21 {false} \
   CONFIG.DAC_RESERVED_1_22 {false} \
   CONFIG.DAC_RESERVED_1_23 {false} \
   CONFIG.DAC_RESERVED_1_30 {false} \
   CONFIG.DAC_RESERVED_1_31 {false} \
   CONFIG.DAC_RESERVED_1_32 {false} \
   CONFIG.DAC_RESERVED_1_33 {false} \
   CONFIG.DAC_Slice00_Enable {true} \
   CONFIG.DAC_Slice10_Enable {true} \
   CONFIG.DAC_Slice20_Enable {true} \
   CONFIG.DAC_Slice30_Enable {true} \
 ] $usp_rf_data_converter

  # Create interface connections
  connect_bd_intf_net -intf_net Conn5 [get_bd_intf_pins adc2_clk] [get_bd_intf_pins usp_rf_data_converter/adc2_clk]
  connect_bd_intf_net -intf_net Conn6 [get_bd_intf_pins dac2_clk] [get_bd_intf_pins usp_rf_data_converter/dac2_clk]
  connect_bd_intf_net -intf_net s_axi_1 [get_bd_intf_pins s_axi] [get_bd_intf_pins usp_rf_data_converter/s_axi]
  connect_bd_intf_net -intf_net sysref_in_1 [get_bd_intf_pins sysref_in] [get_bd_intf_pins usp_rf_data_converter/sysref_in]
  foreach v [concat [v49_vins] [v49_vouts]] {
    connect_bd_intf_net -intf_net rfdc_$v [get_bd_intf_pins $v] [get_bd_intf_pins usp_rf_data_converter/$v]
  }
  connect_bd_intf_net -intf_net S_DAC_AXIS_1 [get_bd_intf_pins S_DAC_AXIS] [get_bd_intf_pins axis_register_slice_1/S_AXIS]
  connect_bd_intf_net -intf_net axis_register_slice_0_M_AXIS [get_bd_intf_pins M_ADC_AXIS] [get_bd_intf_pins axis_register_slice_0/M_AXIS]
  connect_bd_intf_net -intf_net ${jn}_m_axis [get_bd_intf_pins $jn/m_axis] [get_bd_intf_pins axis_register_slice_0/S_AXIS]
  # converter streams (v49_channel_slices)
  if {$nch == 1} {
    connect_bd_intf_net -intf_net axis_register_slice_1_M_AXIS [get_bd_intf_pins axis_register_slice_1/M_AXIS] [get_bd_intf_pins usp_rf_data_converter/s20_axis]
    connect_bd_intf_net -intf_net usp_rf_data_converter_m20_axis [get_bd_intf_pins $jn/s_i_axis] [get_bd_intf_pins usp_rf_data_converter/m20_axis]
    connect_bd_intf_net -intf_net usp_rf_data_converter_m21_axis [get_bd_intf_pins $jn/s_q_axis] [get_bd_intf_pins usp_rf_data_converter/m21_axis]
  } else {
    connect_bd_intf_net -intf_net axis_register_slice_1_M_AXIS [get_bd_intf_pins axis_broadcaster_0/S_AXIS] [get_bd_intf_pins axis_register_slice_1/M_AXIS]
    connect_bd_intf_net -intf_net axis_broadcaster_0_M00_AXIS [get_bd_intf_pins axis_broadcaster_0/M00_AXIS] [get_bd_intf_pins usp_rf_data_converter/s20_axis]
    connect_bd_intf_net -intf_net axis_broadcaster_0_M01_AXIS [get_bd_intf_pins axis_broadcaster_0/M01_AXIS] [get_bd_intf_pins usp_rf_data_converter/s00_axis]
    connect_bd_intf_net -intf_net adc_pair0_i_axis [get_bd_intf_pins $jn/s_ch0_i_axis] [get_bd_intf_pins usp_rf_data_converter/m20_axis]
    connect_bd_intf_net -intf_net adc_pair0_q_axis [get_bd_intf_pins $jn/s_ch0_q_axis] [get_bd_intf_pins usp_rf_data_converter/m21_axis]
    connect_bd_intf_net -intf_net adc_pair1_i_axis [get_bd_intf_pins $jn/s_ch1_i_axis] [get_bd_intf_pins usp_rf_data_converter/m02_axis]
    connect_bd_intf_net -intf_net adc_pair1_q_axis [get_bd_intf_pins $jn/s_ch1_q_axis] [get_bd_intf_pins usp_rf_data_converter/m03_axis]
  }

  # Create port connections
  set aclk [list [get_bd_pins adc_axis_clk] [get_bd_pins $jn/axis_aclk] [get_bd_pins axis_register_slice_0/aclk]]
  set arst [list [get_bd_pins adc_axis_aresetn] [get_bd_pins $jn/axis_aresetn] [get_bd_pins axis_register_slice_0/aresetn]]
  set dclk [list [get_bd_pins dac_axis_clk] [get_bd_pins axis_register_slice_1/aclk]]
  set drst [list [get_bd_pins dac_axis_aresetn] [get_bd_pins axis_register_slice_1/aresetn]]
  if {$nch > 1} {
    lappend dclk [get_bd_pins axis_broadcaster_0/aclk]
    lappend drst [get_bd_pins axis_broadcaster_0/aresetn]
  }
  for {set t 0} {$t < 4} {incr t} {
    lappend aclk [get_bd_pins usp_rf_data_converter/m${t}_axis_aclk]
    lappend arst [get_bd_pins usp_rf_data_converter/m${t}_axis_aresetn]
    lappend dclk [get_bd_pins usp_rf_data_converter/s${t}_axis_aclk]
    lappend drst [get_bd_pins usp_rf_data_converter/s${t}_axis_aresetn]
  }
  connect_bd_net -net adc_axis_clk_1 {*}$aclk
  connect_bd_net -net adc_axis_aresetn_1 {*}$arst
  connect_bd_net -net dac_axis_clk_1 {*}$dclk
  connect_bd_net -net dac_axis_aresetn_1 {*}$drst
  connect_bd_net -net s_axi_aclk_1 [get_bd_pins s_axi_aclk] [get_bd_pins usp_rf_data_converter/s_axi_aclk]
  connect_bd_net -net s_axi_aresetn_1 [get_bd_pins s_axi_aresetn] [get_bd_pins usp_rf_data_converter/s_axi_aresetn]
  connect_bd_net -net user_sysref_adc_1 [get_bd_pins user_sysref_adc] [get_bd_pins usp_rf_data_converter/user_sysref_adc]
  connect_bd_net -net user_sysref_dac_1 [get_bd_pins user_sysref_dac] [get_bd_pins usp_rf_data_converter/user_sysref_dac]
  connect_bd_net -net usp_rf_data_converter_irq [get_bd_pins irq] [get_bd_pins usp_rf_data_converter/irq]

  current_bd_instance $oldCurInst
}

# The RFDC's analog pins: the dual RF-ADC tiles' inputs and each DAC tile's
# block 0
proc v49_vins {} { return {vin0_01 vin0_23 vin1_01 vin2_01 vin2_23 vin3_01} }
proc v49_vouts {} { return {vout00 vout10 vout20 vout30} }

# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell nch } {

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }
  set oldCurInst [current_bd_instance .]
  current_bd_instance [get_bd_cells $parentCell]
  set g [v49_geometry $nch $::V49_FACTOR]

  # Create interface ports
  set PL_CLK [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 PL_CLK ]
  set_property -dict [ list \
   CONFIG.FREQ_HZ {300000000} \
   ] $PL_CLK

  set PL_SYSREF [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 PL_SYSREF ]
  set_property -dict [ list \
   CONFIG.FREQ_HZ {10000000} \
   ] $PL_SYSREF

  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 adc2_clk
  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 dac2_clk

  set sysref_in [ create_bd_intf_port -mode Slave -vlnv xilinx.com:display_usp_rf_data_converter:diff_pins_rtl:1.0 -portmaps { \
   diff_n { physical_name sysref_in_diff_n direction I } \
   diff_p { physical_name sysref_in_diff_p direction I } \
   } \
  sysref_in ]
  set_property HDL_ATTRIBUTE.LOCKED {TRUE} [get_bd_intf_ports sysref_in]

  foreach v [v49_vins] {
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 $v
  }
  foreach v [v49_vouts] {
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 $v
  }

  # Create ports
  create_bd_port -dir O -from 1 -to 0 led_g
  create_bd_port -dir O -from 1 -to 0 led_r

  # Create instance: MTS_block
  create_hier_cell_MTS_block [current_bd_instance .] MTS_block

  # Create instance: adc_clk_aresetn, and set properties
  set adc_clk_aresetn [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 adc_clk_aresetn ]

  # Create instance: axi_gpio_led, and set properties
  set axi_gpio_led [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led ]
  set_property -dict [ list \
   CONFIG.C_ALL_OUTPUTS {1} \
   CONFIG.C_ALL_OUTPUTS_2 {1} \
   CONFIG.C_GPIO2_WIDTH {2} \
   CONFIG.C_GPIO_WIDTH {2} \
   CONFIG.C_IS_DUAL {1} \
   CONFIG.GPIO2_BOARD_INTERFACE {Custom} \
   CONFIG.GPIO_BOARD_INTERFACE {Custom} \
   CONFIG.USE_BOARD_FLOW {true} \
 ] $axi_gpio_led

  # Create instance: axi_interconnect_pl -- the PL control smartconnect:
  # M00 rfdc, M01 axi_gpio_led, M02 MTS_clk_wiz, M03 axi_intp, then the
  # eth100g slaves (v49_eth100g_slaves)
  set slaves [v49_eth100g_slaves $nch]
  set axi_interconnect_pl [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_interconnect_pl ]
  set_property -dict [ list \
   CONFIG.NUM_MI [expr {4 + [llength $slaves]}] \
   CONFIG.NUM_SI {1} \
 ] $axi_interconnect_pl

  # Create instance: axi_intp, and set properties
  set axi_intp [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intp ]

  # Create instance: dac_adc_clk_aresetn, and set properties
  set dac_adc_clk_aresetn [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 dac_adc_clk_aresetn ]

  # Create instance: intp_concat -- In0 MTS_clk_wiz, In1 rfdc
  set intp_concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 intp_concat ]
  set_property -dict [ list \
   CONFIG.NUM_PORTS {2} \
 ] $intp_concat

  # Create instance: proc_sys_reset_pl, and set properties
  set proc_sys_reset_pl [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_pl ]

  # Create instance: rfdc
  create_hier_cell_rfdc [current_bd_instance .] rfdc $nch

  # Synchronize PL SYSREF independently into the ADC and DAC MTS AXIS domains.
  set SYSREF_sync_adc [ create_bd_cell -type ip -vlnv xilinx.com:ip:xpm_cdc_gen:1.0 SYSREF_sync_adc ]
  set_property -dict [ list \
   CONFIG.CDC_TYPE {xpm_cdc_single} \
   CONFIG.DEST_SYNC_FF {2} \
   CONFIG.INIT_SYNC_FF {true} \
   CONFIG.WIDTH {1} \
 ] $SYSREF_sync_adc

  set SYSREF_sync_dac [ create_bd_cell -type ip -vlnv xilinx.com:ip:xpm_cdc_gen:1.0 SYSREF_sync_dac ]
  set_property -dict [ list \
   CONFIG.CDC_TYPE {xpm_cdc_single} \
   CONFIG.DEST_SYNC_FF {2} \
   CONFIG.INIT_SYNC_FF {true} \
   CONFIG.WIDTH {1} \
 ] $SYSREF_sync_dac

  # Create instance: eth100g -- the 100GbE / UHD data plane
  create_hier_cell_eth100g [current_bd_instance .] eth100g $nch [dict get $g beat_w] [dict get $g bf_pipe]

  # Create instance: zynq_ultra_ps_e, and set properties
  set zynq_ultra_ps_e [ create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.3 zynq_ultra_ps_e ]
  set_property -dict [ list \
   CONFIG.CAN0_BOARD_INTERFACE {custom} \
   CONFIG.CAN1_BOARD_INTERFACE {custom} \
   CONFIG.CSU_BOARD_INTERFACE {custom} \
   CONFIG.DP_BOARD_INTERFACE {custom} \
   CONFIG.GEM0_BOARD_INTERFACE {custom} \
   CONFIG.GEM1_BOARD_INTERFACE {custom} \
   CONFIG.GEM2_BOARD_INTERFACE {custom} \
   CONFIG.GEM3_BOARD_INTERFACE {custom} \
   CONFIG.GPIO_BOARD_INTERFACE {custom} \
   CONFIG.IIC0_BOARD_INTERFACE {custom} \
   CONFIG.IIC1_BOARD_INTERFACE {custom} \
   CONFIG.NAND_BOARD_INTERFACE {custom} \
   CONFIG.PCIE_BOARD_INTERFACE {custom} \
   CONFIG.PJTAG_BOARD_INTERFACE {custom} \
   CONFIG.PMU_BOARD_INTERFACE {custom} \
   CONFIG.PSU_BANK_0_IO_STANDARD {LVCMOS18} \
   CONFIG.PSU_BANK_1_IO_STANDARD {LVCMOS18} \
   CONFIG.PSU_BANK_2_IO_STANDARD {LVCMOS18} \
   CONFIG.PSU_BANK_3_IO_STANDARD {LVCMOS33} \
   CONFIG.PSU_DDR_RAM_HIGHADDR {0xFFFFFFFF} \
   CONFIG.PSU_DDR_RAM_HIGHADDR_OFFSET {0x800000000} \
   CONFIG.PSU_DDR_RAM_LOWADDR_OFFSET {0x80000000} \
   CONFIG.PSU_DYNAMIC_DDR_CONFIG_EN {0} \
   CONFIG.PSU_IMPORT_BOARD_PRESET {} \
   CONFIG.PSU_MIO_0_DIRECTION {out} \
   CONFIG.PSU_MIO_0_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_0_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_0_POLARITY {Default} \
   CONFIG.PSU_MIO_0_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_0_SLEW {fast} \
   CONFIG.PSU_MIO_10_DIRECTION {inout} \
   CONFIG.PSU_MIO_10_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_10_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_10_POLARITY {Default} \
   CONFIG.PSU_MIO_10_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_10_SLEW {fast} \
   CONFIG.PSU_MIO_11_DIRECTION {inout} \
   CONFIG.PSU_MIO_11_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_11_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_11_POLARITY {Default} \
   CONFIG.PSU_MIO_11_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_11_SLEW {fast} \
   CONFIG.PSU_MIO_12_DIRECTION {out} \
   CONFIG.PSU_MIO_12_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_12_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_12_POLARITY {Default} \
   CONFIG.PSU_MIO_12_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_12_SLEW {fast} \
   CONFIG.PSU_MIO_13_DIRECTION {inout} \
   CONFIG.PSU_MIO_13_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_13_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_13_POLARITY {Default} \
   CONFIG.PSU_MIO_13_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_13_SLEW {fast} \
   CONFIG.PSU_MIO_14_DIRECTION {inout} \
   CONFIG.PSU_MIO_14_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_14_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_14_POLARITY {Default} \
   CONFIG.PSU_MIO_14_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_14_SLEW {fast} \
   CONFIG.PSU_MIO_15_DIRECTION {inout} \
   CONFIG.PSU_MIO_15_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_15_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_15_POLARITY {Default} \
   CONFIG.PSU_MIO_15_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_15_SLEW {fast} \
   CONFIG.PSU_MIO_16_DIRECTION {inout} \
   CONFIG.PSU_MIO_16_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_16_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_16_POLARITY {Default} \
   CONFIG.PSU_MIO_16_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_16_SLEW {fast} \
   CONFIG.PSU_MIO_17_DIRECTION {inout} \
   CONFIG.PSU_MIO_17_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_17_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_17_POLARITY {Default} \
   CONFIG.PSU_MIO_17_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_17_SLEW {fast} \
   CONFIG.PSU_MIO_18_DIRECTION {in} \
   CONFIG.PSU_MIO_18_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_18_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_18_POLARITY {Default} \
   CONFIG.PSU_MIO_18_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_18_SLEW {fast} \
   CONFIG.PSU_MIO_19_DIRECTION {out} \
   CONFIG.PSU_MIO_19_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_19_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_19_POLARITY {Default} \
   CONFIG.PSU_MIO_19_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_19_SLEW {fast} \
   CONFIG.PSU_MIO_1_DIRECTION {inout} \
   CONFIG.PSU_MIO_1_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_1_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_1_POLARITY {Default} \
   CONFIG.PSU_MIO_1_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_1_SLEW {fast} \
   CONFIG.PSU_MIO_20_DIRECTION {inout} \
   CONFIG.PSU_MIO_20_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_20_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_20_POLARITY {Default} \
   CONFIG.PSU_MIO_20_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_20_SLEW {fast} \
   CONFIG.PSU_MIO_21_DIRECTION {inout} \
   CONFIG.PSU_MIO_21_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_21_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_21_POLARITY {Default} \
   CONFIG.PSU_MIO_21_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_21_SLEW {fast} \
   CONFIG.PSU_MIO_22_DIRECTION {inout} \
   CONFIG.PSU_MIO_22_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_22_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_22_POLARITY {Default} \
   CONFIG.PSU_MIO_22_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_22_SLEW {fast} \
   CONFIG.PSU_MIO_23_DIRECTION {inout} \
   CONFIG.PSU_MIO_23_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_23_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_23_POLARITY {Default} \
   CONFIG.PSU_MIO_23_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_23_SLEW {fast} \
   CONFIG.PSU_MIO_24_DIRECTION {inout} \
   CONFIG.PSU_MIO_24_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_24_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_24_POLARITY {Default} \
   CONFIG.PSU_MIO_24_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_24_SLEW {fast} \
   CONFIG.PSU_MIO_25_DIRECTION {inout} \
   CONFIG.PSU_MIO_25_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_25_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_25_POLARITY {Default} \
   CONFIG.PSU_MIO_25_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_25_SLEW {fast} \
   CONFIG.PSU_MIO_26_DIRECTION {inout} \
   CONFIG.PSU_MIO_26_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_26_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_26_POLARITY {Default} \
   CONFIG.PSU_MIO_26_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_26_SLEW {fast} \
   CONFIG.PSU_MIO_27_DIRECTION {out} \
   CONFIG.PSU_MIO_27_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_27_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_27_POLARITY {Default} \
   CONFIG.PSU_MIO_27_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_27_SLEW {fast} \
   CONFIG.PSU_MIO_28_DIRECTION {in} \
   CONFIG.PSU_MIO_28_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_28_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_28_POLARITY {Default} \
   CONFIG.PSU_MIO_28_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_28_SLEW {fast} \
   CONFIG.PSU_MIO_29_DIRECTION {out} \
   CONFIG.PSU_MIO_29_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_29_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_29_POLARITY {Default} \
   CONFIG.PSU_MIO_29_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_29_SLEW {fast} \
   CONFIG.PSU_MIO_2_DIRECTION {inout} \
   CONFIG.PSU_MIO_2_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_2_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_2_POLARITY {Default} \
   CONFIG.PSU_MIO_2_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_2_SLEW {fast} \
   CONFIG.PSU_MIO_30_DIRECTION {in} \
   CONFIG.PSU_MIO_30_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_30_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_30_POLARITY {Default} \
   CONFIG.PSU_MIO_30_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_30_SLEW {fast} \
   CONFIG.PSU_MIO_31_DIRECTION {inout} \
   CONFIG.PSU_MIO_31_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_31_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_31_POLARITY {Default} \
   CONFIG.PSU_MIO_31_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_31_SLEW {fast} \
   CONFIG.PSU_MIO_32_DIRECTION {out} \
   CONFIG.PSU_MIO_32_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_32_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_32_POLARITY {Default} \
   CONFIG.PSU_MIO_32_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_32_SLEW {fast} \
   CONFIG.PSU_MIO_33_DIRECTION {out} \
   CONFIG.PSU_MIO_33_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_33_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_33_POLARITY {Default} \
   CONFIG.PSU_MIO_33_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_33_SLEW {fast} \
   CONFIG.PSU_MIO_34_DIRECTION {out} \
   CONFIG.PSU_MIO_34_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_34_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_34_POLARITY {Default} \
   CONFIG.PSU_MIO_34_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_34_SLEW {fast} \
   CONFIG.PSU_MIO_35_DIRECTION {out} \
   CONFIG.PSU_MIO_35_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_35_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_35_POLARITY {Default} \
   CONFIG.PSU_MIO_35_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_35_SLEW {fast} \
   CONFIG.PSU_MIO_36_DIRECTION {out} \
   CONFIG.PSU_MIO_36_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_36_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_36_POLARITY {Default} \
   CONFIG.PSU_MIO_36_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_36_SLEW {fast} \
   CONFIG.PSU_MIO_37_DIRECTION {out} \
   CONFIG.PSU_MIO_37_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_37_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_37_POLARITY {Default} \
   CONFIG.PSU_MIO_37_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_37_SLEW {fast} \
   CONFIG.PSU_MIO_38_DIRECTION {inout} \
   CONFIG.PSU_MIO_38_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_38_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_38_POLARITY {Default} \
   CONFIG.PSU_MIO_38_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_38_SLEW {fast} \
   CONFIG.PSU_MIO_39_DIRECTION {inout} \
   CONFIG.PSU_MIO_39_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_39_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_39_POLARITY {Default} \
   CONFIG.PSU_MIO_39_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_39_SLEW {fast} \
   CONFIG.PSU_MIO_3_DIRECTION {inout} \
   CONFIG.PSU_MIO_3_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_3_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_3_POLARITY {Default} \
   CONFIG.PSU_MIO_3_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_3_SLEW {fast} \
   CONFIG.PSU_MIO_40_DIRECTION {inout} \
   CONFIG.PSU_MIO_40_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_40_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_40_POLARITY {Default} \
   CONFIG.PSU_MIO_40_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_40_SLEW {fast} \
   CONFIG.PSU_MIO_41_DIRECTION {inout} \
   CONFIG.PSU_MIO_41_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_41_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_41_POLARITY {Default} \
   CONFIG.PSU_MIO_41_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_41_SLEW {fast} \
   CONFIG.PSU_MIO_42_DIRECTION {inout} \
   CONFIG.PSU_MIO_42_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_42_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_42_POLARITY {Default} \
   CONFIG.PSU_MIO_42_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_42_SLEW {fast} \
   CONFIG.PSU_MIO_43_DIRECTION {inout} \
   CONFIG.PSU_MIO_43_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_43_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_43_POLARITY {Default} \
   CONFIG.PSU_MIO_43_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_43_SLEW {fast} \
   CONFIG.PSU_MIO_44_DIRECTION {inout} \
   CONFIG.PSU_MIO_44_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_44_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_44_POLARITY {Default} \
   CONFIG.PSU_MIO_44_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_44_SLEW {fast} \
   CONFIG.PSU_MIO_45_DIRECTION {in} \
   CONFIG.PSU_MIO_45_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_45_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_45_POLARITY {Default} \
   CONFIG.PSU_MIO_45_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_45_SLEW {fast} \
   CONFIG.PSU_MIO_46_DIRECTION {inout} \
   CONFIG.PSU_MIO_46_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_46_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_46_POLARITY {Default} \
   CONFIG.PSU_MIO_46_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_46_SLEW {fast} \
   CONFIG.PSU_MIO_47_DIRECTION {inout} \
   CONFIG.PSU_MIO_47_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_47_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_47_POLARITY {Default} \
   CONFIG.PSU_MIO_47_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_47_SLEW {fast} \
   CONFIG.PSU_MIO_48_DIRECTION {inout} \
   CONFIG.PSU_MIO_48_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_48_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_48_POLARITY {Default} \
   CONFIG.PSU_MIO_48_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_48_SLEW {fast} \
   CONFIG.PSU_MIO_49_DIRECTION {inout} \
   CONFIG.PSU_MIO_49_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_49_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_49_POLARITY {Default} \
   CONFIG.PSU_MIO_49_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_49_SLEW {fast} \
   CONFIG.PSU_MIO_4_DIRECTION {inout} \
   CONFIG.PSU_MIO_4_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_4_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_4_POLARITY {Default} \
   CONFIG.PSU_MIO_4_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_4_SLEW {fast} \
   CONFIG.PSU_MIO_50_DIRECTION {inout} \
   CONFIG.PSU_MIO_50_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_50_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_50_POLARITY {Default} \
   CONFIG.PSU_MIO_50_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_50_SLEW {fast} \
   CONFIG.PSU_MIO_51_DIRECTION {out} \
   CONFIG.PSU_MIO_51_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_51_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_51_POLARITY {Default} \
   CONFIG.PSU_MIO_51_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_51_SLEW {fast} \
   CONFIG.PSU_MIO_52_DIRECTION {in} \
   CONFIG.PSU_MIO_52_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_52_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_52_POLARITY {Default} \
   CONFIG.PSU_MIO_52_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_52_SLEW {fast} \
   CONFIG.PSU_MIO_53_DIRECTION {in} \
   CONFIG.PSU_MIO_53_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_53_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_53_POLARITY {Default} \
   CONFIG.PSU_MIO_53_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_53_SLEW {fast} \
   CONFIG.PSU_MIO_54_DIRECTION {inout} \
   CONFIG.PSU_MIO_54_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_54_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_54_POLARITY {Default} \
   CONFIG.PSU_MIO_54_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_54_SLEW {fast} \
   CONFIG.PSU_MIO_55_DIRECTION {in} \
   CONFIG.PSU_MIO_55_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_55_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_55_POLARITY {Default} \
   CONFIG.PSU_MIO_55_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_55_SLEW {fast} \
   CONFIG.PSU_MIO_56_DIRECTION {inout} \
   CONFIG.PSU_MIO_56_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_56_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_56_POLARITY {Default} \
   CONFIG.PSU_MIO_56_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_56_SLEW {fast} \
   CONFIG.PSU_MIO_57_DIRECTION {inout} \
   CONFIG.PSU_MIO_57_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_57_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_57_POLARITY {Default} \
   CONFIG.PSU_MIO_57_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_57_SLEW {fast} \
   CONFIG.PSU_MIO_58_DIRECTION {out} \
   CONFIG.PSU_MIO_58_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_58_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_58_POLARITY {Default} \
   CONFIG.PSU_MIO_58_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_58_SLEW {fast} \
   CONFIG.PSU_MIO_59_DIRECTION {inout} \
   CONFIG.PSU_MIO_59_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_59_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_59_POLARITY {Default} \
   CONFIG.PSU_MIO_59_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_59_SLEW {fast} \
   CONFIG.PSU_MIO_5_DIRECTION {out} \
   CONFIG.PSU_MIO_5_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_5_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_5_POLARITY {Default} \
   CONFIG.PSU_MIO_5_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_5_SLEW {fast} \
   CONFIG.PSU_MIO_60_DIRECTION {inout} \
   CONFIG.PSU_MIO_60_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_60_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_60_POLARITY {Default} \
   CONFIG.PSU_MIO_60_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_60_SLEW {fast} \
   CONFIG.PSU_MIO_61_DIRECTION {inout} \
   CONFIG.PSU_MIO_61_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_61_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_61_POLARITY {Default} \
   CONFIG.PSU_MIO_61_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_61_SLEW {fast} \
   CONFIG.PSU_MIO_62_DIRECTION {inout} \
   CONFIG.PSU_MIO_62_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_62_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_62_POLARITY {Default} \
   CONFIG.PSU_MIO_62_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_62_SLEW {fast} \
   CONFIG.PSU_MIO_63_DIRECTION {inout} \
   CONFIG.PSU_MIO_63_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_63_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_63_POLARITY {Default} \
   CONFIG.PSU_MIO_63_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_63_SLEW {fast} \
   CONFIG.PSU_MIO_64_DIRECTION {out} \
   CONFIG.PSU_MIO_64_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_64_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_64_POLARITY {Default} \
   CONFIG.PSU_MIO_64_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_64_SLEW {fast} \
   CONFIG.PSU_MIO_65_DIRECTION {out} \
   CONFIG.PSU_MIO_65_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_65_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_65_POLARITY {Default} \
   CONFIG.PSU_MIO_65_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_65_SLEW {fast} \
   CONFIG.PSU_MIO_66_DIRECTION {out} \
   CONFIG.PSU_MIO_66_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_66_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_66_POLARITY {Default} \
   CONFIG.PSU_MIO_66_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_66_SLEW {fast} \
   CONFIG.PSU_MIO_67_DIRECTION {out} \
   CONFIG.PSU_MIO_67_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_67_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_67_POLARITY {Default} \
   CONFIG.PSU_MIO_67_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_67_SLEW {fast} \
   CONFIG.PSU_MIO_68_DIRECTION {out} \
   CONFIG.PSU_MIO_68_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_68_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_68_POLARITY {Default} \
   CONFIG.PSU_MIO_68_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_68_SLEW {fast} \
   CONFIG.PSU_MIO_69_DIRECTION {out} \
   CONFIG.PSU_MIO_69_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_69_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_69_POLARITY {Default} \
   CONFIG.PSU_MIO_69_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_69_SLEW {fast} \
   CONFIG.PSU_MIO_6_DIRECTION {out} \
   CONFIG.PSU_MIO_6_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_6_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_6_POLARITY {Default} \
   CONFIG.PSU_MIO_6_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_6_SLEW {fast} \
   CONFIG.PSU_MIO_70_DIRECTION {in} \
   CONFIG.PSU_MIO_70_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_70_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_70_POLARITY {Default} \
   CONFIG.PSU_MIO_70_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_70_SLEW {fast} \
   CONFIG.PSU_MIO_71_DIRECTION {in} \
   CONFIG.PSU_MIO_71_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_71_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_71_POLARITY {Default} \
   CONFIG.PSU_MIO_71_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_71_SLEW {fast} \
   CONFIG.PSU_MIO_72_DIRECTION {in} \
   CONFIG.PSU_MIO_72_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_72_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_72_POLARITY {Default} \
   CONFIG.PSU_MIO_72_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_72_SLEW {fast} \
   CONFIG.PSU_MIO_73_DIRECTION {in} \
   CONFIG.PSU_MIO_73_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_73_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_73_POLARITY {Default} \
   CONFIG.PSU_MIO_73_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_73_SLEW {fast} \
   CONFIG.PSU_MIO_74_DIRECTION {in} \
   CONFIG.PSU_MIO_74_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_74_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_74_POLARITY {Default} \
   CONFIG.PSU_MIO_74_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_74_SLEW {fast} \
   CONFIG.PSU_MIO_75_DIRECTION {in} \
   CONFIG.PSU_MIO_75_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_75_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_75_POLARITY {Default} \
   CONFIG.PSU_MIO_75_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_75_SLEW {fast} \
   CONFIG.PSU_MIO_76_DIRECTION {out} \
   CONFIG.PSU_MIO_76_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_76_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_76_POLARITY {Default} \
   CONFIG.PSU_MIO_76_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_76_SLEW {fast} \
   CONFIG.PSU_MIO_77_DIRECTION {inout} \
   CONFIG.PSU_MIO_77_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_77_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_77_POLARITY {Default} \
   CONFIG.PSU_MIO_77_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_77_SLEW {fast} \
   CONFIG.PSU_MIO_7_DIRECTION {out} \
   CONFIG.PSU_MIO_7_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_7_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_7_POLARITY {Default} \
   CONFIG.PSU_MIO_7_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_7_SLEW {fast} \
   CONFIG.PSU_MIO_8_DIRECTION {inout} \
   CONFIG.PSU_MIO_8_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_8_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_8_POLARITY {Default} \
   CONFIG.PSU_MIO_8_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_8_SLEW {fast} \
   CONFIG.PSU_MIO_9_DIRECTION {inout} \
   CONFIG.PSU_MIO_9_DRIVE_STRENGTH {12} \
   CONFIG.PSU_MIO_9_INPUT_TYPE {cmos} \
   CONFIG.PSU_MIO_9_POLARITY {Default} \
   CONFIG.PSU_MIO_9_PULLUPDOWN {pullup} \
   CONFIG.PSU_MIO_9_SLEW {fast} \
   CONFIG.PSU_MIO_TREE_PERIPHERALS {Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad\
SPI Flash#Feedback Clk#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI\
Flash#Quad SPI Flash#Quad SPI Flash#GPIO0 MIO#I2C 0#I2C 0#I2C 1#I2C 1#UART\
0#UART 0#GPIO0 MIO#GPIO0 MIO#GPIO0 MIO#GPIO0 MIO#GPIO0 MIO#GPIO0 MIO#GPIO1\
MIO#DPAUX#DPAUX#DPAUX#DPAUX#GPIO1 MIO#PMU GPO 0#PMU GPO 1#PMU GPO 2#PMU GPO\
3#PMU GPO 4#PMU GPO 5#GPIO1 MIO#SD 1#SD 1#SD 1#SD 1#GPIO1 MIO#GPIO1 MIO#SD 1#SD\
1#SD 1#SD 1#SD 1#SD 1#SD 1#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB 0#USB\
0#USB 0#USB 0#USB 0#Gem 3#Gem 3#Gem 3#Gem 3#Gem 3#Gem 3#Gem 3#Gem 3#Gem 3#Gem\
3#Gem 3#Gem 3#MDIO 3#MDIO 3}\
   CONFIG.PSU_MIO_TREE_SIGNALS {sclk_out#miso_mo1#mo2#mo3#mosi_mi0#n_ss_out#clk_for_lpbk#n_ss_out_upper#mo_upper[0]#mo_upper[1]#mo_upper[2]#mo_upper[3]#sclk_out_upper#gpio0[13]#scl_out#sda_out#scl_out#sda_out#rxd#txd#gpio0[20]#gpio0[21]#gpio0[22]#gpio0[23]#gpio0[24]#gpio0[25]#gpio1[26]#dp_aux_data_out#dp_hot_plug_detect#dp_aux_data_oe#dp_aux_data_in#gpio1[31]#gpo[0]#gpo[1]#gpo[2]#gpo[3]#gpo[4]#gpo[5]#gpio1[38]#sdio1_data_out[4]#sdio1_data_out[5]#sdio1_data_out[6]#sdio1_data_out[7]#gpio1[43]#gpio1[44]#sdio1_cd_n#sdio1_data_out[0]#sdio1_data_out[1]#sdio1_data_out[2]#sdio1_data_out[3]#sdio1_cmd_out#sdio1_clk_out#ulpi_clk_in#ulpi_dir#ulpi_tx_data[2]#ulpi_nxt#ulpi_tx_data[0]#ulpi_tx_data[1]#ulpi_stp#ulpi_tx_data[3]#ulpi_tx_data[4]#ulpi_tx_data[5]#ulpi_tx_data[6]#ulpi_tx_data[7]#rgmii_tx_clk#rgmii_txd[0]#rgmii_txd[1]#rgmii_txd[2]#rgmii_txd[3]#rgmii_tx_ctl#rgmii_rx_clk#rgmii_rxd[0]#rgmii_rxd[1]#rgmii_rxd[2]#rgmii_rxd[3]#rgmii_rx_ctl#gem3_mdc#gem3_mdio_out}\
   CONFIG.PSU_PERIPHERAL_BOARD_PRESET {} \
   CONFIG.PSU_SD0_INTERNAL_BUS_WIDTH {8} \
   CONFIG.PSU_SD1_INTERNAL_BUS_WIDTH {8} \
   CONFIG.PSU_SMC_CYCLE_T0 {NA} \
   CONFIG.PSU_SMC_CYCLE_T1 {NA} \
   CONFIG.PSU_SMC_CYCLE_T2 {NA} \
   CONFIG.PSU_SMC_CYCLE_T3 {NA} \
   CONFIG.PSU_SMC_CYCLE_T4 {NA} \
   CONFIG.PSU_SMC_CYCLE_T5 {NA} \
   CONFIG.PSU_SMC_CYCLE_T6 {NA} \
   CONFIG.PSU_USB3__DUAL_CLOCK_ENABLE {1} \
   CONFIG.PSU_VALUE_SILVERSION {3} \
   CONFIG.PSU__ACPU0__POWER__ON {1} \
   CONFIG.PSU__ACPU1__POWER__ON {1} \
   CONFIG.PSU__ACPU2__POWER__ON {1} \
   CONFIG.PSU__ACPU3__POWER__ON {1} \
   CONFIG.PSU__ACTUAL__IP {1} \
   CONFIG.PSU__ACT_DDR_FREQ_MHZ {1066.656006} \
   CONFIG.PSU__AFI0_COHERENCY {0} \
   CONFIG.PSU__AFI1_COHERENCY {0} \
   CONFIG.PSU__AUX_REF_CLK__FREQMHZ {33.333} \
   CONFIG.PSU__CAN0_LOOP_CAN1__ENABLE {0} \
   CONFIG.PSU__CAN0__GRP_CLK__ENABLE {0} \
   CONFIG.PSU__CAN0__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__CAN1__GRP_CLK__ENABLE {0} \
   CONFIG.PSU__CAN1__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__CRF_APB__ACPU_CTRL__ACT_FREQMHZ {1199.988037} \
   CONFIG.PSU__CRF_APB__ACPU_CTRL__DIVISOR0 {1} \
   CONFIG.PSU__CRF_APB__ACPU_CTRL__FREQMHZ {1200} \
   CONFIG.PSU__CRF_APB__ACPU_CTRL__SRCSEL {APLL} \
   CONFIG.PSU__CRF_APB__ACPU__FRAC_ENABLED {0} \
   CONFIG.PSU__CRF_APB__AFI0_REF_CTRL__ACT_FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI0_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__AFI0_REF_CTRL__FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI0_REF_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__AFI0_REF__ENABLE {0} \
   CONFIG.PSU__CRF_APB__AFI1_REF_CTRL__ACT_FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI1_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__AFI1_REF_CTRL__FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI1_REF_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__AFI1_REF__ENABLE {0} \
   CONFIG.PSU__CRF_APB__AFI2_REF_CTRL__ACT_FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI2_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__AFI2_REF_CTRL__FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI2_REF_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__AFI2_REF__ENABLE {0} \
   CONFIG.PSU__CRF_APB__AFI3_REF_CTRL__ACT_FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI3_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__AFI3_REF_CTRL__FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI3_REF_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__AFI3_REF__ENABLE {0} \
   CONFIG.PSU__CRF_APB__AFI4_REF_CTRL__ACT_FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI4_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__AFI4_REF_CTRL__FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI4_REF_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__AFI4_REF__ENABLE {0} \
   CONFIG.PSU__CRF_APB__AFI5_REF_CTRL__ACT_FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI5_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__AFI5_REF_CTRL__FREQMHZ {667} \
   CONFIG.PSU__CRF_APB__AFI5_REF_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__AFI5_REF__ENABLE {0} \
   CONFIG.PSU__CRF_APB__APLL_CTRL__DIV2 {1} \
   CONFIG.PSU__CRF_APB__APLL_CTRL__FBDIV {72} \
   CONFIG.PSU__CRF_APB__APLL_CTRL__FRACDATA {0.000000} \
   CONFIG.PSU__CRF_APB__APLL_CTRL__FRACFREQ {27.138} \
   CONFIG.PSU__CRF_APB__APLL_CTRL__SRCSEL {PSS_REF_CLK} \
   CONFIG.PSU__CRF_APB__APLL_FRAC_CFG__ENABLED {0} \
   CONFIG.PSU__CRF_APB__APLL_TO_LPD_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRF_APB__APM_CTRL__ACT_FREQMHZ {1} \
   CONFIG.PSU__CRF_APB__APM_CTRL__DIVISOR0 {1} \
   CONFIG.PSU__CRF_APB__APM_CTRL__FREQMHZ {1} \
   CONFIG.PSU__CRF_APB__DBG_FPD_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRF_APB__DBG_FPD_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__DBG_FPD_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__DBG_FPD_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__DBG_TRACE_CTRL__ACT_FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__DBG_TRACE_CTRL__DIVISOR0 {5} \
   CONFIG.PSU__CRF_APB__DBG_TRACE_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__DBG_TRACE_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__DBG_TSTMP_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRF_APB__DBG_TSTMP_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__DBG_TSTMP_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__DBG_TSTMP_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__DDR_CTRL__ACT_FREQMHZ {533.328003} \
   CONFIG.PSU__CRF_APB__DDR_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__DDR_CTRL__FREQMHZ {1067} \
   CONFIG.PSU__CRF_APB__DDR_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__DPDMA_REF_CTRL__ACT_FREQMHZ {599.994019} \
   CONFIG.PSU__CRF_APB__DPDMA_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__DPDMA_REF_CTRL__FREQMHZ {600} \
   CONFIG.PSU__CRF_APB__DPDMA_REF_CTRL__SRCSEL {APLL} \
   CONFIG.PSU__CRF_APB__DPLL_CTRL__DIV2 {1} \
   CONFIG.PSU__CRF_APB__DPLL_CTRL__FBDIV {64} \
   CONFIG.PSU__CRF_APB__DPLL_CTRL__FRACDATA {0.000000} \
   CONFIG.PSU__CRF_APB__DPLL_CTRL__FRACFREQ {27.138} \
   CONFIG.PSU__CRF_APB__DPLL_CTRL__SRCSEL {PSS_REF_CLK} \
   CONFIG.PSU__CRF_APB__DPLL_FRAC_CFG__ENABLED {0} \
   CONFIG.PSU__CRF_APB__DPLL_TO_LPD_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__DP_AUDIO_REF_CTRL__ACT_FREQMHZ {24.999750} \
   CONFIG.PSU__CRF_APB__DP_AUDIO_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRF_APB__DP_AUDIO_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRF_APB__DP_AUDIO_REF_CTRL__FREQMHZ {25} \
   CONFIG.PSU__CRF_APB__DP_AUDIO_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRF_APB__DP_AUDIO__FRAC_ENABLED {0} \
   CONFIG.PSU__CRF_APB__DP_STC_REF_CTRL__ACT_FREQMHZ {26.785446} \
   CONFIG.PSU__CRF_APB__DP_STC_REF_CTRL__DIVISOR0 {14} \
   CONFIG.PSU__CRF_APB__DP_STC_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRF_APB__DP_STC_REF_CTRL__FREQMHZ {27} \
   CONFIG.PSU__CRF_APB__DP_STC_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__ACT_FREQMHZ {299.997009} \
   CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__DIVISOR0 {5} \
   CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__FREQMHZ {300} \
   CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__SRCSEL {VPLL} \
   CONFIG.PSU__CRF_APB__DP_VIDEO__FRAC_ENABLED {0} \
   CONFIG.PSU__CRF_APB__GDMA_REF_CTRL__ACT_FREQMHZ {599.994019} \
   CONFIG.PSU__CRF_APB__GDMA_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__GDMA_REF_CTRL__FREQMHZ {600} \
   CONFIG.PSU__CRF_APB__GDMA_REF_CTRL__SRCSEL {APLL} \
   CONFIG.PSU__CRF_APB__GPU_REF_CTRL__ACT_FREQMHZ {0} \
   CONFIG.PSU__CRF_APB__GPU_REF_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRF_APB__GPU_REF_CTRL__FREQMHZ {500} \
   CONFIG.PSU__CRF_APB__GPU_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__GTGREF0_REF_CTRL__ACT_FREQMHZ {-1} \
   CONFIG.PSU__CRF_APB__GTGREF0_REF_CTRL__DIVISOR0 {-1} \
   CONFIG.PSU__CRF_APB__GTGREF0_REF_CTRL__FREQMHZ {-1} \
   CONFIG.PSU__CRF_APB__GTGREF0_REF_CTRL__SRCSEL {NA} \
   CONFIG.PSU__CRF_APB__GTGREF0__ENABLE {NA} \
   CONFIG.PSU__CRF_APB__PCIE_REF_CTRL__ACT_FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__PCIE_REF_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRF_APB__PCIE_REF_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__PCIE_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__SATA_REF_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRF_APB__SATA_REF_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__SATA_REF_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRF_APB__SATA_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__TOPSW_LSBUS_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRF_APB__TOPSW_LSBUS_CTRL__DIVISOR0 {5} \
   CONFIG.PSU__CRF_APB__TOPSW_LSBUS_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRF_APB__TOPSW_LSBUS_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRF_APB__TOPSW_MAIN_CTRL__ACT_FREQMHZ {533.328003} \
   CONFIG.PSU__CRF_APB__TOPSW_MAIN_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRF_APB__TOPSW_MAIN_CTRL__FREQMHZ {533.33} \
   CONFIG.PSU__CRF_APB__TOPSW_MAIN_CTRL__SRCSEL {DPLL} \
   CONFIG.PSU__CRF_APB__VPLL_CTRL__DIV2 {1} \
   CONFIG.PSU__CRF_APB__VPLL_CTRL__FBDIV {90} \
   CONFIG.PSU__CRF_APB__VPLL_CTRL__FRACDATA {0.000000} \
   CONFIG.PSU__CRF_APB__VPLL_CTRL__FRACFREQ {27.138} \
   CONFIG.PSU__CRF_APB__VPLL_CTRL__SRCSEL {PSS_REF_CLK} \
   CONFIG.PSU__CRF_APB__VPLL_FRAC_CFG__ENABLED {0} \
   CONFIG.PSU__CRF_APB__VPLL_TO_LPD_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__ADMA_REF_CTRL__ACT_FREQMHZ {499.994995} \
   CONFIG.PSU__CRL_APB__ADMA_REF_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__ADMA_REF_CTRL__FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__ADMA_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__AFI6_REF_CTRL__ACT_FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__AFI6_REF_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__AFI6_REF_CTRL__FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__AFI6_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__AFI6__ENABLE {0} \
   CONFIG.PSU__CRL_APB__AMS_REF_CTRL__ACT_FREQMHZ {49.999500} \
   CONFIG.PSU__CRL_APB__AMS_REF_CTRL__DIVISOR0 {30} \
   CONFIG.PSU__CRL_APB__AMS_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__AMS_REF_CTRL__FREQMHZ {50} \
   CONFIG.PSU__CRL_APB__AMS_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__CAN0_REF_CTRL__ACT_FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__CAN0_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__CAN0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__CAN0_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__CAN0_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__CAN1_REF_CTRL__ACT_FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__CAN1_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__CAN1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__CAN1_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__CAN1_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__CPU_R5_CTRL__ACT_FREQMHZ {499.994995} \
   CONFIG.PSU__CRL_APB__CPU_R5_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__CPU_R5_CTRL__FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__CPU_R5_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__CSU_PLL_CTRL__ACT_FREQMHZ {180} \
   CONFIG.PSU__CRL_APB__CSU_PLL_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__CSU_PLL_CTRL__FREQMHZ {180} \
   CONFIG.PSU__CRL_APB__CSU_PLL_CTRL__SRCSEL {SysOsc} \
   CONFIG.PSU__CRL_APB__DBG_LPD_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRL_APB__DBG_LPD_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRL_APB__DBG_LPD_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRL_APB__DBG_LPD_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__DEBUG_R5_ATCLK_CTRL__ACT_FREQMHZ {1000} \
   CONFIG.PSU__CRL_APB__DEBUG_R5_ATCLK_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRL_APB__DEBUG_R5_ATCLK_CTRL__FREQMHZ {1000} \
   CONFIG.PSU__CRL_APB__DEBUG_R5_ATCLK_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__DLL_REF_CTRL__ACT_FREQMHZ {1499.984985} \
   CONFIG.PSU__CRL_APB__DLL_REF_CTRL__FREQMHZ {1500} \
   CONFIG.PSU__CRL_APB__DLL_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__GEM0_REF_CTRL__ACT_FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM0_REF_CTRL__DIVISOR0 {12} \
   CONFIG.PSU__CRL_APB__GEM0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__GEM0_REF_CTRL__FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM0_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__GEM1_REF_CTRL__ACT_FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM1_REF_CTRL__DIVISOR0 {12} \
   CONFIG.PSU__CRL_APB__GEM1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__GEM1_REF_CTRL__FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM1_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__GEM2_REF_CTRL__ACT_FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM2_REF_CTRL__DIVISOR0 {12} \
   CONFIG.PSU__CRL_APB__GEM2_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__GEM2_REF_CTRL__FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM2_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__GEM3_REF_CTRL__ACT_FREQMHZ {124.998749} \
   CONFIG.PSU__CRL_APB__GEM3_REF_CTRL__DIVISOR0 {12} \
   CONFIG.PSU__CRL_APB__GEM3_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__GEM3_REF_CTRL__FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__GEM3_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRL_APB__GEM_TSU_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__I2C0_REF_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__I2C0_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__I2C0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__I2C0_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__I2C0_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__I2C1_REF_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__I2C1_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__I2C1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__I2C1_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__I2C1_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__IOPLL_CTRL__DIV2 {1} \
   CONFIG.PSU__CRL_APB__IOPLL_CTRL__FBDIV {90} \
   CONFIG.PSU__CRL_APB__IOPLL_CTRL__FRACDATA {0.000000} \
   CONFIG.PSU__CRL_APB__IOPLL_CTRL__FRACFREQ {27.138} \
   CONFIG.PSU__CRL_APB__IOPLL_CTRL__SRCSEL {PSS_REF_CLK} \
   CONFIG.PSU__CRL_APB__IOPLL_FRAC_CFG__ENABLED {0} \
   CONFIG.PSU__CRL_APB__IOPLL_TO_FPD_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__IOU_SWITCH_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRL_APB__IOU_SWITCH_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRL_APB__IOU_SWITCH_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRL_APB__IOU_SWITCH_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__LPD_LSBUS_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__LPD_LSBUS_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__LPD_LSBUS_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__LPD_LSBUS_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__LPD_SWITCH_CTRL__ACT_FREQMHZ {499.994995} \
   CONFIG.PSU__CRL_APB__LPD_SWITCH_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__LPD_SWITCH_CTRL__FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__LPD_SWITCH_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__NAND_REF_CTRL__ACT_FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__NAND_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__NAND_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__NAND_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__NAND_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__OCM_MAIN_CTRL__ACT_FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__OCM_MAIN_CTRL__DIVISOR0 {3} \
   CONFIG.PSU__CRL_APB__OCM_MAIN_CTRL__FREQMHZ {500} \
   CONFIG.PSU__CRL_APB__OCM_MAIN_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__PCAP_CTRL__ACT_FREQMHZ {187.498123} \
   CONFIG.PSU__CRL_APB__PCAP_CTRL__DIVISOR0 {8} \
   CONFIG.PSU__CRL_APB__PCAP_CTRL__FREQMHZ {200} \
   CONFIG.PSU__CRL_APB__PCAP_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__PL1_REF_CTRL__ACT_FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL1_REF_CTRL__DIVISOR0 {4} \
   CONFIG.PSU__CRL_APB__PL1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL1_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__PL2_REF_CTRL__ACT_FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL2_REF_CTRL__DIVISOR0 {4} \
   CONFIG.PSU__CRL_APB__PL2_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL2_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__PL3_REF_CTRL__ACT_FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL3_REF_CTRL__DIVISOR0 {4} \
   CONFIG.PSU__CRL_APB__PL3_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__PL3_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__PL3_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__QSPI_REF_CTRL__ACT_FREQMHZ {124.998749} \
   CONFIG.PSU__CRL_APB__QSPI_REF_CTRL__DIVISOR0 {12} \
   CONFIG.PSU__CRL_APB__QSPI_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__QSPI_REF_CTRL__FREQMHZ {125} \
   CONFIG.PSU__CRL_APB__QSPI_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__RPLL_CTRL__DIV2 {1} \
   CONFIG.PSU__CRL_APB__RPLL_CTRL__FBDIV {45} \
   CONFIG.PSU__CRL_APB__RPLL_CTRL__FRACDATA {0.000000} \
   CONFIG.PSU__CRL_APB__RPLL_CTRL__FRACFREQ {27.138} \
   CONFIG.PSU__CRL_APB__RPLL_CTRL__SRCSEL {PSS_REF_CLK} \
   CONFIG.PSU__CRL_APB__RPLL_FRAC_CFG__ENABLED {0} \
   CONFIG.PSU__CRL_APB__RPLL_TO_FPD_CTRL__DIVISOR0 {2} \
   CONFIG.PSU__CRL_APB__SDIO0_REF_CTRL__ACT_FREQMHZ {200} \
   CONFIG.PSU__CRL_APB__SDIO0_REF_CTRL__DIVISOR0 {7} \
   CONFIG.PSU__CRL_APB__SDIO0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__SDIO0_REF_CTRL__FREQMHZ {200} \
   CONFIG.PSU__CRL_APB__SDIO0_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__SDIO1_REF_CTRL__ACT_FREQMHZ {187.498123} \
   CONFIG.PSU__CRL_APB__SDIO1_REF_CTRL__DIVISOR0 {8} \
   CONFIG.PSU__CRL_APB__SDIO1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__SDIO1_REF_CTRL__FREQMHZ {200} \
   CONFIG.PSU__CRL_APB__SDIO1_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__SPI0_REF_CTRL__ACT_FREQMHZ {214} \
   CONFIG.PSU__CRL_APB__SPI0_REF_CTRL__DIVISOR0 {7} \
   CONFIG.PSU__CRL_APB__SPI0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__SPI0_REF_CTRL__FREQMHZ {200} \
   CONFIG.PSU__CRL_APB__SPI0_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__SPI1_REF_CTRL__ACT_FREQMHZ {214} \
   CONFIG.PSU__CRL_APB__SPI1_REF_CTRL__DIVISOR0 {7} \
   CONFIG.PSU__CRL_APB__SPI1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__SPI1_REF_CTRL__FREQMHZ {200} \
   CONFIG.PSU__CRL_APB__SPI1_REF_CTRL__SRCSEL {RPLL} \
   CONFIG.PSU__CRL_APB__TIMESTAMP_REF_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__TIMESTAMP_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__TIMESTAMP_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__TIMESTAMP_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__UART0_REF_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__UART0_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__UART0_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__UART0_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__UART0_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__UART1_REF_CTRL__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__CRL_APB__UART1_REF_CTRL__DIVISOR0 {15} \
   CONFIG.PSU__CRL_APB__UART1_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__UART1_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__CRL_APB__UART1_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__USB0_BUS_REF_CTRL__ACT_FREQMHZ {249.997498} \
   CONFIG.PSU__CRL_APB__USB0_BUS_REF_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRL_APB__USB0_BUS_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__USB0_BUS_REF_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRL_APB__USB0_BUS_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__USB1_BUS_REF_CTRL__ACT_FREQMHZ {250} \
   CONFIG.PSU__CRL_APB__USB1_BUS_REF_CTRL__DIVISOR0 {6} \
   CONFIG.PSU__CRL_APB__USB1_BUS_REF_CTRL__DIVISOR1 {1} \
   CONFIG.PSU__CRL_APB__USB1_BUS_REF_CTRL__FREQMHZ {250} \
   CONFIG.PSU__CRL_APB__USB1_BUS_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__USB3_DUAL_REF_CTRL__ACT_FREQMHZ {19.999800} \
   CONFIG.PSU__CRL_APB__USB3_DUAL_REF_CTRL__DIVISOR0 {25} \
   CONFIG.PSU__CRL_APB__USB3_DUAL_REF_CTRL__DIVISOR1 {3} \
   CONFIG.PSU__CRL_APB__USB3_DUAL_REF_CTRL__FREQMHZ {20} \
   CONFIG.PSU__CRL_APB__USB3_DUAL_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__USB3__ENABLE {1} \
   CONFIG.PSU__CSUPMU__PERIPHERAL__VALID {1} \
   CONFIG.PSU__CSU_COHERENCY {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_0__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_0__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_10__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_10__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_11__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_11__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_12__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_12__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_1__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_1__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_2__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_2__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_3__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_3__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_4__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_4__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_5__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_5__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_6__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_6__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_7__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_7__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_8__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_8__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_9__ENABLE {0} \
   CONFIG.PSU__CSU__CSU_TAMPER_9__ERASE_BBRAM {0} \
   CONFIG.PSU__CSU__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__DDRC__ADDR_MIRROR {0} \
   CONFIG.PSU__DDRC__AL {0} \
   CONFIG.PSU__DDRC__BANK_ADDR_COUNT {2} \
   CONFIG.PSU__DDRC__BG_ADDR_COUNT {1} \
   CONFIG.PSU__DDRC__BRC_MAPPING {ROW_BANK_COL} \
   CONFIG.PSU__DDRC__BUS_WIDTH {64 Bit} \
   CONFIG.PSU__DDRC__CL {15} \
   CONFIG.PSU__DDRC__CLOCK_STOP_EN {0} \
   CONFIG.PSU__DDRC__COL_ADDR_COUNT {10} \
   CONFIG.PSU__DDRC__COMPONENTS {UDIMM} \
   CONFIG.PSU__DDRC__CWL {14} \
   CONFIG.PSU__DDRC__DDR3L_T_REF_RANGE {NA} \
   CONFIG.PSU__DDRC__DDR3_T_REF_RANGE {NA} \
   CONFIG.PSU__DDRC__DDR4_ADDR_MAPPING {0} \
   CONFIG.PSU__DDRC__DDR4_CAL_MODE_ENABLE {0} \
   CONFIG.PSU__DDRC__DDR4_CRC_CONTROL {0} \
   CONFIG.PSU__DDRC__DDR4_MAXPWR_SAVING_EN {0} \
   CONFIG.PSU__DDRC__DDR4_T_REF_MODE {0} \
   CONFIG.PSU__DDRC__DDR4_T_REF_RANGE {Normal (0-85)} \
   CONFIG.PSU__DDRC__DEEP_PWR_DOWN_EN {0} \
   CONFIG.PSU__DDRC__DEVICE_CAPACITY {8192 MBits} \
   CONFIG.PSU__DDRC__DIMM_ADDR_MIRROR {0} \
   CONFIG.PSU__DDRC__DM_DBI {DM_NO_DBI} \
   CONFIG.PSU__DDRC__DQMAP_0_3 {0} \
   CONFIG.PSU__DDRC__DQMAP_12_15 {0} \
   CONFIG.PSU__DDRC__DQMAP_16_19 {0} \
   CONFIG.PSU__DDRC__DQMAP_20_23 {0} \
   CONFIG.PSU__DDRC__DQMAP_24_27 {0} \
   CONFIG.PSU__DDRC__DQMAP_28_31 {0} \
   CONFIG.PSU__DDRC__DQMAP_32_35 {0} \
   CONFIG.PSU__DDRC__DQMAP_36_39 {0} \
   CONFIG.PSU__DDRC__DQMAP_40_43 {0} \
   CONFIG.PSU__DDRC__DQMAP_44_47 {0} \
   CONFIG.PSU__DDRC__DQMAP_48_51 {0} \
   CONFIG.PSU__DDRC__DQMAP_4_7 {0} \
   CONFIG.PSU__DDRC__DQMAP_52_55 {0} \
   CONFIG.PSU__DDRC__DQMAP_56_59 {0} \
   CONFIG.PSU__DDRC__DQMAP_60_63 {0} \
   CONFIG.PSU__DDRC__DQMAP_64_67 {0} \
   CONFIG.PSU__DDRC__DQMAP_68_71 {0} \
   CONFIG.PSU__DDRC__DQMAP_8_11 {0} \
   CONFIG.PSU__DDRC__DRAM_WIDTH {16 Bits} \
   CONFIG.PSU__DDRC__ECC {Disabled} \
   CONFIG.PSU__DDRC__ECC_SCRUB {0} \
   CONFIG.PSU__DDRC__ENABLE {1} \
   CONFIG.PSU__DDRC__ENABLE_2T_TIMING {0} \
   CONFIG.PSU__DDRC__ENABLE_DP_SWITCH {0} \
   CONFIG.PSU__DDRC__ENABLE_LP4_HAS_ECC_COMP {0} \
   CONFIG.PSU__DDRC__ENABLE_LP4_SLOWBOOT {0} \
   CONFIG.PSU__DDRC__EN_2ND_CLK {0} \
   CONFIG.PSU__DDRC__FGRM {1X} \
   CONFIG.PSU__DDRC__FREQ_MHZ {1} \
   CONFIG.PSU__DDRC__LPDDR3_DUALRANK_SDP {0} \
   CONFIG.PSU__DDRC__LPDDR3_T_REF_RANGE {NA} \
   CONFIG.PSU__DDRC__LPDDR4_T_REF_RANGE {NA} \
   CONFIG.PSU__DDRC__LP_ASR {manual normal} \
   CONFIG.PSU__DDRC__MEMORY_TYPE {DDR 4} \
   CONFIG.PSU__DDRC__PARITY_ENABLE {0} \
   CONFIG.PSU__DDRC__PER_BANK_REFRESH {0} \
   CONFIG.PSU__DDRC__PHY_DBI_MODE {0} \
   CONFIG.PSU__DDRC__PLL_BYPASS {0} \
   CONFIG.PSU__DDRC__PWR_DOWN_EN {0} \
   CONFIG.PSU__DDRC__RANK_ADDR_COUNT {0} \
   CONFIG.PSU__DDRC__RD_DQS_CENTER {0} \
   CONFIG.PSU__DDRC__ROW_ADDR_COUNT {16} \
   CONFIG.PSU__DDRC__SB_TARGET {15-15-15} \
   CONFIG.PSU__DDRC__SELF_REF_ABORT {0} \
   CONFIG.PSU__DDRC__SPEED_BIN {DDR4_2133P} \
   CONFIG.PSU__DDRC__STATIC_RD_MODE {0} \
   CONFIG.PSU__DDRC__TRAIN_DATA_EYE {1} \
   CONFIG.PSU__DDRC__TRAIN_READ_GATE {1} \
   CONFIG.PSU__DDRC__TRAIN_WRITE_LEVEL {1} \
   CONFIG.PSU__DDRC__T_FAW {30.0} \
   CONFIG.PSU__DDRC__T_RAS_MIN {33} \
   CONFIG.PSU__DDRC__T_RC {47.06} \
   CONFIG.PSU__DDRC__T_RCD {15} \
   CONFIG.PSU__DDRC__T_RP {15} \
   CONFIG.PSU__DDRC__VENDOR_PART {OTHERS} \
   CONFIG.PSU__DDRC__VIDEO_BUFFER_SIZE {0} \
   CONFIG.PSU__DDRC__VREF {1} \
   CONFIG.PSU__DDR_HIGH_ADDRESS_GUI_ENABLE {1} \
   CONFIG.PSU__DDR_QOS_ENABLE {0} \
   CONFIG.PSU__DDR_QOS_FIX_HP0_RDQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP0_WRQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP1_RDQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP1_WRQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP2_RDQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP2_WRQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP3_RDQOS {} \
   CONFIG.PSU__DDR_QOS_FIX_HP3_WRQOS {} \
   CONFIG.PSU__DDR_QOS_HP0_RDQOS {} \
   CONFIG.PSU__DDR_QOS_HP0_WRQOS {} \
   CONFIG.PSU__DDR_QOS_HP1_RDQOS {} \
   CONFIG.PSU__DDR_QOS_HP1_WRQOS {} \
   CONFIG.PSU__DDR_QOS_HP2_RDQOS {} \
   CONFIG.PSU__DDR_QOS_HP2_WRQOS {} \
   CONFIG.PSU__DDR_QOS_HP3_RDQOS {} \
   CONFIG.PSU__DDR_QOS_HP3_WRQOS {} \
   CONFIG.PSU__DDR_QOS_RD_HPR_THRSHLD {} \
   CONFIG.PSU__DDR_QOS_RD_LPR_THRSHLD {} \
   CONFIG.PSU__DDR_QOS_WR_THRSHLD {} \
   CONFIG.PSU__DDR_SW_REFRESH_ENABLED {1} \
   CONFIG.PSU__DDR__INTERFACE__FREQMHZ {533.500} \
   CONFIG.PSU__DEVICE_TYPE {RFSOC} \
   CONFIG.PSU__DISPLAYPORT__LANE0__ENABLE {1} \
   CONFIG.PSU__DISPLAYPORT__LANE0__IO {GT Lane1} \
   CONFIG.PSU__DISPLAYPORT__LANE1__ENABLE {1} \
   CONFIG.PSU__DISPLAYPORT__LANE1__IO {GT Lane0} \
   CONFIG.PSU__DISPLAYPORT__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__DLL__ISUSED {1} \
   CONFIG.PSU__DPAUX__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__DPAUX__PERIPHERAL__IO {MIO 27 .. 30} \
   CONFIG.PSU__DP__LANE_SEL {Dual Lower} \
   CONFIG.PSU__DP__REF_CLK_FREQ {27} \
   CONFIG.PSU__DP__REF_CLK_SEL {Ref Clk1} \
   CONFIG.PSU__ENABLE__DDR__REFRESH__SIGNALS {0} \
   CONFIG.PSU__ENET0__FIFO__ENABLE {0} \
   CONFIG.PSU__ENET0__GRP_MDIO__ENABLE {0} \
   CONFIG.PSU__ENET0__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__ENET0__PTP__ENABLE {0} \
   CONFIG.PSU__ENET0__TSU__ENABLE {0} \
   CONFIG.PSU__ENET1__FIFO__ENABLE {0} \
   CONFIG.PSU__ENET1__GRP_MDIO__ENABLE {0} \
   CONFIG.PSU__ENET1__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__ENET1__PTP__ENABLE {0} \
   CONFIG.PSU__ENET1__TSU__ENABLE {0} \
   CONFIG.PSU__ENET2__FIFO__ENABLE {0} \
   CONFIG.PSU__ENET2__GRP_MDIO__ENABLE {0} \
   CONFIG.PSU__ENET2__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__ENET2__PTP__ENABLE {0} \
   CONFIG.PSU__ENET2__TSU__ENABLE {0} \
   CONFIG.PSU__ENET3__FIFO__ENABLE {0} \
   CONFIG.PSU__ENET3__GRP_MDIO__ENABLE {1} \
   CONFIG.PSU__ENET3__GRP_MDIO__IO {MIO 76 .. 77} \
   CONFIG.PSU__ENET3__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__ENET3__PERIPHERAL__IO {MIO 64 .. 75} \
   CONFIG.PSU__ENET3__PTP__ENABLE {0} \
   CONFIG.PSU__ENET3__TSU__ENABLE {0} \
   CONFIG.PSU__EN_AXI_STATUS_PORTS {0} \
   CONFIG.PSU__EN_EMIO_TRACE {0} \
   CONFIG.PSU__EP__IP {0} \
   CONFIG.PSU__EXPAND__CORESIGHT {0} \
   CONFIG.PSU__EXPAND__FPD_SLAVES {0} \
   CONFIG.PSU__EXPAND__GIC {0} \
   CONFIG.PSU__EXPAND__LOWER_LPS_SLAVES {0} \
   CONFIG.PSU__EXPAND__UPPER_LPS_SLAVES {0} \
   CONFIG.PSU__FPDMASTERS_COHERENCY {0} \
   CONFIG.PSU__FPD_SLCR__WDT1__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__FPD_SLCR__WDT1__FREQMHZ {99.999001} \
   CONFIG.PSU__FPD_SLCR__WDT_CLK_SEL__SELECT {APB} \
   CONFIG.PSU__FPGA_PL0_ENABLE {1} \
   CONFIG.PSU__FPGA_PL1_ENABLE {0} \
   CONFIG.PSU__FPGA_PL2_ENABLE {0} \
   CONFIG.PSU__FPGA_PL3_ENABLE {0} \
   CONFIG.PSU__FP__POWER__ON {1} \
   CONFIG.PSU__FTM__CTI_IN_0 {0} \
   CONFIG.PSU__FTM__CTI_IN_1 {0} \
   CONFIG.PSU__FTM__CTI_IN_2 {0} \
   CONFIG.PSU__FTM__CTI_IN_3 {0} \
   CONFIG.PSU__FTM__CTI_OUT_0 {0} \
   CONFIG.PSU__FTM__CTI_OUT_1 {0} \
   CONFIG.PSU__FTM__CTI_OUT_2 {0} \
   CONFIG.PSU__FTM__CTI_OUT_3 {0} \
   CONFIG.PSU__FTM__GPI {0} \
   CONFIG.PSU__FTM__GPO {0} \
   CONFIG.PSU__GEM0_COHERENCY {0} \
   CONFIG.PSU__GEM0_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__GEM1_COHERENCY {0} \
   CONFIG.PSU__GEM1_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__GEM2_COHERENCY {0} \
   CONFIG.PSU__GEM2_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__GEM3_COHERENCY {0} \
   CONFIG.PSU__GEM3_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__GEM__TSU__ENABLE {0} \
   CONFIG.PSU__GEN_IPI_0__MASTER {APU} \
   CONFIG.PSU__GEN_IPI_10__MASTER {NONE} \
   CONFIG.PSU__GEN_IPI_1__MASTER {RPU0} \
   CONFIG.PSU__GEN_IPI_2__MASTER {RPU1} \
   CONFIG.PSU__GEN_IPI_3__MASTER {PMU} \
   CONFIG.PSU__GEN_IPI_4__MASTER {PMU} \
   CONFIG.PSU__GEN_IPI_5__MASTER {PMU} \
   CONFIG.PSU__GEN_IPI_6__MASTER {PMU} \
   CONFIG.PSU__GEN_IPI_7__MASTER {NONE} \
   CONFIG.PSU__GEN_IPI_8__MASTER {NONE} \
   CONFIG.PSU__GEN_IPI_9__MASTER {NONE} \
   CONFIG.PSU__GPIO0_MIO__IO {MIO 0 .. 25} \
   CONFIG.PSU__GPIO0_MIO__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__GPIO1_MIO__IO {MIO 26 .. 51} \
   CONFIG.PSU__GPIO1_MIO__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__GPIO2_MIO__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__GPIO_EMIO_WIDTH {1} \
   CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__GPIO_EMIO__PERIPHERAL__IO {<Select>} \
   CONFIG.PSU__GPIO_EMIO__WIDTH {[94:0]} \
   CONFIG.PSU__GPU_PP0__POWER__ON {0} \
   CONFIG.PSU__GPU_PP1__POWER__ON {0} \
   CONFIG.PSU__GT_REF_CLK__FREQMHZ {33.333} \
   CONFIG.PSU__GT__LINK_SPEED {HBR} \
   CONFIG.PSU__GT__PRE_EMPH_LVL_4 {0} \
   CONFIG.PSU__GT__VLT_SWNG_LVL_4 {0} \
   CONFIG.PSU__HIGH_ADDRESS__ENABLE {1} \
   CONFIG.PSU__HPM0_FPD__NUM_READ_THREADS {4} \
   CONFIG.PSU__HPM0_FPD__NUM_WRITE_THREADS {4} \
   CONFIG.PSU__HPM0_LPD__NUM_READ_THREADS {4} \
   CONFIG.PSU__HPM0_LPD__NUM_WRITE_THREADS {4} \
   CONFIG.PSU__HPM1_FPD__NUM_READ_THREADS {4} \
   CONFIG.PSU__HPM1_FPD__NUM_WRITE_THREADS {4} \
   CONFIG.PSU__I2C0_LOOP_I2C1__ENABLE {0} \
   CONFIG.PSU__I2C0__GRP_INT__ENABLE {0} \
   CONFIG.PSU__I2C0__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__I2C0__PERIPHERAL__IO {MIO 14 .. 15} \
   CONFIG.PSU__I2C1__GRP_INT__ENABLE {0} \
   CONFIG.PSU__I2C1__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__I2C1__PERIPHERAL__IO {MIO 16 .. 17} \
   CONFIG.PSU__IOU_SLCR__IOU_TTC_APB_CLK__TTC0_SEL {APB} \
   CONFIG.PSU__IOU_SLCR__IOU_TTC_APB_CLK__TTC1_SEL {APB} \
   CONFIG.PSU__IOU_SLCR__IOU_TTC_APB_CLK__TTC2_SEL {APB} \
   CONFIG.PSU__IOU_SLCR__IOU_TTC_APB_CLK__TTC3_SEL {APB} \
   CONFIG.PSU__IOU_SLCR__TTC0__ACT_FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC0__FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC1__ACT_FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC1__FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC2__ACT_FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC2__FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC3__ACT_FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__TTC3__FREQMHZ {100.000000} \
   CONFIG.PSU__IOU_SLCR__WDT0__ACT_FREQMHZ {99.999001} \
   CONFIG.PSU__IOU_SLCR__WDT0__FREQMHZ {99.999001} \
   CONFIG.PSU__IOU_SLCR__WDT_CLK_SEL__SELECT {APB} \
   CONFIG.PSU__IRQ_P2F_ADMA_CHAN__INT {0} \
   CONFIG.PSU__IRQ_P2F_AIB_AXI__INT {0} \
   CONFIG.PSU__IRQ_P2F_AMS__INT {0} \
   CONFIG.PSU__IRQ_P2F_APM_FPD__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_COMM__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_CPUMNT__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_CTI__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_EXTERR__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_IPI__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_L2ERR__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_PMU__INT {0} \
   CONFIG.PSU__IRQ_P2F_APU_REGS__INT {0} \
   CONFIG.PSU__IRQ_P2F_ATB_LPD__INT {0} \
   CONFIG.PSU__IRQ_P2F_CAN0__INT {0} \
   CONFIG.PSU__IRQ_P2F_CAN1__INT {0} \
   CONFIG.PSU__IRQ_P2F_CLKMON__INT {0} \
   CONFIG.PSU__IRQ_P2F_CSUPMU_WDT__INT {0} \
   CONFIG.PSU__IRQ_P2F_CSU_DMA__INT {0} \
   CONFIG.PSU__IRQ_P2F_CSU__INT {0} \
   CONFIG.PSU__IRQ_P2F_DDR_SS__INT {0} \
   CONFIG.PSU__IRQ_P2F_DPDMA__INT {0} \
   CONFIG.PSU__IRQ_P2F_DPORT__INT {0} \
   CONFIG.PSU__IRQ_P2F_EFUSE__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT0_WAKEUP__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT0__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT1_WAKEUP__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT1__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT2_WAKEUP__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT2__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT3_WAKEUP__INT {0} \
   CONFIG.PSU__IRQ_P2F_ENT3__INT {0} \
   CONFIG.PSU__IRQ_P2F_FPD_APB__INT {0} \
   CONFIG.PSU__IRQ_P2F_FPD_ATB_ERR__INT {0} \
   CONFIG.PSU__IRQ_P2F_FP_WDT__INT {0} \
   CONFIG.PSU__IRQ_P2F_GDMA_CHAN__INT {0} \
   CONFIG.PSU__IRQ_P2F_GPIO__INT {0} \
   CONFIG.PSU__IRQ_P2F_GPU__INT {0} \
   CONFIG.PSU__IRQ_P2F_I2C0__INT {0} \
   CONFIG.PSU__IRQ_P2F_I2C1__INT {0} \
   CONFIG.PSU__IRQ_P2F_LPD_APB__INT {0} \
   CONFIG.PSU__IRQ_P2F_LPD_APM__INT {0} \
   CONFIG.PSU__IRQ_P2F_LP_WDT__INT {0} \
   CONFIG.PSU__IRQ_P2F_NAND__INT {0} \
   CONFIG.PSU__IRQ_P2F_OCM_ERR__INT {0} \
   CONFIG.PSU__IRQ_P2F_PCIE_DMA__INT {0} \
   CONFIG.PSU__IRQ_P2F_PCIE_LEGACY__INT {0} \
   CONFIG.PSU__IRQ_P2F_PCIE_MSC__INT {0} \
   CONFIG.PSU__IRQ_P2F_PCIE_MSI__INT {0} \
   CONFIG.PSU__IRQ_P2F_PL_IPI__INT {0} \
   CONFIG.PSU__IRQ_P2F_QSPI__INT {0} \
   CONFIG.PSU__IRQ_P2F_R5_CORE0_ECC_ERR__INT {0} \
   CONFIG.PSU__IRQ_P2F_R5_CORE1_ECC_ERR__INT {0} \
   CONFIG.PSU__IRQ_P2F_RPU_IPI__INT {0} \
   CONFIG.PSU__IRQ_P2F_RPU_PERMON__INT {0} \
   CONFIG.PSU__IRQ_P2F_RTC_ALARM__INT {0} \
   CONFIG.PSU__IRQ_P2F_RTC_SECONDS__INT {0} \
   CONFIG.PSU__IRQ_P2F_SATA__INT {0} \
   CONFIG.PSU__IRQ_P2F_SDIO0_WAKE__INT {0} \
   CONFIG.PSU__IRQ_P2F_SDIO0__INT {0} \
   CONFIG.PSU__IRQ_P2F_SDIO1_WAKE__INT {0} \
   CONFIG.PSU__IRQ_P2F_SDIO1__INT {0} \
   CONFIG.PSU__IRQ_P2F_SPI0__INT {0} \
   CONFIG.PSU__IRQ_P2F_SPI1__INT {0} \
   CONFIG.PSU__IRQ_P2F_TTC0__INT0 {0} \
   CONFIG.PSU__IRQ_P2F_TTC0__INT1 {0} \
   CONFIG.PSU__IRQ_P2F_TTC0__INT2 {0} \
   CONFIG.PSU__IRQ_P2F_TTC1__INT0 {0} \
   CONFIG.PSU__IRQ_P2F_TTC1__INT1 {0} \
   CONFIG.PSU__IRQ_P2F_TTC1__INT2 {0} \
   CONFIG.PSU__IRQ_P2F_TTC2__INT0 {0} \
   CONFIG.PSU__IRQ_P2F_TTC2__INT1 {0} \
   CONFIG.PSU__IRQ_P2F_TTC2__INT2 {0} \
   CONFIG.PSU__IRQ_P2F_TTC3__INT0 {0} \
   CONFIG.PSU__IRQ_P2F_TTC3__INT1 {0} \
   CONFIG.PSU__IRQ_P2F_TTC3__INT2 {0} \
   CONFIG.PSU__IRQ_P2F_UART0__INT {0} \
   CONFIG.PSU__IRQ_P2F_UART1__INT {0} \
   CONFIG.PSU__IRQ_P2F_USB3_ENDPOINT__INT0 {0} \
   CONFIG.PSU__IRQ_P2F_USB3_ENDPOINT__INT1 {0} \
   CONFIG.PSU__IRQ_P2F_USB3_OTG__INT0 {0} \
   CONFIG.PSU__IRQ_P2F_USB3_OTG__INT1 {0} \
   CONFIG.PSU__IRQ_P2F_USB3_PMU_WAKEUP__INT {0} \
   CONFIG.PSU__IRQ_P2F_XMPU_FPD__INT {0} \
   CONFIG.PSU__IRQ_P2F_XMPU_LPD__INT {0} \
   CONFIG.PSU__IRQ_P2F__INTF_FPD_SMMU__INT {0} \
   CONFIG.PSU__IRQ_P2F__INTF_PPD_CCI__INT {0} \
   CONFIG.PSU__L2_BANK0__POWER__ON {1} \
   CONFIG.PSU__LPDMA0_COHERENCY {0} \
   CONFIG.PSU__LPDMA1_COHERENCY {0} \
   CONFIG.PSU__LPDMA2_COHERENCY {0} \
   CONFIG.PSU__LPDMA3_COHERENCY {0} \
   CONFIG.PSU__LPDMA4_COHERENCY {0} \
   CONFIG.PSU__LPDMA5_COHERENCY {0} \
   CONFIG.PSU__LPDMA6_COHERENCY {0} \
   CONFIG.PSU__LPDMA7_COHERENCY {0} \
   CONFIG.PSU__LPD_SLCR__CSUPMU_WDT_CLK_SEL__SELECT {APB} \
   CONFIG.PSU__LPD_SLCR__CSUPMU__ACT_FREQMHZ {100.000000} \
   CONFIG.PSU__LPD_SLCR__CSUPMU__FREQMHZ {100.000000} \
   CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
   CONFIG.PSU__MAXIGP1__DATA_WIDTH {128} \
   CONFIG.PSU__MAXIGP2__DATA_WIDTH {128} \
   CONFIG.PSU__M_AXI_GP0_SUPPORTS_NARROW_BURST {1} \
   CONFIG.PSU__M_AXI_GP1_SUPPORTS_NARROW_BURST {1} \
   CONFIG.PSU__M_AXI_GP2_SUPPORTS_NARROW_BURST {1} \
   CONFIG.PSU__NAND_COHERENCY {0} \
   CONFIG.PSU__NAND_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__NAND__CHIP_ENABLE__ENABLE {0} \
   CONFIG.PSU__NAND__DATA_STROBE__ENABLE {0} \
   CONFIG.PSU__NAND__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__NAND__READY0_BUSY__ENABLE {0} \
   CONFIG.PSU__NAND__READY1_BUSY__ENABLE {0} \
   CONFIG.PSU__NAND__READY_BUSY__ENABLE {0} \
   CONFIG.PSU__NUM_FABRIC_RESETS {1} \
   CONFIG.PSU__OCM_BANK0__POWER__ON {1} \
   CONFIG.PSU__OCM_BANK1__POWER__ON {1} \
   CONFIG.PSU__OCM_BANK2__POWER__ON {1} \
   CONFIG.PSU__OCM_BANK3__POWER__ON {1} \
   CONFIG.PSU__OVERRIDE_HPX_QOS {0} \
   CONFIG.PSU__OVERRIDE__BASIC_CLOCK {0} \
   CONFIG.PSU__PCIE__ACS_VIOLAION {0} \
   CONFIG.PSU__PCIE__ACS_VIOLATION {0} \
   CONFIG.PSU__PCIE__AER_CAPABILITY {0} \
   CONFIG.PSU__PCIE__ATOMICOP_EGRESS_BLOCKED {0} \
   CONFIG.PSU__PCIE__BAR0_64BIT {0} \
   CONFIG.PSU__PCIE__BAR0_ENABLE {0} \
   CONFIG.PSU__PCIE__BAR0_PREFETCHABLE {0} \
   CONFIG.PSU__PCIE__BAR0_VAL {} \
   CONFIG.PSU__PCIE__BAR1_64BIT {0} \
   CONFIG.PSU__PCIE__BAR1_ENABLE {0} \
   CONFIG.PSU__PCIE__BAR1_PREFETCHABLE {0} \
   CONFIG.PSU__PCIE__BAR1_VAL {} \
   CONFIG.PSU__PCIE__BAR2_64BIT {0} \
   CONFIG.PSU__PCIE__BAR2_ENABLE {0} \
   CONFIG.PSU__PCIE__BAR2_PREFETCHABLE {0} \
   CONFIG.PSU__PCIE__BAR2_VAL {} \
   CONFIG.PSU__PCIE__BAR3_64BIT {0} \
   CONFIG.PSU__PCIE__BAR3_ENABLE {0} \
   CONFIG.PSU__PCIE__BAR3_PREFETCHABLE {0} \
   CONFIG.PSU__PCIE__BAR3_VAL {} \
   CONFIG.PSU__PCIE__BAR4_64BIT {0} \
   CONFIG.PSU__PCIE__BAR4_ENABLE {0} \
   CONFIG.PSU__PCIE__BAR4_PREFETCHABLE {0} \
   CONFIG.PSU__PCIE__BAR4_VAL {} \
   CONFIG.PSU__PCIE__BAR5_64BIT {0} \
   CONFIG.PSU__PCIE__BAR5_ENABLE {0} \
   CONFIG.PSU__PCIE__BAR5_PREFETCHABLE {0} \
   CONFIG.PSU__PCIE__BAR5_VAL {} \
   CONFIG.PSU__PCIE__CLASS_CODE_BASE {} \
   CONFIG.PSU__PCIE__CLASS_CODE_INTERFACE {} \
   CONFIG.PSU__PCIE__CLASS_CODE_SUB {} \
   CONFIG.PSU__PCIE__CLASS_CODE_VALUE {} \
   CONFIG.PSU__PCIE__COMPLETER_ABORT {0} \
   CONFIG.PSU__PCIE__COMPLTION_TIMEOUT {0} \
   CONFIG.PSU__PCIE__CORRECTABLE_INT_ERR {0} \
   CONFIG.PSU__PCIE__CRS_SW_VISIBILITY {0} \
   CONFIG.PSU__PCIE__DEVICE_ID {} \
   CONFIG.PSU__PCIE__ECRC_CHECK {0} \
   CONFIG.PSU__PCIE__ECRC_ERR {0} \
   CONFIG.PSU__PCIE__ECRC_GEN {0} \
   CONFIG.PSU__PCIE__EROM_ENABLE {0} \
   CONFIG.PSU__PCIE__EROM_VAL {} \
   CONFIG.PSU__PCIE__FLOW_CONTROL_ERR {0} \
   CONFIG.PSU__PCIE__FLOW_CONTROL_PROTOCOL_ERR {0} \
   CONFIG.PSU__PCIE__HEADER_LOG_OVERFLOW {0} \
   CONFIG.PSU__PCIE__INTX_GENERATION {0} \
   CONFIG.PSU__PCIE__LANE0__ENABLE {0} \
   CONFIG.PSU__PCIE__LANE1__ENABLE {0} \
   CONFIG.PSU__PCIE__LANE2__ENABLE {0} \
   CONFIG.PSU__PCIE__LANE3__ENABLE {0} \
   CONFIG.PSU__PCIE__MC_BLOCKED_TLP {0} \
   CONFIG.PSU__PCIE__MSIX_BAR_INDICATOR {} \
   CONFIG.PSU__PCIE__MSIX_CAPABILITY {0} \
   CONFIG.PSU__PCIE__MSIX_PBA_BAR_INDICATOR {} \
   CONFIG.PSU__PCIE__MSIX_PBA_OFFSET {0} \
   CONFIG.PSU__PCIE__MSIX_TABLE_OFFSET {0} \
   CONFIG.PSU__PCIE__MSIX_TABLE_SIZE {0} \
   CONFIG.PSU__PCIE__MSI_64BIT_ADDR_CAPABLE {0} \
   CONFIG.PSU__PCIE__MSI_CAPABILITY {0} \
   CONFIG.PSU__PCIE__MULTIHEADER {0} \
   CONFIG.PSU__PCIE__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__PCIE__PERIPHERAL__ENDPOINT_ENABLE {1} \
   CONFIG.PSU__PCIE__PERIPHERAL__ROOTPORT_ENABLE {0} \
   CONFIG.PSU__PCIE__PERM_ROOT_ERR_UPDATE {0} \
   CONFIG.PSU__PCIE__RECEIVER_ERR {0} \
   CONFIG.PSU__PCIE__RECEIVER_OVERFLOW {0} \
   CONFIG.PSU__PCIE__RESET__POLARITY {Active Low} \
   CONFIG.PSU__PCIE__REVISION_ID {} \
   CONFIG.PSU__PCIE__SUBSYSTEM_ID {} \
   CONFIG.PSU__PCIE__SUBSYSTEM_VENDOR_ID {} \
   CONFIG.PSU__PCIE__SURPRISE_DOWN {0} \
   CONFIG.PSU__PCIE__TLP_PREFIX_BLOCKED {0} \
   CONFIG.PSU__PCIE__UNCORRECTABL_INT_ERR {0} \
   CONFIG.PSU__PCIE__VENDOR_ID {} \
   CONFIG.PSU__PJTAG__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__PL_CLK0_BUF {TRUE} \
   CONFIG.PSU__PL_CLK1_BUF {FALSE} \
   CONFIG.PSU__PL_CLK2_BUF {FALSE} \
   CONFIG.PSU__PL_CLK3_BUF {FALSE} \
   CONFIG.PSU__PL__POWER__ON {1} \
   CONFIG.PSU__PMU_COHERENCY {0} \
   CONFIG.PSU__PMU__AIBACK__ENABLE {0} \
   CONFIG.PSU__PMU__EMIO_GPI__ENABLE {0} \
   CONFIG.PSU__PMU__EMIO_GPO__ENABLE {0} \
   CONFIG.PSU__PMU__GPI0__ENABLE {0} \
   CONFIG.PSU__PMU__GPI1__ENABLE {0} \
   CONFIG.PSU__PMU__GPI2__ENABLE {0} \
   CONFIG.PSU__PMU__GPI3__ENABLE {0} \
   CONFIG.PSU__PMU__GPI4__ENABLE {0} \
   CONFIG.PSU__PMU__GPI5__ENABLE {0} \
   CONFIG.PSU__PMU__GPO0__ENABLE {1} \
   CONFIG.PSU__PMU__GPO0__IO {MIO 32} \
   CONFIG.PSU__PMU__GPO1__ENABLE {1} \
   CONFIG.PSU__PMU__GPO1__IO {MIO 33} \
   CONFIG.PSU__PMU__GPO2__ENABLE {1} \
   CONFIG.PSU__PMU__GPO2__IO {MIO 34} \
   CONFIG.PSU__PMU__GPO2__POLARITY {low} \
   CONFIG.PSU__PMU__GPO3__ENABLE {1} \
   CONFIG.PSU__PMU__GPO3__IO {MIO 35} \
   CONFIG.PSU__PMU__GPO3__POLARITY {low} \
   CONFIG.PSU__PMU__GPO4__ENABLE {1} \
   CONFIG.PSU__PMU__GPO4__IO {MIO 36} \
   CONFIG.PSU__PMU__GPO4__POLARITY {low} \
   CONFIG.PSU__PMU__GPO5__ENABLE {1} \
   CONFIG.PSU__PMU__GPO5__IO {MIO 37} \
   CONFIG.PSU__PMU__GPO5__POLARITY {low} \
   CONFIG.PSU__PMU__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__PMU__PLERROR__ENABLE {0} \
   CONFIG.PSU__PRESET_APPLIED {1} \
   CONFIG.PSU__PROTECTION__DDR_SEGMENTS {NONE} \
   CONFIG.PSU__PROTECTION__DEBUG {0} \
   CONFIG.PSU__PROTECTION__ENABLE {0} \
   CONFIG.PSU__PROTECTION__FPD_SEGMENTS {SA:0xFD1A0000; SIZE:1280; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware         |          SA:0xFD000000; SIZE:64; UNIT:KB;\
RegionTZ:Secure; WrAllowed:Read/Write; subsystemId:PMU Firmware         |      \
SA:0xFD010000; SIZE:64; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware         |          SA:0xFD020000; SIZE:64; UNIT:KB;\
RegionTZ:Secure; WrAllowed:Read/Write; subsystemId:PMU Firmware         |      \
SA:0xFD030000; SIZE:64; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware         |          SA:0xFD040000; SIZE:64; UNIT:KB;\
RegionTZ:Secure; WrAllowed:Read/Write; subsystemId:PMU Firmware         |      \
SA:0xFD050000; SIZE:64; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware         |          SA:0xFD610000; SIZE:512; UNIT:KB;\
RegionTZ:Secure; WrAllowed:Read/Write; subsystemId:PMU Firmware         |      \
SA:0xFD5D0000; SIZE:64; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware         |         SA:0xFD1A0000 ; SIZE:1280; UNIT:KB;\
RegionTZ:Secure ; WrAllowed:Read/Write; subsystemId:Secure Subsystem}\
   CONFIG.PSU__PROTECTION__LOCK_UNUSED_SEGMENTS {0} \
   CONFIG.PSU__PROTECTION__LPD_SEGMENTS {SA:0xFF980000; SIZE:64; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware| SA:0xFF5E0000; SIZE:2560; UNIT:KB; RegionTZ:Secure;\
WrAllowed:Read/Write; subsystemId:PMU Firmware| SA:0xFFCC0000; SIZE:64;\
UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write; subsystemId:PMU Firmware|\
SA:0xFF180000; SIZE:768; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware| SA:0xFF410000; SIZE:640; UNIT:KB; RegionTZ:Secure;\
WrAllowed:Read/Write; subsystemId:PMU Firmware| SA:0xFFA70000; SIZE:64;\
UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write; subsystemId:PMU Firmware|\
SA:0xFF9A0000; SIZE:64; UNIT:KB; RegionTZ:Secure; WrAllowed:Read/Write;\
subsystemId:PMU Firmware|SA:0xFF5E0000 ; SIZE:2560; UNIT:KB; RegionTZ:Secure ;\
WrAllowed:Read/Write; subsystemId:Secure Subsystem|SA:0xFFCC0000 ; SIZE:64;\
UNIT:KB; RegionTZ:Secure ; WrAllowed:Read/Write; subsystemId:Secure\
Subsystem|SA:0xFF180000 ; SIZE:768; UNIT:KB; RegionTZ:Secure ;\
WrAllowed:Read/Write; subsystemId:Secure Subsystem|SA:0xFF9A0000 ; SIZE:64;\
UNIT:KB; RegionTZ:Secure ; WrAllowed:Read/Write; subsystemId:Secure Subsystem}\
   CONFIG.PSU__PROTECTION__MASTERS {USB1:NonSecure;0|USB0:NonSecure;1|S_AXI_LPD:NA;0|S_AXI_HPC1_FPD:NA;0|S_AXI_HPC0_FPD:NA;0|S_AXI_HP3_FPD:NA;0|S_AXI_HP2_FPD:NA;0|S_AXI_HP1_FPD:NA;0|S_AXI_HP0_FPD:NA;1|S_AXI_ACP:NA;0|S_AXI_ACE:NA;0|SD1:NonSecure;1|SD0:NonSecure;0|SATA1:NonSecure;1|SATA0:NonSecure;1|RPU1:Secure;1|RPU0:Secure;1|QSPI:NonSecure;1|PMU:NA;1|PCIe:NonSecure;0|NAND:NonSecure;0|LDMA:NonSecure;1|GPU:NonSecure;1|GEM3:NonSecure;1|GEM2:NonSecure;0|GEM1:NonSecure;0|GEM0:NonSecure;0|FDMA:NonSecure;1|DP:NonSecure;1|DAP:NA;1|Coresight:NA;1|CSU:NA;1|APU:NA;1}\
   CONFIG.PSU__PROTECTION__MASTERS_TZ {GEM0:NonSecure|SD1:NonSecure|GEM2:NonSecure|GEM1:NonSecure|GEM3:NonSecure|PCIe:NonSecure|DP:NonSecure|NAND:NonSecure|GPU:NonSecure|USB1:NonSecure|USB0:NonSecure|LDMA:NonSecure|FDMA:NonSecure|QSPI:NonSecure|SD0:NonSecure}\
   CONFIG.PSU__PROTECTION__OCM_SEGMENTS {NONE} \
   CONFIG.PSU__PROTECTION__PRESUBSYSTEMS {NONE} \
   CONFIG.PSU__PROTECTION__SLAVES {LPD;USB3_1_XHCI;FE300000;FE3FFFFF;0|LPD;USB3_1;FF9E0000;FF9EFFFF;0|LPD;USB3_0_XHCI;FE200000;FE2FFFFF;1|LPD;USB3_0;FF9D0000;FF9DFFFF;1|LPD;UART1;FF010000;FF01FFFF;0|LPD;UART0;FF000000;FF00FFFF;1|LPD;TTC3;FF140000;FF14FFFF;1|LPD;TTC2;FF130000;FF13FFFF;1|LPD;TTC1;FF120000;FF12FFFF;1|LPD;TTC0;FF110000;FF11FFFF;1|FPD;SWDT1;FD4D0000;FD4DFFFF;1|LPD;SWDT0;FF150000;FF15FFFF;1|LPD;SPI1;FF050000;FF05FFFF;0|LPD;SPI0;FF040000;FF04FFFF;0|FPD;SMMU_REG;FD5F0000;FD5FFFFF;1|FPD;SMMU;FD800000;FDFFFFFF;1|FPD;SIOU;FD3D0000;FD3DFFFF;1|FPD;SERDES;FD400000;FD47FFFF;1|LPD;SD1;FF170000;FF17FFFF;1|LPD;SD0;FF160000;FF16FFFF;0|FPD;SATA;FD0C0000;FD0CFFFF;1|LPD;RTC;FFA60000;FFA6FFFF;1|LPD;RSA_CORE;FFCE0000;FFCEFFFF;1|LPD;RPU;FF9A0000;FF9AFFFF;1|LPD;R5_TCM_RAM_GLOBAL;FFE00000;FFE3FFFF;1|LPD;R5_1_Instruction_Cache;FFEC0000;FFECFFFF;1|LPD;R5_1_Data_Cache;FFED0000;FFEDFFFF;1|LPD;R5_1_BTCM_GLOBAL;FFEB0000;FFEBFFFF;1|LPD;R5_1_ATCM_GLOBAL;FFE90000;FFE9FFFF;1|LPD;R5_0_Instruction_Cache;FFE40000;FFE4FFFF;1|LPD;R5_0_Data_Cache;FFE50000;FFE5FFFF;1|LPD;R5_0_BTCM_GLOBAL;FFE20000;FFE2FFFF;1|LPD;R5_0_ATCM_GLOBAL;FFE00000;FFE0FFFF;1|LPD;QSPI_Linear_Address;C0000000;DFFFFFFF;1|LPD;QSPI;FF0F0000;FF0FFFFF;1|LPD;PMU_RAM;FFDC0000;FFDDFFFF;1|LPD;PMU_GLOBAL;FFD80000;FFDBFFFF;1|FPD;PCIE_MAIN;FD0E0000;FD0EFFFF;0|FPD;PCIE_LOW;E0000000;EFFFFFFF;0|FPD;PCIE_HIGH2;8000000000;BFFFFFFFFF;0|FPD;PCIE_HIGH1;600000000;7FFFFFFFF;0|FPD;PCIE_DMA;FD0F0000;FD0FFFFF;0|FPD;PCIE_ATTRIB;FD480000;FD48FFFF;0|LPD;OCM_XMPU_CFG;FFA70000;FFA7FFFF;1|LPD;OCM_SLCR;FF960000;FF96FFFF;1|OCM;OCM;FFFC0000;FFFFFFFF;1|LPD;NAND;FF100000;FF10FFFF;0|LPD;MBISTJTAG;FFCF0000;FFCFFFFF;1|LPD;LPD_XPPU_SINK;FF9C0000;FF9CFFFF;1|LPD;LPD_XPPU;FF980000;FF98FFFF;1|LPD;LPD_SLCR_SECURE;FF4B0000;FF4DFFFF;1|LPD;LPD_SLCR;FF410000;FF4AFFFF;1|LPD;LPD_GPV;FE100000;FE1FFFFF;1|LPD;LPD_DMA_7;FFAF0000;FFAFFFFF;1|LPD;LPD_DMA_6;FFAE0000;FFAEFFFF;1|LPD;LPD_DMA_5;FFAD0000;FFADFFFF;1|LPD;LPD_DMA_4;FFAC0000;FFACFFFF;1|LPD;LPD_DMA_3;FFAB0000;FFABFFFF;1|LPD;LPD_DMA_2;FFAA0000;FFAAFFFF;1|LPD;LPD_DMA_1;FFA90000;FFA9FFFF;1|LPD;LPD_DMA_0;FFA80000;FFA8FFFF;1|LPD;IPI_CTRL;FF380000;FF3FFFFF;1|LPD;IOU_SLCR;FF180000;FF23FFFF;1|LPD;IOU_SECURE_SLCR;FF240000;FF24FFFF;1|LPD;IOU_SCNTRS;FF260000;FF26FFFF;1|LPD;IOU_SCNTR;FF250000;FF25FFFF;1|LPD;IOU_GPV;FE000000;FE0FFFFF;1|LPD;I2C1;FF030000;FF03FFFF;1|LPD;I2C0;FF020000;FF02FFFF;1|FPD;GPU;FD4B0000;FD4BFFFF;0|LPD;GPIO;FF0A0000;FF0AFFFF;1|LPD;GEM3;FF0E0000;FF0EFFFF;1|LPD;GEM2;FF0D0000;FF0DFFFF;0|LPD;GEM1;FF0C0000;FF0CFFFF;0|LPD;GEM0;FF0B0000;FF0BFFFF;0|FPD;FPD_XMPU_SINK;FD4F0000;FD4FFFFF;1|FPD;FPD_XMPU_CFG;FD5D0000;FD5DFFFF;1|FPD;FPD_SLCR_SECURE;FD690000;FD6CFFFF;1|FPD;FPD_SLCR;FD610000;FD68FFFF;1|FPD;FPD_DMA_CH7;FD570000;FD57FFFF;1|FPD;FPD_DMA_CH6;FD560000;FD56FFFF;1|FPD;FPD_DMA_CH5;FD550000;FD55FFFF;1|FPD;FPD_DMA_CH4;FD540000;FD54FFFF;1|FPD;FPD_DMA_CH3;FD530000;FD53FFFF;1|FPD;FPD_DMA_CH2;FD520000;FD52FFFF;1|FPD;FPD_DMA_CH1;FD510000;FD51FFFF;1|FPD;FPD_DMA_CH0;FD500000;FD50FFFF;1|LPD;EFUSE;FFCC0000;FFCCFFFF;1|FPD;Display\
Port;FD4A0000;FD4AFFFF;1|FPD;DPDMA;FD4C0000;FD4CFFFF;1|FPD;DDR_XMPU5_CFG;FD050000;FD05FFFF;1|FPD;DDR_XMPU4_CFG;FD040000;FD04FFFF;1|FPD;DDR_XMPU3_CFG;FD030000;FD03FFFF;1|FPD;DDR_XMPU2_CFG;FD020000;FD02FFFF;1|FPD;DDR_XMPU1_CFG;FD010000;FD01FFFF;1|FPD;DDR_XMPU0_CFG;FD000000;FD00FFFF;1|FPD;DDR_QOS_CTRL;FD090000;FD09FFFF;1|FPD;DDR_PHY;FD080000;FD08FFFF;1|DDR;DDR_LOW;0;7FFFFFFF;1|DDR;DDR_HIGH;800000000;87FFFFFFF;1|FPD;DDDR_CTRL;FD070000;FD070FFF;1|LPD;Coresight;FE800000;FEFFFFFF;1|LPD;CSU_DMA;FFC80000;FFC9FFFF;1|LPD;CSU;FFCA0000;FFCAFFFF;1|LPD;CRL_APB;FF5E0000;FF85FFFF;1|FPD;CRF_APB;FD1A0000;FD2DFFFF;1|FPD;CCI_REG;FD5E0000;FD5EFFFF;1|LPD;CAN1;FF070000;FF07FFFF;0|LPD;CAN0;FF060000;FF06FFFF;0|FPD;APU;FD5C0000;FD5CFFFF;1|LPD;APM_INTC_IOU;FFA20000;FFA2FFFF;1|LPD;APM_FPD_LPD;FFA30000;FFA3FFFF;1|FPD;APM_5;FD490000;FD49FFFF;1|FPD;APM_0;FD0B0000;FD0BFFFF;1|LPD;APM2;FFA10000;FFA1FFFF;1|LPD;APM1;FFA00000;FFA0FFFF;1|LPD;AMS;FFA50000;FFA5FFFF;1|FPD;AFI_5;FD3B0000;FD3BFFFF;1|FPD;AFI_4;FD3A0000;FD3AFFFF;1|FPD;AFI_3;FD390000;FD39FFFF;1|FPD;AFI_2;FD380000;FD38FFFF;1|FPD;AFI_1;FD370000;FD37FFFF;1|FPD;AFI_0;FD360000;FD36FFFF;1|LPD;AFIFM6;FF9B0000;FF9BFFFF;1|FPD;ACPU_GIC;F9010000;F907FFFF;1}\
   CONFIG.PSU__PROTECTION__SUBSYSTEMS {PMU Firmware:PMU|Secure Subsystem:} \
   CONFIG.PSU__PSS_ALT_REF_CLK__ENABLE {0} \
   CONFIG.PSU__PSS_ALT_REF_CLK__FREQMHZ {33.333} \
   CONFIG.PSU__PSS_REF_CLK__FREQMHZ {33.333} \
   CONFIG.PSU__QSPI_COHERENCY {0} \
   CONFIG.PSU__QSPI_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__QSPI__GRP_FBCLK__ENABLE {1} \
   CONFIG.PSU__QSPI__GRP_FBCLK__IO {MIO 6} \
   CONFIG.PSU__QSPI__PERIPHERAL__DATA_MODE {x4} \
   CONFIG.PSU__QSPI__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__QSPI__PERIPHERAL__IO {MIO 0 .. 12} \
   CONFIG.PSU__QSPI__PERIPHERAL__MODE {Dual Parallel} \
   CONFIG.PSU__REPORT__DBGLOG {0} \
   CONFIG.PSU__RPU_COHERENCY {0} \
   CONFIG.PSU__RPU__POWER__ON {1} \
   CONFIG.PSU__SATA__LANE0__ENABLE {0} \
   CONFIG.PSU__SATA__LANE1__ENABLE {1} \
   CONFIG.PSU__SATA__LANE1__IO {GT Lane3} \
   CONFIG.PSU__SATA__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__SATA__REF_CLK_FREQ {125} \
   CONFIG.PSU__SATA__REF_CLK_SEL {Ref Clk3} \
   CONFIG.PSU__SAXIGP0__DATA_WIDTH {128} \
   CONFIG.PSU__SAXIGP1__DATA_WIDTH {128} \
   CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
   CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
   CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
   CONFIG.PSU__SAXIGP5__DATA_WIDTH {128} \
   CONFIG.PSU__SAXIGP6__DATA_WIDTH {128} \
   CONFIG.PSU__SD0_COHERENCY {0} \
   CONFIG.PSU__SD0_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__SD0__GRP_CD__ENABLE {0} \
   CONFIG.PSU__SD0__GRP_POW__ENABLE {0} \
   CONFIG.PSU__SD0__GRP_WP__ENABLE {0} \
   CONFIG.PSU__SD0__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__SD0__RESET__ENABLE {0} \
   CONFIG.PSU__SD1_COHERENCY {0} \
   CONFIG.PSU__SD1_ROUTE_THROUGH_FPD {0} \
   CONFIG.PSU__SD1__DATA_TRANSFER_MODE {8Bit} \
   CONFIG.PSU__SD1__GRP_CD__ENABLE {1} \
   CONFIG.PSU__SD1__GRP_CD__IO {MIO 45} \
   CONFIG.PSU__SD1__GRP_POW__ENABLE {0} \
   CONFIG.PSU__SD1__GRP_WP__ENABLE {0} \
   CONFIG.PSU__SD1__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__SD1__PERIPHERAL__IO {MIO 39 .. 51} \
   CONFIG.PSU__SD1__RESET__ENABLE {0} \
   CONFIG.PSU__SD1__SLOT_TYPE {SD 3.0} \
   CONFIG.PSU__SPI0_LOOP_SPI1__ENABLE {0} \
   CONFIG.PSU__SPI0__GRP_SS0__ENABLE {0} \
   CONFIG.PSU__SPI0__GRP_SS1__ENABLE {0} \
   CONFIG.PSU__SPI0__GRP_SS2__ENABLE {0} \
   CONFIG.PSU__SPI0__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__SPI1__GRP_SS0__ENABLE {0} \
   CONFIG.PSU__SPI1__GRP_SS1__ENABLE {0} \
   CONFIG.PSU__SPI1__GRP_SS2__ENABLE {0} \
   CONFIG.PSU__SPI1__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__SWDT0__CLOCK__ENABLE {0} \
   CONFIG.PSU__SWDT0__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__SWDT0__PERIPHERAL__IO {NA} \
   CONFIG.PSU__SWDT0__RESET__ENABLE {0} \
   CONFIG.PSU__SWDT1__CLOCK__ENABLE {0} \
   CONFIG.PSU__SWDT1__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__SWDT1__PERIPHERAL__IO {NA} \
   CONFIG.PSU__SWDT1__RESET__ENABLE {0} \
   CONFIG.PSU__TCM0A__POWER__ON {1} \
   CONFIG.PSU__TCM0B__POWER__ON {1} \
   CONFIG.PSU__TCM1A__POWER__ON {1} \
   CONFIG.PSU__TCM1B__POWER__ON {1} \
   CONFIG.PSU__TESTSCAN__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__TRACE_PIPELINE_WIDTH {8} \
   CONFIG.PSU__TRACE__INTERNAL_WIDTH {32} \
   CONFIG.PSU__TRACE__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__TRISTATE__INVERTED {1} \
   CONFIG.PSU__TSU__BUFG_PORT_PAIR {0} \
   CONFIG.PSU__TTC0__CLOCK__ENABLE {0} \
   CONFIG.PSU__TTC0__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__TTC0__PERIPHERAL__IO {NA} \
   CONFIG.PSU__TTC0__WAVEOUT__ENABLE {0} \
   CONFIG.PSU__TTC1__CLOCK__ENABLE {0} \
   CONFIG.PSU__TTC1__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__TTC1__PERIPHERAL__IO {NA} \
   CONFIG.PSU__TTC1__WAVEOUT__ENABLE {0} \
   CONFIG.PSU__TTC2__CLOCK__ENABLE {0} \
   CONFIG.PSU__TTC2__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__TTC2__PERIPHERAL__IO {NA} \
   CONFIG.PSU__TTC2__WAVEOUT__ENABLE {0} \
   CONFIG.PSU__TTC3__CLOCK__ENABLE {0} \
   CONFIG.PSU__TTC3__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__TTC3__PERIPHERAL__IO {NA} \
   CONFIG.PSU__TTC3__WAVEOUT__ENABLE {0} \
   CONFIG.PSU__UART0_LOOP_UART1__ENABLE {0} \
   CONFIG.PSU__UART0__BAUD_RATE {115200} \
   CONFIG.PSU__UART0__MODEM__ENABLE {0} \
   CONFIG.PSU__UART0__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__UART0__PERIPHERAL__IO {MIO 18 .. 19} \
   CONFIG.PSU__UART1__BAUD_RATE {<Select>} \
   CONFIG.PSU__UART1__MODEM__ENABLE {0} \
   CONFIG.PSU__UART1__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__UART1__PERIPHERAL__IO {<Select>} \
   CONFIG.PSU__USB0_COHERENCY {0} \
   CONFIG.PSU__USB0__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__USB0__PERIPHERAL__IO {MIO 52 .. 63} \
   CONFIG.PSU__USB0__REF_CLK_FREQ {26} \
   CONFIG.PSU__USB0__REF_CLK_SEL {Ref Clk2} \
   CONFIG.PSU__USB0__RESET__ENABLE {0} \
   CONFIG.PSU__USB1_COHERENCY {0} \
   CONFIG.PSU__USB1__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__USB1__RESET__ENABLE {0} \
   CONFIG.PSU__USB2_0__EMIO__ENABLE {0} \
   CONFIG.PSU__USB2_1__EMIO__ENABLE {0} \
   CONFIG.PSU__USB3_0__EMIO__ENABLE {0} \
   CONFIG.PSU__USB3_0__PERIPHERAL__ENABLE {1} \
   CONFIG.PSU__USB3_0__PERIPHERAL__IO {GT Lane2} \
   CONFIG.PSU__USB3_1__EMIO__ENABLE {0} \
   CONFIG.PSU__USB3_1__PERIPHERAL__ENABLE {0} \
   CONFIG.PSU__USB__RESET__MODE {Boot Pin} \
   CONFIG.PSU__USB__RESET__POLARITY {Active Low} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP0 {0} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP1 {0} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP2 {0} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP3 {0} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP4 {0} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP5 {0} \
   CONFIG.PSU__USE_DIFF_RW_CLK_GP6 {0} \
   CONFIG.PSU__USE__ADMA {0} \
   CONFIG.PSU__USE__APU_LEGACY_INTERRUPT {0} \
   CONFIG.PSU__USE__AUDIO {0} \
   CONFIG.PSU__USE__CLK {0} \
   CONFIG.PSU__USE__CLK0 {0} \
   CONFIG.PSU__USE__CLK1 {0} \
   CONFIG.PSU__USE__CLK2 {0} \
   CONFIG.PSU__USE__CLK3 {0} \
   CONFIG.PSU__USE__CROSS_TRIGGER {0} \
   CONFIG.PSU__USE__DDR_INTF_REQUESTED {0} \
   CONFIG.PSU__USE__DEBUG__TEST {0} \
   CONFIG.PSU__USE__EVENT_RPU {0} \
   CONFIG.PSU__USE__FABRIC__RST {1} \
   CONFIG.PSU__USE__FTM {0} \
   CONFIG.PSU__USE__GDMA {0} \
   CONFIG.PSU__USE__IRQ {0} \
   CONFIG.PSU__USE__IRQ0 {1} \
   CONFIG.PSU__USE__IRQ1 {1} \
   CONFIG.PSU__USE__M_AXI_GP0 {0} \
   CONFIG.PSU__USE__M_AXI_GP1 {0} \
   CONFIG.PSU__USE__M_AXI_GP2 {1} \
   CONFIG.PSU__USE__PROC_EVENT_BUS {0} \
   CONFIG.PSU__USE__RPU_LEGACY_INTERRUPT {0} \
   CONFIG.PSU__USE__RST0 {0} \
   CONFIG.PSU__USE__RST1 {0} \
   CONFIG.PSU__USE__RST2 {0} \
   CONFIG.PSU__USE__RST3 {0} \
   CONFIG.PSU__USE__RTC {0} \
   CONFIG.PSU__USE__STM {0} \
   CONFIG.PSU__USE__S_AXI_ACE {0} \
   CONFIG.PSU__USE__S_AXI_ACP {0} \
   CONFIG.PSU__USE__S_AXI_GP0 {0} \
   CONFIG.PSU__USE__S_AXI_GP1 {0} \
   CONFIG.PSU__USE__S_AXI_GP2 {0} \
   CONFIG.PSU__USE__S_AXI_GP3 {0} \
   CONFIG.PSU__USE__S_AXI_GP4 {0} \
   CONFIG.PSU__USE__S_AXI_GP5 {0} \
   CONFIG.PSU__USE__S_AXI_GP6 {0} \
   CONFIG.PSU__USE__USB3_0_HUB {0} \
   CONFIG.PSU__USE__USB3_1_HUB {0} \
   CONFIG.PSU__USE__VIDEO {0} \
   CONFIG.PSU__VIDEO_REF_CLK__ENABLE {0} \
   CONFIG.PSU__VIDEO_REF_CLK__FREQMHZ {33.333} \
   CONFIG.QSPI_BOARD_INTERFACE {custom} \
   CONFIG.SATA_BOARD_INTERFACE {custom} \
   CONFIG.SD0_BOARD_INTERFACE {custom} \
   CONFIG.SD1_BOARD_INTERFACE {custom} \
   CONFIG.SPI0_BOARD_INTERFACE {custom} \
   CONFIG.SPI1_BOARD_INTERFACE {custom} \
   CONFIG.SUBPRESET1 {Custom} \
   CONFIG.SUBPRESET2 {Custom} \
   CONFIG.SWDT0_BOARD_INTERFACE {custom} \
   CONFIG.SWDT1_BOARD_INTERFACE {custom} \
   CONFIG.TRACE_BOARD_INTERFACE {custom} \
   CONFIG.TTC0_BOARD_INTERFACE {custom} \
   CONFIG.TTC1_BOARD_INTERFACE {custom} \
   CONFIG.TTC2_BOARD_INTERFACE {custom} \
   CONFIG.TTC3_BOARD_INTERFACE {custom} \
   CONFIG.UART0_BOARD_INTERFACE {custom} \
   CONFIG.UART1_BOARD_INTERFACE {custom} \
   CONFIG.USB0_BOARD_INTERFACE {custom} \
   CONFIG.USB1_BOARD_INTERFACE {custom} \
 ] $zynq_ultra_ps_e

  # Create interface connections
  connect_bd_intf_net -intf_net PL_CLK_1 [get_bd_intf_ports PL_CLK] [get_bd_intf_pins MTS_block/PL_CLK]
  connect_bd_intf_net -intf_net PL_SYSREF_1 [get_bd_intf_ports PL_SYSREF] [get_bd_intf_pins MTS_block/PL_SYSREF]
  connect_bd_intf_net -intf_net adc2_clk_0_1 [get_bd_intf_ports adc2_clk] [get_bd_intf_pins rfdc/adc2_clk]
  connect_bd_intf_net -intf_net dac2_clk_0_1 [get_bd_intf_ports dac2_clk] [get_bd_intf_pins rfdc/dac2_clk]
  connect_bd_intf_net -intf_net sysref_in_0_1 [get_bd_intf_ports sysref_in] [get_bd_intf_pins rfdc/sysref_in]
  connect_bd_intf_net -intf_net zynq_ultra_ps_e_M_AXI_HPM0_LPD [get_bd_intf_pins axi_interconnect_pl/S00_AXI] [get_bd_intf_pins zynq_ultra_ps_e/M_AXI_HPM0_LPD]
  set peers {rfdc/s_axi axi_gpio_led/S_AXI MTS_block/s_axi_lite axi_intp/s_axi}
  foreach s $slaves { lappend peers eth100g/$s }
  set m 0
  foreach peer $peers {
    set mp [format M%02d_AXI $m]
    connect_bd_intf_net -intf_net axi_interconnect_pl_$mp [get_bd_intf_pins axi_interconnect_pl/$mp] [get_bd_intf_pins $peer]
    incr m
  }
  foreach v [concat [v49_vins] [v49_vouts]] {
    connect_bd_intf_net -intf_net ${v}_1 [get_bd_intf_ports $v] [get_bd_intf_pins rfdc/$v]
  }
  # the converter streams straight into / out of eth100g
  connect_bd_intf_net -intf_net rfdc_M_ADC_AXIS [get_bd_intf_pins rfdc/M_ADC_AXIS] [get_bd_intf_pins eth100g/S_AXIS_ADC]
  connect_bd_intf_net -intf_net eth100g_M_AXIS_DAC [get_bd_intf_pins eth100g/M_AXIS_DAC] [get_bd_intf_pins rfdc/S_DAC_AXIS]

  # Create port connections
  connect_bd_net -net MTS_block_pl_ref_clk [get_bd_pins MTS_block/pl_ref_clk] [get_bd_pins SYSREF_sync_adc/src_clk] [get_bd_pins SYSREF_sync_dac/src_clk]
  connect_bd_net -net MTS_block_sysref_raw [get_bd_pins MTS_block/sysref_raw] [get_bd_pins SYSREF_sync_adc/src_in] [get_bd_pins SYSREF_sync_dac/src_in]
  connect_bd_net -net adc_user_sysref [get_bd_pins SYSREF_sync_adc/dest_out] [get_bd_pins rfdc/user_sysref_adc]
  connect_bd_net -net dac_user_sysref [get_bd_pins SYSREF_sync_dac/dest_out] [get_bd_pins rfdc/user_sysref_dac]
  connect_bd_net -net MTS_clk_wiz_interrupt [get_bd_pins MTS_block/interrupt] [get_bd_pins intp_concat/In0]
  connect_bd_net -net usp_rf_data_converter_irq [get_bd_pins intp_concat/In1] [get_bd_pins rfdc/irq]
  connect_bd_net -net intp_concat_dout [get_bd_pins axi_intp/intr] [get_bd_pins intp_concat/dout]
  connect_bd_net -net axi_intc_0_irq [get_bd_pins axi_intp/irq] [get_bd_pins zynq_ultra_ps_e/pl_ps_irq0]
  connect_bd_net -net axi_gpio_led_gpio2_io_o [get_bd_ports led_r] [get_bd_pins axi_gpio_led/gpio2_io_o]
  connect_bd_net -net axi_gpio_led_gpio_io_o [get_bd_ports led_g] [get_bd_pins axi_gpio_led/gpio_io_o]
  # the converter AXIS clocks: MTS_clk_wiz drives adc_clk and dac_clk from one
  # output; eth100g runs on dac_clk
  connect_bd_net -net adc_axis_clk [get_bd_pins MTS_block/adc_clk] [get_bd_pins SYSREF_sync_adc/dest_clk] [get_bd_pins adc_clk_aresetn/slowest_sync_clk] [get_bd_pins rfdc/adc_axis_clk]
  connect_bd_net -net adc_axis_aresetn [get_bd_pins adc_clk_aresetn/peripheral_aresetn] [get_bd_pins rfdc/adc_axis_aresetn]
  connect_bd_net -net dac_axis_clk [get_bd_pins MTS_block/dac_clk] [get_bd_pins SYSREF_sync_dac/dest_clk] [get_bd_pins dac_adc_clk_aresetn/slowest_sync_clk] [get_bd_pins rfdc/dac_axis_clk] [get_bd_pins eth100g/adc_clk]
  connect_bd_net -net dac_axis_aresetn [get_bd_pins dac_adc_clk_aresetn/peripheral_aresetn] [get_bd_pins rfdc/dac_axis_aresetn] [get_bd_pins eth100g/adc_aresetn]
  connect_bd_net -net rst_ps8_99M_peripheral_aresetn [get_bd_pins MTS_block/pl_aresetn] [get_bd_pins axi_gpio_led/s_axi_aresetn] [get_bd_pins axi_interconnect_pl/aresetn] [get_bd_pins axi_intp/s_axi_aresetn] [get_bd_pins proc_sys_reset_pl/peripheral_aresetn] [get_bd_pins rfdc/s_axi_aresetn] [get_bd_pins eth100g/s_axi_aresetn]
  connect_bd_net -net zynq_ultra_ps_e_pl_clk1 [get_bd_pins MTS_block/pl_clk] [get_bd_pins axi_gpio_led/s_axi_aclk] [get_bd_pins axi_interconnect_pl/aclk] [get_bd_pins axi_intp/s_axi_aclk] [get_bd_pins proc_sys_reset_pl/slowest_sync_clk] [get_bd_pins rfdc/s_axi_aclk] [get_bd_pins zynq_ultra_ps_e/maxihpm0_lpd_aclk] [get_bd_pins zynq_ultra_ps_e/pl_clk0] [get_bd_pins eth100g/s_axi_aclk]
  connect_bd_net -net zynq_ultra_ps_e_pl_resetn0 [get_bd_pins adc_clk_aresetn/ext_reset_in] [get_bd_pins dac_adc_clk_aresetn/ext_reset_in] [get_bd_pins proc_sys_reset_pl/ext_reset_in] [get_bd_pins zynq_ultra_ps_e/pl_resetn0]

  # the CMAC side: external ports, wired to cmac_100g in the RTL top
  # (v49_gen_top in scripts/v49_build.tcl)
  create_bd_port -dir I -type clk -freq_hz 322265625 cmac_usr_clk
  set p [create_bd_port -dir I -type rst cmac_usr_rstn]
  set_property CONFIG.POLARITY {ACTIVE_LOW} $p
  connect_bd_net [get_bd_ports cmac_usr_clk] [get_bd_pins eth100g/usr_clk]
  connect_bd_net [get_bd_ports cmac_usr_rstn] [get_bd_pins eth100g/usr_rstn]
  make_bd_intf_pins_external [get_bd_intf_pins eth100g/M_AXIS_CMAC_TX]
  set_property name cmac_tx [get_bd_intf_ports M_AXIS_CMAC_TX_0]
  make_bd_intf_pins_external [get_bd_intf_pins eth100g/S_AXIS_CMAC_RX]
  set_property name cmac_rx [get_bd_intf_ports S_AXIS_CMAC_RX_0]
  set_property CONFIG.ASSOCIATED_BUSIF {cmac_tx:cmac_rx} [get_bd_ports cmac_usr_clk]
  set_property CONFIG.ASSOCIATED_RESET {cmac_usr_rstn} [get_bd_ports cmac_usr_clk]
  create_bd_port -dir O -from 31 -to 0 cmac_ctl
  create_bd_port -dir I -from 31 -to 0 cmac_status
  connect_bd_net [get_bd_ports cmac_ctl] [get_bd_pins eth100g/cmac_ctl]
  connect_bd_net [get_bd_ports cmac_status] [get_bd_pins eth100g/cmac_status]
  create_bd_port -dir I -from 31 -to 0 cmac_refclk_khz
  create_bd_port -dir I -from 31 -to 0 cmac_usrclk_khz
  connect_bd_net [get_bd_ports cmac_refclk_khz] [get_bd_pins eth100g/refclk_khz]
  connect_bd_net [get_bd_ports cmac_usrclk_khz] [get_bd_pins eth100g/usrclk_khz]
  create_bd_port -dir O -type clk cmac_init_clk
  connect_bd_net [get_bd_ports cmac_init_clk] [get_bd_pins zynq_ultra_ps_e/pl_clk0]

  # Create address segments (the same PS map as the ZCU216 builds)
  set ps [get_bd_addr_spaces zynq_ultra_ps_e/Data]
  assign_bd_address -offset 0x80200000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs MTS_block/MTS_clk_wiz/s_axi_lite/Reg] -force
  assign_bd_address -offset 0x80230000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs axi_gpio_led/S_AXI/Reg] -force
  assign_bd_address -offset 0x80240000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs axi_intp/S_AXI/Reg] -force
  assign_bd_address -offset 0x80280000 -range 0x00040000 -target_address_space $ps [get_bd_addr_segs rfdc/usp_rf_data_converter/s_axi/Reg] -force
  assign_bd_address -offset 0x80020000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs eth100g/udp_streamer/s_axi/reg0] -force
  assign_bd_address -offset 0x80030000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs eth100g/udp_player/s_axi/reg0] -force
  assign_bd_address -offset 0x80040000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs eth100g/cmac_gpio/S_AXI/Reg] -force
  assign_bd_address -offset 0x80050000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs eth100g/cmac_freq/S_AXI/Reg] -force
  if {$nch > 1} {
    assign_bd_address -offset 0x80060000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs eth100g/tx_beamformer/s_axi/*] -force
    assign_bd_address -offset 0x80070000 -range 0x00010000 -target_address_space $ps [get_bd_addr_segs eth100g/rx_beamformer/s_axi/*] -force
  }

  current_bd_instance $oldCurInst
}
# End of create_root_design()

##################################################################
# MAIN FLOW
##################################################################

create_root_design "" $v49_nch
apply_geometry $v49_nch [v49_geometry $v49_nch $v49_F]
validate_bd_design
verify_rate_variant $v49_F $v49_nch
save_bd_design
