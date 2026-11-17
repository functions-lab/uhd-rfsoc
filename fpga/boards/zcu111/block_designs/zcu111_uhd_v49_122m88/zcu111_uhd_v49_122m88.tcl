################################################################
# zcu111_uhd_v49_122m88.tcl -- the ZCU111 as a UHD device over 100 GbE (uhd-rfsoc):
# the v49 block design for every channel count N = 1, 2, 4, 8, factor F and
# sample rate fs (3932.16 MS/s = 8 x 491.52: the 3GPP rates; the 320 MHz family
# zcu111_uhd_v49_320m has 4000).
#
# Self-contained: this file and zcu111_uhd_v49_122m88.xdc in the same directory are
# the whole design. Sourced into a Vivado 2021.1 project for the ZCU111
# (xczu28dr-ffvg1517-2-e, board part xilinx.com:zcu111:part0:1.4, Vivado's
# own board files) whose IP repository path holds the packaged UHD cores
# user.org:uhd:*:1.0 (fpga/ip/repo/uhd_ip, `make -C fpga package` from
# fpga/ip/src/uhd_ip) and the dual RF-ADC I/Q joiner
# user.org:user:dual_rf_adc_iq_merger:1.0 (fpga/ip/repo, one per channel);
# everything else is Xilinx IP. The CMAC and its GT cannot sit in a block
# design: the RTL top that fpga/flow/build.tcl generates instantiates
# fpga/ip/src/cmac_100g next to it. Board facts and their sources:
# fpga/boards/zcu111/AGENTS.md.
#
# The ZCU111's XCZU28DR is a GEN1 RFSoC (RFDC C_IP_Type 0) with the ZCU208's
# data-path shape (four DUAL RF-ADC tiles 224..227, I/Q on two slices) but
# only two RF-DAC tiles (228, 229, four DACs each), so the data path follows
# zcu208_uhd_v49 with these Gen1 differences:
#   - converter factors 2, 4, 8 only (Gen1 decimation 1, 2, 4, 8; Gen1 DAC
#     interpolation of I/Q data 2, 4, 8: no F = 1 TX);
#   - no on-chip clock distribution (Gen3 only): each of the six tiles takes
#     its own LMX2594 output on its own adc<t>_clk / dac<t>_clk pin (three
#     LMX2594s, RFoutA and RFoutB each, on the ZCU111), tile PLLs bypassed;
#   - MTS on ADC tiles 0..3 and DAC tiles 0..1, reference tile 0 of each
#     (Gen1: tile 0 must be active).
#
# Clocks (the 122.88 MHz family: the LMK04208's 122.88 MHz VCXO feeds the
# LMX2594s; the 320 MHz one, fs 4000, is zcu111_uhd_v49_320m):
# rfsoc/rfsoc_lib/xrfclk/ZCU111/LMK04208_12.8_122.88_122.88_7.68.txt (PYNQ's
# stock ZCU111 file: PL_CLK 122.88 MHz = the MTS_clk_wiz input, SYSREF
# 7.68 MHz to the PL and to the RFSoC) and LMX2594_122.88_<fs>.txt (every
# tile at fs). The daemon picks both from the build (its fs and its
# MTS_clk_wiz input frequency).
#
# Vivado release: the design is written for 2021.1 and names 2021.1's IP
# versions. fpga/flow/build.tcl also builds it with the other releases of
# fpga/flow/versions.txt (one per PYNQ version): its v49_vlnv maps every
# xilinx.com:ip VLNV below to that release's version. Sourced without the
# flow, the VLNVs are used as written and only 2021.1 is accepted.
#
# Parameters (Tcl globals, set before sourcing; fpga/flow/build.tcl sets them):
#   V49_NCH          channel count N: 1, 2, 4 or 8 (required)
#   V49_FACTOR       RFDC converter factor F, a v49_geometry row of N
#                    (default: N's first row at fs)
#   V49_FS           converter sample rate fs, MS/s (default 3932.16)
#   V49_DEFINE_ONLY  1: define the v49_* procs and return without building
# The block design is named zcu111_v49_<N>ch_qsfp.
#
# The dual RF-ADC tiles deliver each converter's I and Q on two AXIS streams
# (m<t><2k> = I, m<t><2k+1> = Q, Data_Width samples each). The rfdc hierarchy
# joins each channel's pair into one complex stream with a
# dual_rf_adc_iq_merger (I in the low 16 bits of each 32-bit slot,
# C_S_AXIS_TDATA_WIDTH = 16 x samples) and, for N > 1, the N channel streams
# side by side with an axis_combiner (channel-major: channel c = S<c>_AXIS,
# bits [c*W +: W]). The DACs take I/Q interleaved on one stream (Data_Width =
# 2 x samples): N = 1 feeds channel 0's DAC directly, N > 1 splits the
# channel-major beat with an axis_broadcaster (M<c>_AXIS = channel c). Every
# ADC and DAC of the part is enabled on every build (8 + 8, MTS on all six
# tiles); only channels 0..N-1 stream. Channel map (v49_channel_slices,
# rfsoc/server/boards.py): channel c is ADC tile c / 2 converter c % 2 and
# DAC tile c / 4 slice c % 4:
#   c 0..3: ADC 224 ch0/ch1, 225 ch0/ch1 (XM500 J4, J3, J2, J1: baluned SMAs),
#           DAC 228 ch0..3 (differential SMA pairs)
#   c 4..7: ADC 226, 227 (differential pairs), DAC 229 ch0..3 (J7, J8, J5, J6:
#           baluned)
# so every N includes ADC tile 0 and DAC tile 0, the MTS reference tiles.
#
# eth100g sits on rfdc/M_ADC_AXIS and rfdc/S_DAC_AXIS (channel-major for
# N > 1), with the ch_interleave IP re-ordering the 32-bit slots to/from the
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
# than one sample per channel; with one sample per channel per beat the two
# layouts coincide and it is wires. The cores'
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
# (user.org:uhd:<core>:1.0) in fpga/ip/repo/uhd_ip; their sources, testbenches
# and packaging script are in fpga/ip/src/uhd_ip.
#   0x8004_0000  eth100g/cmac_gpio      ch1 = cmac ctl (out, default 0xF003: GT held
#                                        in reset), ch2 = cmac status (in); bits in
#                                        ip_design/cmac_100g/cmac_100g.v
#   0x8005_0000  eth100g/cmac_freq      ch1 = GT refclk kHz, ch2 = CMAC user clock kHz
#                                        (expect 156250 and 322266: the Si570 runs
#                                        from power-up)
#   0x8006_0000  eth100g/tx_beamformer  N >= 2 only: TX beamformer (Protocol §11)
#   0x8007_0000  eth100g/rx_beamformer  N >= 2 only: RX beamformer (Protocol §11)
# The CMAC and its GT wizard cannot live in the block design: neither
# cmac_usplus nor gtwizard_ultrascale may sit inside a module reference
# (filemgmt 56-181). ip_design/cmac_100g/cmac_100g.v is instantiated in the
# RTL top (generated by build.tcl's v49_gen_top from the BD wrapper), built
# with CMAC_LANES sfp128: the four SFP28 cages SFP0..3 = GTY X0Y4..X0Y7
# (quad 128, CMACE4_X0Y0), refclk the user MGT Si570 (156.25 MHz at power-up)
# on MGTREFCLK1 of quad 129, the quad above. The BD exports:
#   cmac_usr_clk / cmac_usr_rstn   CMAC user clock and reset (in)
#   cmac_tx / cmac_rx              512-bit AXIS to / from the CMAC
#   cmac_ctl / cmac_status         the GPIO words (bits in cmac_100g.v)
#   cmac_init_clk                  pl_clk0, the CMAC init/DRP clock (out)
# The SFP28 TX_DISABLE lines are jumpers on the ZCU111 (UG1271 Table 3-21),
# not FPGA pins: nothing drives them here.
#
# Clocks: adc_clk = MTS_block/dac_clk (= adc_clk: one MTS_clk_wiz output; the converter
# AXIS clock fs/F/S, v49_geometry), tx_clk = CMAC gt_txusrclk2 (322.265625
# MHz), s_axi/init = pl_clk0 (100 MHz).
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
# 2 MiB = 64 of the xczu28dr's 80 URAM288 (the same fabric as the xczu48dr:
# 80 URAM288, 1080 RAMB36). META_DEPTH scales with it so the
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

  set gpio [create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axi_gpio:2.0] cmac_gpio]
  set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_DOUT_DEFAULT {0x0000F003} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1} \
  ] $gpio

  # Measured GT refclk / CMAC user clock (kHz): ch1 refclk, ch2 usr_clk
  set fgpio [create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axi_gpio:2.0] cmac_freq]
  set_property -dict [list CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1}] $fgpio
  connect_bd_intf_net [get_bd_intf_pins S_AXI_FREQ] [get_bd_intf_pins cmac_freq/S_AXI]
  connect_bd_net [get_bd_pins refclk_khz] [get_bd_pins cmac_freq/gpio_io_i]
  connect_bd_net [get_bd_pins usrclk_khz] [get_bd_pins cmac_freq/gpio2_io_i]

  # (no SFP28 sideband: the cages' TX_DISABLE are jumpers on the ZCU111)

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
  set one [create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xlconstant:1.1] adc_tready_one]
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
  set zero [create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xlconstant:1.1] dma_tvalid_zero]
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
  set aligned [create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xlslice:1.0] cmac_aligned]
  set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0}] $aligned
  set txen [create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xlslice:1.0] cmac_txen]
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
#   ADC (dual tile, I/Q on two streams)  Data_Width = S per stream (Gen1: <= 8)
#   DAC (I/Q interleaved on one stream)  Data_Width = 2 S         (Gen1: <= 16)
#   Fabric_Freq = fs / F / S  ==  MTS_clk_wiz clk_out1, the converter AXIS
#   clock of the whole design; beat_w = N x 32 x S, the S_WIDTH / M_WIDTH of
#   udp_streamer / udp_player.
# Converters sample at fs = V49_FS (DACs at the same fs), tile PLLs bypassed:
# every tile takes the fs MHz LMX2594 output
# (rfsoc/rfsoc_lib/xrfclk/ZCU111/LMX2594_122.88_<fs>.txt: 3932.16, made in TICS
# Pro: N 64 integer, VCO 7864.32 MHz / 2).
# Gen1 factors only: F in {2, 4, 8} (v49_gen1_factors).
#
# The rows of N are the candidates {F S}; at an fs the rows whose fabric
# clock exceeds 312.5 MHz are not built, so the template (the first row left)
# depends on fs:
#   N  S  beat   F (template first)   fs 3932.16: fabric MHz, MS/s/ch
#   1  8  256 b  2 4 8                 245.76 .. 61.44, 1966.08 .. 491.52
#   2  8  512 b  2 4 8                 245.76 .. 61.44, 1966.08 .. 491.52
#   4  4  512 b  (2) 4 8               245.76 .. 122.88, 983.04 .. 491.52
#   8  2  512 b  (2 4) 8               245.76, 491.52
# ((F): its fabric clock is above 312.5 MHz at 3932.16: not built.)
#
# Each channel count's template is its highest rate whose stream fits the
# 100G link in some wire format (Protocol §10), at a 512-bit (or narrower)
# beat so that every format converts, retuned at run time to every higher
# Gen1 factor of its row (Protocol §8); which formats a rate carries is the
# daemon's link check (1ch: sc16 at 1966.08 MS/s; 2ch / 4ch / 8ch templates:
# sc8). Every row is also a fixed build. Builds are named
# zcu111_v49_<N>ch_qsfp_f<F>_fs<fs> (builds.txt lists them).
# TICK_STEP 1 on every build: one tick is one 32-bit slot time.
proc v49_fs {} {
  expr {[info exists ::V49_FS] ? double($::V49_FS) : 3932.16}
}

