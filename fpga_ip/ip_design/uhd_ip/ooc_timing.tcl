# ooc_timing.tcl -- out-of-context synthesis + place + route of udp_streamer
# or udp_player, and a timing summary, on the ZCU216 part.
#
#   cd hw_design/ip_design/uhd_ip   (or: make ooc)
#   vivado -mode batch -nojournal -source ooc_timing.tcl \
#          -tclargs <udp_streamer|udp_player> <width> <adc_mhz> [outdir] [NAME=value ...]
#
# Extra NAME=value arguments are passed to synth_design as generics (e.g.
# TX_BUF_WORDS=32768 for the 2 MiB TX buffer).
#
# Clocks: adc_clk at <adc_mhz> (300 for the 128/256-bit builds and for the
# 512-bit max-rate builds, one 16-slot group per cycle), tx_clk = CMAC user clock 322.265625 MHz,
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

set wparam [expr {$mod eq "udp_streamer" ? "S_WIDTH" : "M_WIDTH"}]
set gen [list -generic $wparam=$width -generic TICK_STEP=1]
foreach g [lrange $argv 4 end] { lappend gen -generic $g }
read_verilog $src/$mod.v
synth_design -top $mod -part xczu49dr-ffvf1760-2-e -mode out_of_context {*}$gen

create_clock -name adc_clk -period [format %.4f [expr {1000.0 / $adcmhz}]] [get_ports adc_clk]
create_clock -name tx_clk  -period 3.1030 [get_ports tx_clk]
create_clock -name axi_clk -period 10.000 [get_ports s_axi_aclk]
set_clock_groups -asynchronous -group adc_clk -group tx_clk -group axi_clk

report_utilization -file $out/util_synth.rpt
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_utilization -file $out/util.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
foreach clk {adc_clk tx_clk axi_clk} {
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup -group $clk]
    puts "OOC_CLK $mod w=$width $clk WNS=[get_property SLACK $p]"
}
puts "OOC_RESULT $mod w=$width adc=${adcmhz}MHz [lrange $argv 4 end] WNS=$wns WHS=$whs"
