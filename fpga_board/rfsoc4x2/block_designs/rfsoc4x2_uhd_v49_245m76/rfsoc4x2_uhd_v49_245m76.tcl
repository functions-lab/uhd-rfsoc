################################################################
# rfsoc4x2_uhd_v49_245m76.tcl -- the RFSoC 4x2 as a UHD device over 100 GbE
# (rfsoc-uhd), 245.76 MHz clock family: the v49 block design for every
# channel count N = 1, 2, factor F and sample rate fs.
#
# The clock tree differs from rfsoc4x2_uhd_v49 (the 250 MHz family): the
# LMK04828 feeds the LMX2594 245.76 MHz and the PL 122.88 MHz (PL_CLK, the
# MTS_clk_wiz input) with a 7.68 MHz SYSREF
# (rfsoc/rfsoc_lib/xrfclk/RFSoC4x2/LMK04828_10.0_245.76_122.88_7.68.txt), and
# the LMX2594 clocks the tiles at fs = 4915.2 MS/s
# (LMX2594_245.76_4915.2.txt). The daemon picks both register files from the
# build (its fs and its MTS_clk_wiz input frequency).
#
# Self-contained: this file and rfsoc4x2_uhd_v49_245m76.xdc in the same
# directory are the whole design. Sourced into a Vivado 2021.1 project for the RFSoC 4x2
# (xczu48dr-ffvg1517-2-e, board part realdigital.org:rfsoc4x2:part0:1.0 from
# ../../board_files) whose IP repository path holds the packaged UHD
# cores user.org:uhd:*:1.0 (fpga_ip/ip/uhd_ip, `make package` in
# fpga_ip/ip_design/uhd_ip) and the dual RF-ADC I/Q joiners
# user.org:user:dual_rf_adc_iq_merger:1.0 (N = 1) and
# user.org:user:dual_channel_rf_adc_iq_packer:1.0 (N = 2) (fpga_ip/ip/iprepo);
# everything else is Xilinx IP. The CMAC and its GT cannot sit in a block
# design: the RTL top that scripts/v49_build.tcl generates instantiates
# fpga_ip/ip_design/cmac_100g next to it.
#
# Parameters (Tcl globals, set before sourcing; scripts/v49_build.tcl sets them):
#   V49_NCH          channel count N: 1 or 2 (required)
#   V49_FACTOR       RFDC converter factor F, a v49_geometry row of N
#                    (default: N's first row)
#   V49_FS           converter sample rate fs, MS/s (default 4915.2)
#   V49_DEFINE_ONLY  1: define the v49_* procs and return without building
# The block design is named rfsoc4x2_v49_<N>ch_qsfp.
#
# The RFSoC 4x2's RF-ADC tiles are DUAL: in I/Q mode each converter delivers I
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
# Both beamformers (Protocol §11; IP user.org:uhd:
# {tx,rx}_beamformer:1.0, sources ip_design/uhd_ip/src) work on the
# channel-major beat, bypass by default:
#   tx_beamformer  channel 0 x w[c] to every DAC c. AXI-Lite 0x8006_0000.
#                  PIPE = 1 (pipelined math, 5-cycle latency) above a 150 MHz
#                  converter clock, 0 (beamformer_v1_0 unchanged, 3 cycles)
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
# Wire format and control: the Protocol (top AGENTS.md). Addresses (AXI-Lite, pl_clk0):
#   0x8002_0000  eth100g/udp_streamer   ADC -> UDP (map in udp_streamer.v)
#   0x8003_0000  eth100g/udp_player     UDP -> DAC, ARP, flow control (udp_player.v)
# udp_streamer, udp_player, axis_pkt_arb and ch_interleave are packaged IP
# (user.org:uhd:<core>:1.0) in fpga_ip/ip/uhd_ip; their sources, testbenches
# and packaging script are in fpga_ip/ip_design/uhd_ip.
#   0x8004_0000  eth100g/cmac_gpio      ch1 = cmac ctl (out, default 0xF003: GT held
#                                        in reset), ch2 = cmac status (in); bits in
#                                        ip_design/cmac_100g/cmac_100g.v
#   0x8005_0000  eth100g/cmac_freq      ch1 = GT refclk kHz, ch2 = CMAC user clock kHz
#                                        (expect 156250 and 322266: the Si570 runs from power-up)
#   0x8006_0000  eth100g/tx_beamformer  N >= 2 only: TX beamformer (Protocol §11)
#   0x8007_0000  eth100g/rx_beamformer  N >= 2 only: RX beamformer (Protocol §11)
# The CMAC and its GT wizard (quad 128, the QSFP28) cannot live in the block design:
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
# gt_txusrclk2 (322.265625 MHz, runs once the GT TX PLL locks on the Si570 refclk),
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

  # (the QSFP28 ResetL / LPMode / ModSelL are held constant by the RTL top:
  # scripts/v49_build.tcl v49_gen_top, pins in rfsoc4x2_uhd_v49_245m76.xdc)

  # ---- streams
  # beat width of the combined converter stream (Protocol §9)
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