# Gen1 RF-ADC decimation is 1, 2, 4, 8 and Gen1 RF-DAC interpolation of I/Q
# data 2, 4, 8 (PG269; Vivado on the xczu28dr): the factors of a coupled
# RX / TX build
proc v49_gen1_factors {} { return {2 4 8} }

# PL SYSREF = analog SYSREF (MHz), from the LMK04208 file of this family
proc v49_sysref {} { return 7.68 }
# PL_CLK (MHz): the MTS_clk_wiz input
proc v49_pl_clk {} { return 122.88 }

proc v49_geometry {nch {F ""}} {
  # N -> list of {F S}; the default is the first row whose fabric clock fits
  set rows [dict create \
    1 {{2 8} {4 8} {8 8}} \
    2 {{2 8} {4 8} {8 8}} \
    4 {{2 4} {4 4} {8 4}} \
    8 {{2 2} {4 2} {8 2}} ]
  set fs [v49_fs]
  if {![dict exists $rows $nch]} { error "v49 (ZCU111): no geometry for $nch channels (1, 2, 4 or 8)" }
  set row ""
  set factors {}
  foreach r [dict get $rows $nch] {
    lassign $r f s
    if {$fs / $f / $s > 312.5} continue
    lappend factors $f
    if {$row eq "" && ($F eq "" || $f == $F)} { set row $r }
  }
  if {$row eq "" && $F ne "" && $F in [v49_gen1_factors]} {
    foreach r [dict get $rows $nch] {
      if {[lindex $r 0] == $F} { error "v49: N=$nch F=$F S=[lindex $r 1] at $fs MS/s needs a [expr {$fs / $F / [lindex $r 1]}] MHz fabric (max 312.5)" }
    }
  }
  if {$row eq ""} { error "v49 (ZCU111): $nch channels at $fs MS/s is built at factor [join $factors {, }] only, not '$F'" }
  lassign $row F S
  if {$F ni [v49_gen1_factors]} { error "v49 (ZCU111): factor $F is not a Gen1 factor ([v49_gen1_factors])" }
  if {$S > 8} { error "v49 (ZCU111): S=$S: Gen1 ADC Data_Width is at most 8, DAC at most 16" }
  set beat [expr {$nch * 32 * $S}]
  # at most 512 bits: every wire format converts (Protocol §10)
  if {$beat != 128 && $beat != 256 && $beat != 512} { error "v49: N=$nch S=$S gives a $beat-bit beat (128, 256 or 512)" }
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
  puts "V49_GEOMETRY (ZCU111) N=$nch fs $fs MS/s factor $F S $S (ADC Data_Width $adc_dw, DAC $dac_dw)\
        -> [expr {$fs / $F}] MS/s per channel, fabric $fabric MHz, beat $beat_w b"
  set_property -dict [list CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %g $fabric]] \
      [get_bd_cells MTS_block/MTS_clk_wiz]
  v49_clk_exact $fabric
  set rfdc [get_bd_cells rfdc/usp_rf_data_converter]
  foreach {k t} [v49_tiles] {
    set sr [get_property CONFIG.${k}${t}_Sampling_Rate $rfdc]
    if {abs($sr - $fs / 1000.0) > 1e-6} { error "v49: ${k}${t}_Sampling_Rate is $sr GS/s, expected [expr {$fs / 1000.0}] (v49_rfdc_creation)" }
  }
  # the part's tiles only: list_property also names the absent DAC tiles 2
  # and 3 (230, 231), whose parameters are disabled
  set cfg {}
  foreach {pat v} [list {ADC_Decimation_Mode[0-3][0-3]} $F {ADC_Data_Width[0-3][0-3]} $adc_dw \
                        {DAC_Interpolation_Mode[01][0-3]} $F {DAC_Data_Width[01][0-3]} $dac_dw] {
    foreach p [v49_rfdc_props $rfdc $pat] { lappend cfg $p $v }
  }
  # re-asserted in the SAME dict: writing a converter mode makes the IP
  # recompute dependents and drop MTS back to false
  foreach {k t} [v49_tiles] { lappend cfg CONFIG.${k}${t}_Multi_Tile_Sync true }
  set_property -dict $cfg $rfdc
  foreach c {eth100g/udp_streamer eth100g/udp_player} {
    set_property CONFIG.TICK_STEP $tick_step [get_bd_cells $c]
  }
  v49_converter_streams $nch $S $beat_w
  set_property USER_COMMENTS.comment_1 "[current_bd_design] (ZCU111 v49)
