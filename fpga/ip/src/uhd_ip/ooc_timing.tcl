# ooc_timing.tcl -- out-of-context synthesis + place + route of udp_streamer,
# udp_player or tx_dpd, and a timing summary, on the ZCU216 part.
#
#   cd fpga/ip/src/uhd_ip   (or: make ooc)
#   vivado -mode batch -nojournal -source ooc_timing.tcl \
#          -tclargs <udp_streamer|udp_player|tx_dpd> <width> <adc_mhz> [outdir] [NAME=value ...]
#
# Extra NAME=value arguments are passed to synth_design as generics (e.g.
# TX_BUF_WORDS=32768 for the 2 MiB TX buffer, N_CH=4 for tx_dpd, whose
# <width> is BEAT_W and whose converter clock port is aclk).
#
# Clocks: adc_clk at <adc_mhz> (312.5 at the templates: a 128, 256 or
# 512-bit beat per cycle), tx_clk = CMAC user clock 322.265625 MHz,
# s_axi_aclk 100 MHz, all mutually asynchronous (every crossing is an XPM CDC
# primitive or async FIFO, which carry their own constraints). The I/O ports
# are left unconstrained: this checks the register-to-register paths inside
# the module, including the over-the-wire format converters.
set mod    [lindex $argv 0]
set width  [lindex $argv 1]
set adcmhz [lindex $argv 2]
set out    [expr {[llength $argv] > 3 ? [lindex $argv 3] : "ooc_${mod}_w${width}"}]
set here   [file normalize [file dirname [info script]]]
set src    [file normalize $here/src]
file mkdir $out

if {$mod eq "tx_dpd"} {
  set gen [list -generic BEAT_W=$width]
  read_verilog -sv [lsort [glob $src/dpd_*.sv]]
} else {
  set wparam [expr {$mod eq "udp_streamer" ? "S_WIDTH" : "M_WIDTH"}]
  set gen [list -generic $wparam=$width -generic TICK_STEP=1]
}
foreach g [lrange $argv 4 end] { lappend gen -generic $g }
read_verilog $src/$mod.v
synth_design -top $mod -part xczu49dr-ffvf1760-2-e -mode out_of_context {*}$gen

set cports [expr {$mod eq "tx_dpd" ? {aclk} : {adc_clk tx_clk}}]
create_clock -name adc_clk -period [format %.4f [expr {1000.0 / $adcmhz}]] [get_ports [lindex $cports 0]]
create_clock -name axi_clk -period 10.000 [get_ports s_axi_aclk]
if {$mod eq "tx_dpd"} {
  set_clock_groups -asynchronous -group adc_clk -group axi_clk
} else {
  create_clock -name tx_clk -period 3.1030 [get_ports tx_clk]
  set_clock_groups -asynchronous -group adc_clk -group tx_clk -group axi_clk
}

report_utilization -file $out/util_synth.rpt
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_utilization -file $out/util.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
foreach clk [get_property NAME [get_clocks]] {
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup -group $clk]
    puts "OOC_CLK $mod w=$width $clk WNS=[get_property SLACK $p]"
}
puts "OOC_RESULT $mod w=$width adc=${adcmhz}MHz [lrange $argv 4 end] WNS=$wns WHS=$whs"