# Converter geometry per channel count N (Protocol §9).
# The factor F is a BLOCK DESIGN parameter (never a run-time one), set on
# EVERY ADC and DAC slice. S = complex samples per
# channel per converter clock:
#   ADC (dual tile, I/Q on two streams)  Data_Width = S per stream
#   DAC (I/Q interleaved on one stream)  Data_Width = 2 S
#   Fabric_Freq = fs / F / S  ==  MTS_clk_wiz clk_out1, the converter AXIS
#   clock of the whole design; beat_w = N x 32 x S, the S_WIDTH / M_WIDTH of
#   udp_streamer / udp_player.
# Converters sample at fs = V49_FS (4915.2 MS/s on every build of this
# design; DACs at the same fs), tile PLLs bypassed: every tile takes the fs
# MHz LMX2594 output (rfsoc/rfsoc_lib/xrfclk/RFSoC4x2/LMX2594_245.76_4915.2.txt,
# from the LMK04828's 245.76 MHz).
#
#   N  F (template first)                          S  beat   fabric = fs/F/S    per-channel rate
#   1  2 3 4 5 6 8 10 12 16 20 24 40                8  256 b  307.2 .. 15.36 MHz  2457.6 .. 122.88 MS/s
#   2  2 3 4 5 6 8 10 12 16 20 24 40                8  512 b  307.2 .. 15.36 MHz  2457.6 .. 122.88 MS/s
#
# Each channel count's template is its highest rate whose stream fits the
# 100G link in some wire format (Protocol §10), retuned at run time to every
# lower factor (Protocol §8); which formats a rate carries is the daemon's
# link check: 1ch carries sc16 at 2457.6 MS/s (79 Gb/s), 2ch sc8 at 2 x 2457.6,
# sc12 / sc8 at 2 x 1638.4 and sc16 from 2 x 1228.8 down. Every row is also a
# fixed build. Builds are named rfsoc4x2_v49_<N>ch_qsfp_f<F>_fs4915p2 (the
# decimal point of fs as p; scripts/v49_ladder.sh lists them).
# TICK_STEP 1 on every build: one tick is one 32-bit slot time.
proc v49_fs {} {
  expr {[info exists ::V49_FS] ? double($::V49_FS) : 4915.2}
}

proc v49_geometry {nch {F ""}} {
  # N -> list of {F S}, the default (first) row is the max-rate build
  set rows [dict create \
    1 {{2 8} {3 8} {4 8} {5 8} {6 8} {8 8} {10 8} {12 8} {16 8} {20 8} {24 8} {40 8}} \
    2 {{2 8} {3 8} {4 8} {5 8} {6 8} {8 8} {10 8} {12 8} {16 8} {20 8} {24 8} {40 8}} ]
  set fs [v49_fs]
  if {![dict exists $rows $nch]} { error "v49 (RFSoC4x2): no geometry for $nch channels (1 or 2)" }
  set row ""
  set factors {}
  foreach r [dict get $rows $nch] {
    lappend factors [lindex $r 0]
    if {$row eq "" && ($F eq "" || [lindex $r 0] == $F)} { set row $r }
  }
  if {$row eq ""} { error "v49 (RFSoC4x2): $nch channels is built at factor [join $factors {, }] only, not $F" }
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
# every ladder frequency exactly from the 122.88 MHz input: VCO = 122.88 x M / D,
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
  puts "V49_GEOMETRY (RFSoC4x2) N=$nch fs $fs MS/s factor $F S $S (ADC Data_Width $adc_dw, DAC $dac_dw)\
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
  set_property USER_COMMENTS.comment_1 "[current_bd_design] (RFSoC 4x2 v49)
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
  puts "V49_RATE verified (RFSoC4x2): N=$nch, factor $F on all $nslice enabled slices (ADC Data_Width $adc_dw,\
        DAC $dac_dw), fabric $fabric MHz on every tile, clk_wiz $clk MHz, beat $beat_w b, TICK_STEP $tick_step,\
        TX buffer [dict get $tbuf TX_BUF_WORDS] words,\
        [expr {$nch > 1 ? "beamformers N_CH $nch PIPE $bf_pipe" : "no beamformers"}], PS address map as on ZCU216"
}

