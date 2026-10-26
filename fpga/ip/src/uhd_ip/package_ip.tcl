# package_ip.tcl -- package the UHD / 100GbE data-plane cores as Vivado IP
# into fpga/ip/repo/uhd_ip (the repo every board's block designs import).
#
#   cd fpga/ip/src/uhd_ip
#   vivado -mode batch -nojournal -notrace -source package_ip.tcl [-tclargs <repo_dir>]
#   (or: make package)
#
# Every core is packaged straight from src/<core>.v (Verilog-2001, XPM macros;
# tx_beamformer also carries the beamformer_1.0 datapath it instantiates,
# src/beamformer_v1_0.sv and src/beamformer_channel.sv) as user.org:uhd:<core>:1.0; its HDL is copied into the IP
# (<repo>/<core>_1.0/src), so the repo is self-contained. The bus interfaces
# are inferred from the X_INTERFACE_INFO attributes and port names, and this
# script refuses to save a core whose interfaces, parameters or AXI-Lite
# address block differ from what zcu216_uhd_v49.tcl connects to (the names the cores
# had as module references). Re-run it after every change under src/ and
# commit src/ and the repo together.
set here [file normalize [file dirname [info script]]]
set repo [file normalize [expr {$argc > 0 ? [lindex $argv 0] : "$here/../../repo/uhd_ip"}]]
set part xczu49dr-ffvf1760-2-e

# core -> {description, bus interfaces, user parameters}
set cores [dict create \
  udp_streamer [list \
    "RFDC ADC samples -> Ethernet/IPv4/UDP/VRT frames for a 100G CMAC: timekeeper, stream commands, over-the-wire format conversion (sc16/sc8/sc12/fc32). Register map in the HDL header; wire format: the Protocol (top AGENTS.md)." \
    {s_axis m_axis_adc m_axis s_axi adc_clk tx_clk s_axi_aclk adc_aresetn tx_aresetn s_axi_aresetn} \
    {DATA_FIFO_DEPTH TICK_STEP S_WIDTH}] \
  udp_player [list \
    "Host UDP/VRT sample packets from a 100G CMAC -> RFDC DAC: URAM buffer (+ optional block-RAM play-out chain), timed playout, flow control, ARP and async status, over-the-wire format conversion (sc16/sc8/sc12/fc32). Register map in the HDL header; wire format: the Protocol (top AGENTS.md)." \
    {s_axis_rx m_axis_ctl s_axis_dma m_axis_dac s_axi tx_clk adc_clk s_axi_aclk tx_aresetn adc_aresetn s_axi_aresetn} \
    {TX_BUF_WORDS TX_BUF_RESERVE META_DEPTH XFER_DEPTH CHAIN_STAGES CHAIN_DEPTH URAM_RD_LATENCY TICK_STEP M_WIDTH}] \
  axis_pkt_arb [list \
    "Two-input 512-bit AXI-Stream packet arbiter for the CMAC TX (no bubbles inside a frame, s1 wins at packet boundaries)." \
    {s0_axis s1_axis m_axis clk aresetn} \
    {REG_OUT}] \
  ch_interleave [list \
    "Re-orders the 32-bit slots of an AXI-Stream beat between channel-major (axis_combiner/broadcaster) and sample-major (UDP wire) order." \
    {s_axis m_axis aclk} \
    {N_CH BEAT_W DIR REG}] \
  tx_beamformer [list \
    "TX beamformer on the channel-major DAC beat: TX channel 0 fanned out to N DACs, DAC c = ch0 x w_c (Q1.15), or bit-exact bypass; atomic weight LOAD. Register map in the HDL header; Protocol §11." \
    {s_axis m_axis s_axi aclk s_axi_aclk aresetn s_axi_aresetn} \
    {N_CH BEAT_W PIPE}] \
  rx_beamformer [list \
    "RX beamformer on the channel-major ADC beat: channel 0 = sat16(round(sum over c of x_c w_c >> (15+SHIFT))), channels 1..N-1 unchanged, or bit-exact bypass; atomic weight/shift LOAD. Register map in the HDL header; Protocol §11." \
    {s_axis m_axis s_axi aclk s_axi_aclk aresetn s_axi_aresetn} \
    {N_CH BEAT_W}] \
]
# extra HDL a core instantiates (copied into the IP with its own source)
set extra [dict create \
  tx_beamformer [list $here/src/beamformer_v1_0.sv \
                      $here/src/beamformer_channel.sv]]

file mkdir $repo
set tmp [file normalize $here/.pkg_tmp]
foreach name [dict keys $cores] {
  lassign [dict get $cores $name] desc want_if want_par
  set root $repo/${name}_1.0
  file delete -force $root $tmp
  create_project -force pkg_$name $tmp -part $part
  add_files -norecurse $here/src/$name.v
  if {[dict exists $extra $name]} { add_files -norecurse [dict get $extra $name] }
  set_property top $name [current_fileset]
  update_compile_order -fileset sources_1
  ipx::package_project -root_dir $root -vendor user.org -library uhd -taxonomy /UHD \
      -import_files -set_current true -force
  set core [ipx::current_core]
  set_property -dict [list \
      version 1.0 core_revision 1 \
      display_name $name description $desc \
      vendor_display_name {uhd-rfsoc} company_url {} \
      supported_families {zynquplus Production}] $core

  # the boundary zcu216_uhd_v49.tcl relies on
  set got_if [lsort [get_property NAME [ipx::get_bus_interfaces -of_objects $core]]]
  if {$got_if ne [lsort $want_if]} {
    error "$name: bus interfaces {$got_if}, want {[lsort $want_if]}"
  }
  set got_par [lsort [get_property NAME [ipx::get_user_parameters -of_objects $core]]]
  foreach p $want_par {
    if {[lsearch -exact $got_par $p] < 0} { error "$name: user parameter $p missing ({$got_par})" }
  }
  if {[lsearch -exact $want_if s_axi] >= 0} {
    set blk [get_property NAME [ipx::get_address_blocks -of_objects \
                 [ipx::get_memory_maps s_axi -of_objects $core]]]
    if {$blk ne "reg0"} { error "$name: s_axi address block '$blk', zcu216_uhd_v49.tcl uses reg0" }
  }

  ipx::create_xgui_files $core
  ipx::update_checksums $core
  ipx::check_integrity $core
  ipx::save_core $core
  puts "UHD_IP_PACKAGED [get_property VLNV $core] -> $root  interfaces {$got_if}"
  ipx::unload_core [get_property VLNV $core]
  close_project
  file delete -force $tmp
}
puts "UHD_IP_PACKAGE_PASS repo=$repo"