- $nch DACs + $nch ADCs @ [format %g [expr {$fs / 1000.0}]] GSPS, factor $F, $S samples/clock -> [format %g [expr {$fs / $F}]] MS/s per channel
- converter AXIS [format %g $fabric] MHz, combined beat $beat_w b
- 100GbE UHD data plane: eth100g (udp_streamer, udp_player, axis_pkt_arb)" [current_bd_design]
}

# The rfdc hierarchy's stream glue, set from the geometry: one ADC I/Q
# merger per channel (rfdc/iq_merger_<c>, 16 x S bits per I or Q stream) and,
# for N > 1, the N-input axis_combiner and the N-output DAC axis_broadcaster
# (channel c = bits [c*W +: W] of the beat, W = beat_w / N). The glue is
# STATELESS, so the channels stay sample-aligned (MTS) by construction, as
# on the ZCU216 (RFDC -> axis_combiner) and the 4x2 (one packer): the
# merger's m_axis_tvalid depends on its m_axis_tready and the combiner's
# s_axis_tready on all its inputs' tvalid (a combinational loop), so for
# N > 1 every merger's m_axis_tready is tied to 1 (rfdc/iq_tready_one; the
# RFDC streams whatever the handshake says) and the combiner's s_axis_tready
# is left unused. No per-channel buffer: one would hold stale beats of the
# other channels while one tile's stream pauses (bring-up, the run-time
# factor change's SetupFIFO) and skew them for good.
# Only values that differ are written.
proc v49_stream_cells {nch} {
  set mergers {}
  for {set c 0} {$c < $nch} {incr c} {
    set m [get_bd_cells -quiet rfdc/iq_merger_$c]
    if {[llength $m] != 1} { error "v49: rfdc/iq_merger_$c missing" }
    lappend mergers $m
  }
  if {[llength [get_bd_cells -quiet rfdc/iq_merger_$nch]]} { error "v49: rfdc has more than $nch I/Q mergers" }
  if {$nch == 1} { return [list $mergers "" ""] }
  set comb [get_bd_cells -quiet rfdc/axis_combiner]
  set bcst [get_bd_cells -quiet rfdc/axis_broadcaster]
  if {[llength $comb] != 1 || [llength $bcst] != 1} { error "v49: rfdc/axis_combiner or rfdc/axis_broadcaster missing" }
  return [list $mergers $comb $bcst]
}

proc v49_converter_streams {nch S beat_w} {
  lassign [v49_stream_cells $nch] mergers comb bcst
  set w [expr {16 * $S}]
  foreach j $mergers {
    if {[get_property CONFIG.C_S_AXIS_TDATA_WIDTH $j] != $w} {
      puts "V49_GEOMETRY $j C_S_AXIS_TDATA_WIDTH $w"
      set_property CONFIG.C_S_AXIS_TDATA_WIDTH $w $j
    }
  }
  if {$nch == 1} return
  if {[get_property CONFIG.NUM_SI $comb] != $nch} { set_property CONFIG.NUM_SI $nch $comb }
  set cw [expr {$beat_w / $nch}]
  set want [list CONFIG.NUM_MI $nch CONFIG.S_TDATA_NUM_BYTES [expr {$beat_w / 8}] \
                 CONFIG.M_TDATA_NUM_BYTES [expr {$cw / 8}]]
  for {set c 0} {$c < $nch} {incr c} {
    lappend want CONFIG.M[format %02d $c]_TDATA_REMAP "tdata\[[expr {($c + 1) * $cw - 1}]:[expr {$c * $cw}]\]"
  }
  set cfg {}
  foreach {k v} $want { if {[get_property $k $bcst] ne $v} { lappend cfg $k $v } }
  if {[llength $cfg]} { puts "V49_GEOMETRY $bcst: $cfg"; set_property -dict $cfg $bcst }
}

# The part's converter tiles, {kind tile ...}: ADC tiles 0..3 (224..227, dual
# RF-ADC), DAC tiles 0..1 (228, 229); the IP refuses DAC tiles 2 and 3
proc v49_tiles {} { return {ADC 0 ADC 1 ADC 2 ADC 3 DAC 0 DAC 1} }