if {[info exists ::V49_DEFINE_ONLY] && $::V49_DEFINE_ONLY} { return }

################################################################
# Parameters
################################################################
if {![info exists ::V49_NCH]} { error "rfsoc4x2_uhd_v49_245m76: set V49_NCH (1 or 2) before sourcing" }
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
   create_project project_1 myproj -part xczu48dr-ffvg1517-2-e
}
# RFSoC 4x2 ONLY: a netlist for another die would build without complaint.
if { [get_property PART [current_project]] ne "xczu48dr-ffvg1517-2-e" } {
   error "rfsoc4x2_uhd_v49_245m76 targets the RFSoC 4x2 (xczu48dr-ffvg1517-2-e), not [get_property PART [current_project]]"
}

variable design_name
set design_name rfsoc4x2_v49_${v49_nch}ch_qsfp
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
   error "rfsoc4x2_uhd_v49_245m76: IPs not in the catalog: $list_ips_missing (user.org:uhd:*: run 'make package' in fpga_ip/ip_design/uhd_ip and add fpga_ip/ip/uhd_ip to ip_repo_paths; the I/Q joiners: fpga_ip/ip/iprepo)"
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
   CONFIG.CLKIN1_JITTER_PS {81.38} \
   CONFIG.CLKOUT1_DRIVES {Buffer} \
   CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {307.2} \
   CONFIG.CLKOUT2_DRIVES {Buffer} \
   CONFIG.CLKOUT3_DRIVES {Buffer} \
   CONFIG.CLKOUT4_DRIVES {Buffer} \
   CONFIG.CLKOUT5_DRIVES {Buffer} \
   CONFIG.CLKOUT6_DRIVES {Buffer} \
   CONFIG.CLKOUT7_DRIVES {Buffer} \
   CONFIG.ENABLE_CLOCK_MONITOR {true} \
   CONFIG.JITTER_SEL {Min_O_Jitter} \
   CONFIG.MMCM_BANDWIDTH {HIGH} \
   CONFIG.MMCM_CLKFBOUT_MULT_F {10.000} \
   CONFIG.MMCM_CLKIN1_PERIOD {8.138} \
   CONFIG.MMCM_CLKIN2_PERIOD {10.0} \
   CONFIG.MMCM_CLKOUT0_DIVIDE_F {4.000} \
   CONFIG.MMCM_DIVCLK_DIVIDE {1} \
   CONFIG.PRIMITIVE {MMCM} \
   CONFIG.PRIM_IN_FREQ {122.88} \
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
   CONFIG.FREQ_HZ {122880000} \
   ] $PL_CLK

  set PL_SYSREF [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 PL_SYSREF ]
  set_property -dict [ list \
   CONFIG.FREQ_HZ {7680000} \
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
  # The RFSoC 4x2's PS: Real Digital's board preset (DDR4, MIO, peripherals;
  # board files ../../board_files, board part realdigital.org:rfsoc4x2:part0:1.0),
  # then the PL side this design uses: one master port, HPM0_LPD (M_AXI_GP2,
  # 128 bit; the register map at 0x8000_0000 is in its window), pl_clk0 =
  # 100 MHz from the IOPLL (s_axi / CMAC init clock), one fabric reset, IRQ0/1.
  if {[get_property BOARD_PART [current_project]] ne "realdigital.org:rfsoc4x2:part0:1.0"} {
     error "rfsoc4x2_uhd_v49_245m76: the project needs BOARD_PART realdigital.org:rfsoc4x2:part0:1.0 (set_param board.repoPaths <fpga_board/rfsoc4x2/board_files>), not '[get_property BOARD_PART [current_project]]'"
  }
  apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $zynq_ultra_ps_e
  set_property -dict [ list \
   CONFIG.PSU__USE__M_AXI_GP0 {0} \
   CONFIG.PSU__USE__M_AXI_GP1 {0} \
   CONFIG.PSU__USE__M_AXI_GP2 {1} \
   CONFIG.PSU__MAXIGP2__DATA_WIDTH {128} \
   CONFIG.PSU__FPGA_PL0_ENABLE {1} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL} \
   CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
   CONFIG.PSU__FPGA_PL1_ENABLE {0} \
   CONFIG.PSU__FPGA_PL2_ENABLE {0} \
   CONFIG.PSU__FPGA_PL3_ENABLE {0} \
   CONFIG.PSU__USE__FABRIC__RST {1} \
   CONFIG.PSU__NUM_FABRIC_RESETS {1} \
   CONFIG.PSU__USE__IRQ0 {1} \
   CONFIG.PSU__USE__IRQ1 {1} \
   CONFIG.PSU__HIGH_ADDRESS__ENABLE {1} \
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