# The converter slices each channel streams (fpga/boards/zcu111/AGENTS.md,
# rfsoc/server/boards.py): channel c is ADC tile c / 2 converter k = c % 2
# (IP slices 2k = I and 2k+1 = Q; xrfdc API block k) and DAC tile c / 4
# slice c % 4 (= API block):
#   channel 0..3: ADC t0 k0, t0 k1, t1 k0, t1 k1 (vin0_01, vin0_23, vin1_01, vin1_23),
#                 DAC t0 slices 0..3 (vout00..vout03)
#   channel 4..7: ADC t2 k0, t2 k1, t3 k0, t3 k1, DAC t1 slices 0..3 (vout10..vout13)
proc v49_channel_slices {} {
  set d [dict create]
  for {set c 0} {$c < 8} {incr c} {
    set ta [expr {$c / 2}]
    set k [expr {$c % 2}]
    dict set d $c [list dac [expr {$c / 4}][expr {$c % 4}] adc_i $ta[expr {2 * $k}] adc_q $ta[expr {2 * $k + 1}]]
  }
  return $d
}

# Errors on any mismatch between the compiled block design and v49_geometry,
# and on anything the Gen1 part needs that the design relies on: a Gen1
# factor and the Data_Width on EVERY enabled ADC and DAC slice (16 + 8, no
# slice of the absent DAC tiles 2, 3), the channel slices enabled, on each of
# the six tiles MTS / sampling rate / tile PLL bypassed with Refclk = fs /
# its own clock pin (Clock_Source = itself, no Clock_Dist: Gen1 has no
# on-chip distribution) wired to the board port / Fabric_Freq, the PG269
# SYSREF rule for the 7.68 MHz SYSREF (it divides fs/16, PL_CLK and the
# fabric clock), the clock the BD propagates from MTS_clk_wiz, the stream glue
# (joiner widths and its ADC inputs, the DAC fan-out and remap), the eth100g
# widths / TICK_STEP / TX buffer / pass-through tie-offs, the beamformers
# (N >= 2) and the PS address map.
proc verify_rate_variant {F {nch 1}} {
  set g [v49_geometry $nch $F]
  dict with g {}
  if {$F ni [v49_gen1_factors]} { error "v49: factor $F is not a Gen1 factor ([v49_gen1_factors])" }
  set rfdc [get_bd_cells rfdc/usp_rf_data_converter]
  set nslice 0
  for {set t 0} {$t < 4} {incr t} {
    for {set b 0} {$b < 4} {incr b} {
      foreach {k mode dw} [list ADC Decimation $adc_dw DAC Interpolation $dac_dw] {
        set en [get_property -quiet CONFIG.${k}_Slice${t}${b}_Enable $rfdc]
        if {$en ne "true"} continue
        if {$k eq "DAC" && $t > 1} { error "v49: DAC slice $t$b enabled: the xczu28dr has DAC tiles 0 and 1 only" }
        incr nslice
        set v [get_property CONFIG.${k}_${mode}_Mode${t}${b} $rfdc]
        if {$v ne $F} { error "v49: ${k}_${mode}_Mode${t}${b} is '$v', expected $F on every tile and slice" }
        set v [get_property CONFIG.${k}_Data_Width${t}${b} $rfdc]
        if {$v ne $dw} { error "v49: ${k}_Data_Width${t}${b} is '$v', expected $dw on every slice" }
      }
    }
  }
  # every converter of the part on every build: the 16 ADC slices (8 dual
  # RF-ADCs in I/Q mode), the 8 DAC slices
  if {$nslice != 24} { error "v49: $nslice ADC + DAC slices enabled, expected 16 + 8" }
  foreach {k t} [v49_tiles] {
    if {[get_property CONFIG.${k}${t}_Enable $rfdc] != 1} { error "v49: ${k} tile $t is disabled" }
    if {[get_property CONFIG.${k}${t}_Multi_Tile_Sync $rfdc] ne "true"} { error "v49: ${k}${t}_Multi_Tile_Sync dropped to false" }
    set sr [get_property CONFIG.${k}${t}_Sampling_Rate $rfdc]
    if {abs($sr - $fs / 1000.0) > 1e-6} { error "v49: ${k}${t}_Sampling_Rate is $sr GS/s, expected [expr {$fs / 1000.0}]" }
    if {[get_property CONFIG.${k}${t}_PLL_Enable $rfdc] ne "false"} { error "v49: ${k}${t}_PLL_Enable is not false (the tiles take fs from the LMX2594s)" }
    set rc [get_property CONFIG.${k}${t}_Refclk_Freq $rfdc]
    if {abs($rc - $fs) > 1e-3} { error "v49: ${k}${t}_Refclk_Freq is $rc MHz with the tile PLL bypassed, expected fs $fs" }
    set v [get_property CONFIG.${k}${t}_Fabric_Freq $rfdc]
    if {abs($v - $fabric) > 0.01} { error "v49: ${k}${t}_Fabric_Freq is $v MHz, expected $fabric" }
    # Gen1: every tile on its own clock pin (ADC tile t = source t, DAC tile
    # t = source 4 + t), nothing distributed
    set want [expr {$k eq "ADC" ? $t : 4 + $t}]
    if {[get_property CONFIG.${k}${t}_Clock_Source $rfdc] != $want} { error "v49: ${k}${t}_Clock_Source is [get_property CONFIG.${k}${t}_Clock_Source $rfdc], expected $want (its own clock pin)" }
    if {[get_property CONFIG.${k}${t}_Clock_Dist $rfdc] != 0} { error "v49: ${k}${t}_Clock_Dist is [get_property CONFIG.${k}${t}_Clock_Dist $rfdc] (Gen1 has no clock distribution)" }
    set pin [string tolower $k]${t}_clk
    # the RFDC pin to the rfdc hierarchy pin (its inner net), that pin to the
    # board port (its outer net)
    set inner [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins rfdc/usp_rf_data_converter/$pin]]
    set outer [get_bd_intf_nets -quiet -of_objects [get_bd_intf_ports $pin]]
    if {$inner eq "" || $inner ne [get_bd_intf_nets -quiet -boundary_type lower -of_objects [get_bd_intf_pins rfdc/$pin]] || \
        $outer eq "" || $outer ne [get_bd_intf_nets -quiet -boundary_type upper -of_objects [get_bd_intf_pins rfdc/$pin]]} {
      error "v49: $pin is not wired from the board port to the RFDC (nets '$inner' / '$outer')"
    }
  }
  foreach t {2 3} {
    if {[get_property -quiet CONFIG.DAC${t}_Enable $rfdc] == 1} { error "v49: DAC tile $t enabled: the xczu28dr has DAC tiles 0 and 1 only" }
  }
  dict for {c sl} [v49_channel_slices] {
    if {$c >= $nch} continue
    dict with sl {}
    foreach {k s} [list DAC $dac ADC $adc_i ADC $adc_q] {
      if {[get_property CONFIG.${k}_Slice${s}_Enable $rfdc] ne "true"} { error "v49: channel $c needs ${k} slice $s, which is disabled" }
    }
  }
  # the MTS reference tiles are tile 0 of each kind: in every build
  foreach k {ADC DAC} {
    if {[get_property CONFIG.${k}0_Multi_Tile_Sync $rfdc] ne "true"} { error "v49: ${k} tile 0 (the MTS reference) is not synchronised" }
  }
  # PG269 (MTS): SYSREF an integer submultiple of fs/16 and of every clock
  # that samples it (PL_CLK, the converter AXIS clock); the ports carry the
  # family's PL_CLK and SYSREF
  set sysref [v49_sysref]
  set plclk [v49_pl_clk]
  foreach {what f} [list fs/16 [expr {$fs / 16.0}] PL_CLK $plclk fabric $fabric] {
    set q [expr {$f / $sysref}]
    if {abs($q - round($q)) > 1e-6} { error "v49: SYSREF $sysref MHz does not divide $what $f MHz" }
  }
  foreach {port mhz} [list PL_CLK $plclk PL_SYSREF $sysref] {
    set hz [get_property CONFIG.FREQ_HZ [get_bd_intf_ports $port]]
    if {abs($hz / 1e6 - $mhz) > 1e-6} { error "v49: port $port is [expr {$hz / 1e6}] MHz, expected $mhz" }
  }
  if {abs([get_property CONFIG.PRIM_IN_FREQ [get_bd_cells MTS_block/MTS_clk_wiz]] - $plclk) > 1e-6} { error "v49: MTS_clk_wiz input is not PL_CLK $plclk MHz" }
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
  # stream glue: one merger per channel on its I / Q slices, the merger
  # widths, for N > 1 the register slices, the combiner inputs in channel
  # order and the DAC fan-out with its remap
  lassign [v49_stream_cells $nch] mergers comb bcst
  set conv rfdc/usp_rf_data_converter
  set slices [v49_channel_slices]
  set ins {}
  for {set c 0} {$c < $nch} {incr c} {
    set j [lindex $mergers $c]
    if {[get_property CONFIG.C_S_AXIS_TDATA_WIDTH $j] != 16 * $S} { error "v49: $j C_S_AXIS_TDATA_WIDTH is [get_property CONFIG.C_S_AXIS_TDATA_WIDTH $j], expected [expr {16 * $S}]" }
    dict with slices $c {}
    lappend ins $j/s_i_axis $conv/m${adc_i}_axis $j/s_q_axis $conv/m${adc_q}_axis
    set cc [format %02d $c]
    if {$nch == 1} {
      lappend ins $j/m_axis rfdc/axis_register_slice_0/S_AXIS rfdc/axis_register_slice_1/M_AXIS $conv/s${dac}_axis
    } else {
      lappend ins $j/m_axis $comb/S${cc}_AXIS $bcst/M${cc}_AXIS $conv/s${dac}_axis
      # stateless: the merger's tready from the constant, nothing else
      set tr [get_bd_pins $j/m_axis_tready]
      set drv [get_bd_pins -quiet -of_objects [get_bd_nets -quiet -of_objects $tr] -filter {DIR == O}]
      if {[llength $drv] != 1 || [get_bd_cells -of_objects $drv] ne [get_bd_cells rfdc/iq_tready_one]} { error "v49: $j m_axis_tready is not tied to rfdc/iq_tready_one" }
    }
    if {[get_bd_cells -quiet rfdc/iq_slice_$c] ne ""} { error "v49: rfdc/iq_slice_$c: no per-channel buffer may sit in the ADC glue" }
  }
  if {$nch > 1} {
    lappend ins $comb/M_AXIS rfdc/axis_register_slice_0/S_AXIS rfdc/axis_register_slice_1/M_AXIS $bcst/S_AXIS
    if {[get_property CONFIG.NUM_SI $comb] != $nch} { error "v49: $comb NUM_SI is [get_property CONFIG.NUM_SI $comb], expected $nch" }
    if {[get_property CONFIG.NUM_MI $bcst] != $nch} { error "v49: $bcst NUM_MI is [get_property CONFIG.NUM_MI $bcst], expected $nch" }
    set cw [expr {$beat_w / $nch}]
    for {set c 0} {$c < $nch} {incr c} {
      set k M[format %02d $c]_TDATA_REMAP
      set v "tdata\[[expr {($c + 1) * $cw - 1}]:[expr {$c * $cw}]\]"
      if {[get_property CONFIG.$k $bcst] ne $v} { error "v49: $bcst $k is '[get_property CONFIG.$k $bcst]', expected $v" }
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
  # beamformers: N >= 2 only, sized to the row
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
  if {$nch > 1} {
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
  puts "V49_RATE verified (ZCU111): N=$nch fs $fs, Gen1 factor $F on all $nslice enabled slices (ADC Data_Width $adc_dw,\
        DAC $dac_dw), fabric $fabric MHz on every tile, clk_wiz $clk MHz, beat $beat_w b, TICK_STEP $tick_step,\
        TX buffer [dict get $tbuf TX_BUF_WORDS] words,\
        [expr {$nch > 1 ? "beamformers N_CH $nch PIPE $bf_pipe" : "no beamformers"}], 6 tiles own clock + PLL bypassed + MTS, SYSREF $sysref divides fs/16 / PL_CLK / fabric, PS address map as on ZCU216"
}

if {[info exists ::V49_DEFINE_ONLY] && $::V49_DEFINE_ONLY} { return }

################################################################
# Parameters
################################################################
if {![info exists ::V49_NCH]} { error "zcu111_uhd_v49_122m88: set V49_NCH (1, 2, 4 or 8) before sourcing" }
set v49_nch $::V49_NCH
if {![info exists ::V49_FACTOR] || $::V49_FACTOR eq ""} { set ::V49_FACTOR [dict get [v49_geometry $v49_nch] F] }
# (v49_geometry errors on an N or F it has no row for)
set v49_F [dict get [v49_geometry $v49_nch $::V49_FACTOR] F]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2021.1
set current_vivado_version [version -short]

# another release only through fpga/flow/build.tcl, which sets V49_VIVADO
# (a release of fpga/flow/versions.txt) and maps the IP versions (v49_vlnv)
if { [string first $scripts_vivado_version $current_vivado_version] == -1 && ![info exists ::V49_VIVADO] } {
   puts ""
   catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}
   error "zcu111_uhd_v49_122m88: Vivado $current_vivado_version: build it through fpga/flow/build.tcl (make -C fpga BOARD=<board> PYNQ=<version>)"
}

################################################################
# START
################################################################
set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xczu28dr-ffvg1517-2-e
}
# ZCU111 ONLY: a netlist for another package or die would build without complaint.
if { [get_property PART [current_project]] ne "xczu28dr-ffvg1517-2-e" } {
   error "zcu111_uhd_v49_122m88 targets the ZCU111 (xczu28dr-ffvg1517-2-e), not [get_property PART [current_project]]"
}

variable design_name
set design_name zcu111_v49_${v49_nch}ch_qsfp
if { [get_files -quiet ${design_name}.bd] ne "" } {
   error "Design <$design_name> already exists in the project"
}
create_bd_design $design_name
current_bd_design $design_name

##################################################################
# CHECK IPs
##################################################################
# (the VLNVs as the flow's v49_vlnv maps them for the running release;
# sourced without the flow, as written)
if {[info commands v49_vlnv] eq ""} { proc v49_vlnv {vlnv} { return $vlnv } }
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
xilinx.com:ip:axis_combiner:1.1
xilinx.com:ip:usp_rf_data_converter:2.5
xilinx.com:ip:xlconstant:1.1
xilinx.com:ip:xlslice:1.0
user.org:user:dual_rf_adc_iq_merger:1.0
user.org:uhd:udp_streamer:1.0
user.org:uhd:udp_player:1.0
user.org:uhd:axis_pkt_arb:1.0
user.org:uhd:ch_interleave:1.0
user.org:uhd:tx_beamformer:1.0
user.org:uhd:rx_beamformer:1.0
}
set list_ips_missing {}
foreach ip_vlnv $list_check_ips {
   if { [get_ipdefs -all [v49_vlnv $ip_vlnv]] eq "" } { lappend list_ips_missing $ip_vlnv }
}
if { $list_ips_missing ne "" } {
   error "zcu111_uhd_v49_122m88: IPs not in the catalog: $list_ips_missing (user.org:uhd:*: run 'make package' in fpga/ip/src/uhd_ip and add fpga/ip/repo/uhd_ip to ip_repo_paths; the I/Q merger: fpga/ip/repo)"
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
  set BUFG_PL_CLK [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:util_ds_buf:2.2] BUFG_PL_CLK ]
  set_property -dict [ list \
   CONFIG.C_BUF_TYPE {BUFG} \
 ] $BUFG_PL_CLK

  # Create instance: IBUFDS_PL_CLK, and set properties
  set IBUFDS_PL_CLK [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:util_ds_buf:2.2] IBUFDS_PL_CLK ]
  set_property -dict [ list \
   CONFIG.C_BUF_TYPE {IBUFDS} \
 ] $IBUFDS_PL_CLK

  # Create instance: IBUFDS_SYSREF, and set properties
  set IBUFDS_SYSREF [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:util_ds_buf:2.2] IBUFDS_SYSREF ]
  set_property -dict [ list \
   CONFIG.C_BUF_TYPE {IBUFDS} \
 ] $IBUFDS_SYSREF

  # Create instance: MTS_clk_wiz, and set properties
  # USE_DYN_RECONFIG: the daemon retunes clk_out1 (the converter AXIS clock)
  # at run time over s_axi_lite (register file at 0x200, shared with the
  # clock monitor), so one bitstream serves every factor F of its row. The
  # build is timed at the clk_out1 it is generated with: the highest.
  set MTS_clk_wiz [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:clk_wiz:6.0] MTS_clk_wiz ]
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

# Hierarchical cell: rfdc -- the RF data converter (every RF-ADC of the four
# dual tiles in I/Q mode, every RF-DAC: the four slices of each of the two
# DAC tiles) and its combined converter streams (channel map:
# v49_channel_slices).
# M_ADC_AXIS: each channel's I/Q pair joined into complex 32-bit slots, I low,
# by rfdc/iq_merger_<c>; N > 1: straight into the axis_combiner,
# channel-major (channel c = S<c>_AXIS), stateless (v49_stream_cells).
# S_DAC_AXIS: N = 1 straight to channel 0's DAC; N > 1 split by the
# axis_broadcaster (M<c>_AXIS = channel c, bits [c*W +: W]). Both through an
# axis_register_slice.
# Tile clocks: Gen1 has no on-chip clock distribution, and the ZCU111 wires
# one LMX2594 output to each tile's clock pin (fpga/boards/zcu111/AGENTS.md):
# adc0_clk .. adc3_clk, dac0_clk, dac1_clk, each its own tile's
# (<k><t>_Clock_Source = the tile itself, the IP's Gen1 default).
proc create_hier_cell_rfdc { parentCell nameHier nch } {
  set oldCurInst [current_bd_instance .]
  current_bd_instance [get_bd_cells $parentCell]
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_ADC_AXIS
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_DAC_AXIS
  foreach c [v49_tile_clks] {
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 $c
  }
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
  # synchronized to PL SYSREF. RFDC clk_adc<t>/clk_dac<t> are only converter
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

  set v49c [v49_rfdc_creation $nch $::V49_FACTOR]
  set S [dict get $v49c S]
  set slices [v49_channel_slices]

  # ADC: one I/Q merger per channel (a dual RF-ADC emits simultaneous,
  # continuously-valid I and Q streams; the merger keeps both RFDC TREADY
  # inputs high and interleaves {Q[S-1],I[S-1],...,Q0,I0})
  set acells {}
  for {set c 0} {$c < $nch} {incr c} {
    set j [ create_bd_cell -type ip -vlnv user.org:user:dual_rf_adc_iq_merger:1.0 iq_merger_$c ]
    set_property -dict [list CONFIG.C_S_AXIS_TDATA_WIDTH [expr {16 * $S}]] $j
    lappend acells iq_merger_$c
  }
  set dcells {}
  if {$nch > 1} {
    # widths and remaps: v49_converter_streams (apply_geometry)
    set axis_combiner [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axis_combiner:1.1] axis_combiner ]
    set_property CONFIG.NUM_SI $nch $axis_combiner
    set axis_broadcaster [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axis_broadcaster:1.1] axis_broadcaster ]
    set_property CONFIG.NUM_MI $nch $axis_broadcaster
    lappend acells axis_combiner
    lappend dcells axis_broadcaster
    # every merger's m_axis_tready (v49_stream_cells: no handshake loop)
    set one [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xlconstant:1.1] iq_tready_one ]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $one
  }

  # Create instance: axis_register_slice_0 (ADC) and _1 (DAC)
  create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axis_register_slice:1.1] axis_register_slice_0
  create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axis_register_slice:1.1] axis_register_slice_1
  lappend acells axis_register_slice_0
  lappend dcells axis_register_slice_1

  # Create instance: usp_rf_data_converter, and set properties
  # The rfdc is created at the build's geometry (v49_rfdc_creation): fs =
  # V49_FS on every tile with the tile PLLs bypassed (Refclk = fs), factor
  # V49_FACTOR and the Data_Width of S samples/clock on every slice, and the
  # Fabric/Outclk values they imply. The per-slice settings are the other
  # boards' (the ZCU208 / RFSoC 4x2 data path): I/Q data, fine mixer, DAC
  # inverse sinc on; but for two Gen1 parameters left at the IP's values:
  # ADC_CalOpt_Mode (Gen1 takes 0 / 1 on converter slices 0 and 2 only, not
  # the Gen3 designs' 2; default 1) and DAC_Coarse_Mixer_Freq (disabled with
  # the fine mixer on Gen1).
  # Clock_Source / Clock_Dist are left at the IP's Gen1 values (each tile its
  # own pin, nothing distributed; verify_rate_variant checks them). DAC
  # output current: the IP default (DAC_Output_Current 0, 20 mA).
  set usp_rf_data_converter [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:usp_rf_data_converter:2.5] usp_rf_data_converter ]
  set cfg {}
  foreach {k t} [v49_tiles] {
    lappend cfg CONFIG.${k}${t}_Enable 1 CONFIG.${k}${t}_PLL_Enable false \
        CONFIG.${k}${t}_Refclk_Freq [dict get $v49c fs_mhz] \
        CONFIG.${k}${t}_Sampling_Rate [dict get $v49c fs_gsps] \
        CONFIG.${k}${t}_Fabric_Freq [dict get $v49c fabric_s] \
        CONFIG.${k}${t}_Outclk_Freq [dict get $v49c outclk_s] \
        CONFIG.${k}${t}_Multi_Tile_Sync true
  }
  for {set t 0} {$t < 4} {incr t} {
    for {set s 0} {$s < 4} {incr s} {
      lappend cfg CONFIG.ADC_Slice${t}${s}_Enable true CONFIG.ADC_Data_Type${t}${s} 1 \
          CONFIG.ADC_Decimation_Mode${t}${s} [dict get $v49c F] \
          CONFIG.ADC_Data_Width${t}${s} [dict get $v49c adc_dw] \
          CONFIG.ADC_Mixer_Type${t}${s} 2 CONFIG.ADC_Mixer_Mode${t}${s} 0 \
          CONFIG.ADC_Coarse_Mixer_Freq${t}${s} 0
    }
    foreach s {0 2} { lappend cfg CONFIG.ADC_RESERVED_1_${t}${s} false }
  }
  for {set t 0} {$t < 2} {incr t} {
    for {set s 0} {$s < 4} {incr s} {
      lappend cfg CONFIG.DAC_Slice${t}${s}_Enable true \
          CONFIG.DAC_Interpolation_Mode${t}${s} [dict get $v49c F] \
          CONFIG.DAC_Data_Width${t}${s} [dict get $v49c dac_dw] \
          CONFIG.DAC_Mixer_Type${t}${s} 2 CONFIG.DAC_Mixer_Mode${t}${s} 0 \
          CONFIG.DAC_Invsinc_Ctrl${t}${s} true \
          CONFIG.DAC_RESERVED_1_${t}${s} false
    }
  }
  set_property -dict $cfg $usp_rf_data_converter

  # Create interface connections
  foreach c [v49_tile_clks] {
    connect_bd_intf_net -intf_net ${c}_1 [get_bd_intf_pins $c] [get_bd_intf_pins usp_rf_data_converter/$c]
  }
  connect_bd_intf_net -intf_net s_axi_1 [get_bd_intf_pins s_axi] [get_bd_intf_pins usp_rf_data_converter/s_axi]
  connect_bd_intf_net -intf_net sysref_in_1 [get_bd_intf_pins sysref_in] [get_bd_intf_pins usp_rf_data_converter/sysref_in]
  foreach v [concat [v49_vins] [v49_vouts]] {
    connect_bd_intf_net -intf_net rfdc_$v [get_bd_intf_pins $v] [get_bd_intf_pins usp_rf_data_converter/$v]
  }
  connect_bd_intf_net -intf_net S_DAC_AXIS_1 [get_bd_intf_pins S_DAC_AXIS] [get_bd_intf_pins axis_register_slice_1/S_AXIS]
  connect_bd_intf_net -intf_net axis_register_slice_0_M_AXIS [get_bd_intf_pins M_ADC_AXIS] [get_bd_intf_pins axis_register_slice_0/M_AXIS]
  # converter streams (v49_channel_slices)
  for {set c 0} {$c < $nch} {incr c} {
    dict with slices $c {}
    set cc [format %02d $c]
    connect_bd_intf_net -intf_net adc_ch${c}_i_axis [get_bd_intf_pins iq_merger_$c/s_i_axis] [get_bd_intf_pins usp_rf_data_converter/m${adc_i}_axis]
    connect_bd_intf_net -intf_net adc_ch${c}_q_axis [get_bd_intf_pins iq_merger_$c/s_q_axis] [get_bd_intf_pins usp_rf_data_converter/m${adc_q}_axis]
    if {$nch == 1} {
      connect_bd_intf_net -intf_net iq_merger_0_m_axis [get_bd_intf_pins iq_merger_0/m_axis] [get_bd_intf_pins axis_register_slice_0/S_AXIS]
      connect_bd_intf_net -intf_net axis_register_slice_1_M_AXIS [get_bd_intf_pins axis_register_slice_1/M_AXIS] [get_bd_intf_pins usp_rf_data_converter/s${dac}_axis]
    } else {
      connect_bd_intf_net -intf_net iq_merger_${c}_m_axis [get_bd_intf_pins iq_merger_$c/m_axis] [get_bd_intf_pins axis_combiner/S${cc}_AXIS]
      connect_bd_intf_net -intf_net axis_broadcaster_M${cc}_AXIS [get_bd_intf_pins axis_broadcaster/M${cc}_AXIS] [get_bd_intf_pins usp_rf_data_converter/s${dac}_axis]
    }
  }
  if {$nch > 1} {
    connect_bd_intf_net -intf_net axis_combiner_M_AXIS [get_bd_intf_pins axis_combiner/M_AXIS] [get_bd_intf_pins axis_register_slice_0/S_AXIS]
    set tr {}
    for {set c 0} {$c < $nch} {incr c} { lappend tr [get_bd_pins iq_merger_$c/m_axis_tready] }
    connect_bd_net -net iq_tready_one_dout [get_bd_pins iq_tready_one/dout] {*}$tr
    connect_bd_intf_net -intf_net axis_register_slice_1_M_AXIS [get_bd_intf_pins axis_broadcaster/S_AXIS] [get_bd_intf_pins axis_register_slice_1/M_AXIS]
  }

  # Create port connections
  set aclk [list [get_bd_pins adc_axis_clk]]
  set arst [list [get_bd_pins adc_axis_aresetn]]
  foreach c $acells {
    set ck [get_bd_pins -quiet $c/aclk]
    if {$ck eq ""} { set ck [get_bd_pins $c/axis_aclk] }
    set rs [get_bd_pins -quiet $c/aresetn]
    if {$rs eq ""} { set rs [get_bd_pins $c/axis_aresetn] }
    lappend aclk $ck
    lappend arst $rs
  }
  set dclk [list [get_bd_pins dac_axis_clk]]
  set drst [list [get_bd_pins dac_axis_aresetn]]
  foreach c $dcells {
    lappend dclk [get_bd_pins $c/aclk]
    lappend drst [get_bd_pins $c/aresetn]
  }
  foreach {k t} [v49_tiles] {
    if {$k eq "ADC"} {
      lappend aclk [get_bd_pins usp_rf_data_converter/m${t}_axis_aclk]
      lappend arst [get_bd_pins usp_rf_data_converter/m${t}_axis_aresetn]
    } else {
      lappend dclk [get_bd_pins usp_rf_data_converter/s${t}_axis_aclk]
      lappend drst [get_bd_pins usp_rf_data_converter/s${t}_axis_aresetn]
    }
  }
  foreach l [list $aclk $arst $dclk $drst] {
    if {[lsearch -exact $l ""] >= 0} { error "v49: an rfdc AXIS clock / reset pin is missing" }
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

# The RFDC's analog pins: both inputs of each dual RF-ADC tile, the four
# outputs of each of the two RF-DAC tiles; and the six tile clock inputs
proc v49_vins {} { return {vin0_01 vin0_23 vin1_01 vin1_23 vin2_01 vin2_23 vin3_01 vin3_23} }
proc v49_vouts {} { return {vout00 vout01 vout02 vout03 vout10 vout11 vout12 vout13} }
proc v49_tile_clks {} { return {adc0_clk adc1_clk adc2_clk adc3_clk dac0_clk dac1_clk} }

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

  foreach c [v49_tile_clks] {
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 $c
  }

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
  create_bd_port -dir O -from 7 -to 0 led

  # Create instance: MTS_block
  create_hier_cell_MTS_block [current_bd_instance .] MTS_block

  # Create instance: adc_clk_aresetn, and set properties
  set adc_clk_aresetn [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:proc_sys_reset:5.0] adc_clk_aresetn ]

  # Create instance: axi_gpio_led, and set properties
  set axi_gpio_led [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axi_gpio:2.0] axi_gpio_led ]
  set_property -dict [ list \
   CONFIG.C_ALL_OUTPUTS {1} \
   CONFIG.C_GPIO_WIDTH {8} \
   CONFIG.C_IS_DUAL {0} \
   CONFIG.GPIO_BOARD_INTERFACE {Custom} \
   CONFIG.USE_BOARD_FLOW {true} \
 ] $axi_gpio_led

  # Create instance: axi_interconnect_pl -- the PL control smartconnect:
  # M00 rfdc, M01 axi_gpio_led, M02 MTS_clk_wiz, M03 axi_intp, then the
  # eth100g slaves (v49_eth100g_slaves)
  set slaves [v49_eth100g_slaves $nch]
  set axi_interconnect_pl [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:smartconnect:1.0] axi_interconnect_pl ]
  set_property -dict [ list \
   CONFIG.NUM_MI [expr {4 + [llength $slaves]}] \
   CONFIG.NUM_SI {1} \
 ] $axi_interconnect_pl

  # Create instance: axi_intp, and set properties
  set axi_intp [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:axi_intc:4.1] axi_intp ]

  # Create instance: dac_adc_clk_aresetn, and set properties
  set dac_adc_clk_aresetn [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:proc_sys_reset:5.0] dac_adc_clk_aresetn ]

  # Create instance: intp_concat -- In0 MTS_clk_wiz, In1 rfdc
  set intp_concat [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xlconcat:2.1] intp_concat ]
  set_property -dict [ list \
   CONFIG.NUM_PORTS {2} \
 ] $intp_concat

  # Create instance: proc_sys_reset_pl, and set properties
  set proc_sys_reset_pl [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:proc_sys_reset:5.0] proc_sys_reset_pl ]

  # Create instance: rfdc
  create_hier_cell_rfdc [current_bd_instance .] rfdc $nch

  # Synchronize PL SYSREF independently into the ADC and DAC MTS AXIS domains.
  set SYSREF_sync_adc [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xpm_cdc_gen:1.0] SYSREF_sync_adc ]
  set_property -dict [ list \
   CONFIG.CDC_TYPE {xpm_cdc_single} \
   CONFIG.DEST_SYNC_FF {2} \
   CONFIG.INIT_SYNC_FF {true} \
   CONFIG.WIDTH {1} \
 ] $SYSREF_sync_adc

  set SYSREF_sync_dac [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:xpm_cdc_gen:1.0] SYSREF_sync_dac ]
  set_property -dict [ list \
   CONFIG.CDC_TYPE {xpm_cdc_single} \
   CONFIG.DEST_SYNC_FF {2} \
   CONFIG.INIT_SYNC_FF {true} \
   CONFIG.WIDTH {1} \
 ] $SYSREF_sync_dac

  # Create instance: eth100g -- the 100GbE / UHD data plane
  create_hier_cell_eth100g [current_bd_instance .] eth100g $nch [dict get $g beat_w] [dict get $g bf_pipe]

  # Create instance: zynq_ultra_ps_e, and set properties
  set zynq_ultra_ps_e [ create_bd_cell -type ip -vlnv [v49_vlnv xilinx.com:ip:zynq_ultra_ps_e:3.3] zynq_ultra_ps_e ]
  # The ZCU111's PS: Vivado's board preset (DDR4 SODIMM, MIO, peripherals;
  # board part xilinx.com:zcu111:part0:1.4, the ZCU216's PS but for the DDR4
  # timing: fpga/boards/zcu111/AGENTS.md),
  # then the PL side this design uses: one master port, HPM0_LPD (M_AXI_GP2,
  # 128 bit; the register map at 0x8000_0000 is in its window), pl_clk0 =
  # 100 MHz from the IOPLL (s_axi / CMAC init clock), one fabric reset, IRQ0/1.
  if {[get_property BOARD_PART [current_project]] ne "xilinx.com:zcu111:part0:1.4"} {
     error "zcu111_uhd_v49_122m88: the project needs BOARD_PART xilinx.com:zcu111:part0:1.4, not '[get_property BOARD_PART [current_project]]'"
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
  foreach c [v49_tile_clks] {
    connect_bd_intf_net -intf_net ${c}_0_1 [get_bd_intf_ports $c] [get_bd_intf_pins rfdc/$c]
  }
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
  # the eight user LEDs (GPIO_LED_0..7, the board's led_8bits; pins in the XDC)
  connect_bd_net -net axi_gpio_led_gpio_io_o [get_bd_ports led] [get_bd_pins axi_gpio_led/gpio_io_o]
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
  # (v49_gen_top in fpga/flow/build.tcl)
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
