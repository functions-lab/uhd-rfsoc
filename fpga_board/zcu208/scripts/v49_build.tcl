# v49_build.tcl (ZCU208) -- build zcu208_v49_<N>ch_qsfp (ZCU208 as a UHD device
# over 100 GbE), N = 1, 2. This board's own copy of the ZCU216 flow
# (hw_design/ZCU208/CLAUDE.md: nothing is shared between the two boards' flows).
# `make v49 N=<N> F=<F>` / `make v49-ladder` in hw_design/ZCU208 call it; directly:
#
#   cd hw_design/ZCU208
#   vivado -mode batch -nojournal -nolog -source scripts/v49_build.tcl \
#          -tclargs <N> [bd|synth|bit|impl] [jobs] [factor] [fs]
#
#   bd     block design only (validates it and runs every v49 check)
#   synth  + synthesis
#   bit    + implementation and bitstream (default)
#   impl   continue an existing synthesized project to a bitstream
#
# Inputs (hw_design rule: a block-design directory holds only its .tcl and .xdc):
#   block_designs/zcu208_uhd_v49/zcu208_uhd_v49.{tcl,xdc}   the design, every N
#                                                   (self-contained: geometry, data plane, checks)
#   ../ip/uhd_ip                                    packaged cores (`make package` in
#                                                   ../ip_design/uhd_ip first)
#   ../ip/iprepo/dual_rf_adc_iq_merger_1.0,
#   ../ip/iprepo/dual_channel_rf_adc_iq_packer_1.0  the dual RF-ADC I/Q joiners (N = 1, 2)
#   ../ip_design/cmac_100g                          CMAC + split-quad GT wrapper RTL
# Output: build/v49_qsfp/bitstreams/zcu208_v49_<N>ch_qsfp_f<F>_fs<fs>.{bit,hwh}
#         (the deploy set; a build that misses timing goes to
#         bitstreams_timing_fail/), with its timing and utilization reports.
#         The Vivado project (build/v49_qsfp/<name>_proj) is deleted once the
#         bitstream is out unless V49_KEEP_PROJ=1 is in the environment.
#
# factor = RFDC converter factor, a v49_geometry row of zcu208_uhd_v49.tcl
# (default: that N's first row); fs = converter sample rate in MS/s (default
# 5000, the dual RF-ADC's maximum). The builds: normal family 1ch F2..40 and
# 2ch F4..40, sc8max 2ch F2, all at fs 5000 (scripts/v49_ladder.sh). A build is
# named ..._fs<fs> for fs != 2400 and needs
# rfsoc_lib/xrfclk/ZCU208/LMX2594_250.0_<fs>.0.txt on the board.

set scripts     [file dirname [file normalize [info script]]]
set zcu208      [file normalize $scripts/..]
set hwd         [file normalize $zcu208/../../fpga_ip]
if {$argc < 1} { error "usage: v49_build.tcl -tclargs <N> [bd|synth|bit|impl] [jobs] [factor] [fs]" }
set V49_NCH     [lindex $argv 0]
set here        $zcu208/block_designs/zcu208_uhd_v49
set outdir      $zcu208/build/v49_qsfp
if {![file exists $here]} { error "no design directory $here" }
set V49_FS      [expr {$argc > 4 ? double([lindex $argv 4]) : 5000.0}]
# the design's procs only (v49_geometry: the factor names the build)
set V49_DEFINE_ONLY 1
source $here/zcu208_uhd_v49.tcl
unset V49_DEFINE_ONLY
set design_name zcu208_v49_${V49_NCH}ch_qsfp
set step        [expr {$argc > 1 ? [lindex $argv 1] : "bit"}]
set jobs        [expr {$argc > 2 ? [lindex $argv 2] : 8}]
set V49_FACTOR  [dict get [v49_geometry $V49_NCH [expr {$argc > 3 ? [lindex $argv 3] : ""}]] F]
set variant     "_f$V49_FACTOR"
if {$V49_FS != 2400.0} { append variant "_fs[format %g $V49_FS]" }
set proj_name   ${design_name}${variant}_proj
# V49_PROJ_TAG=<t>: a separate project (<name>_proj_<t>), so the same build can
# run several implementation strategies at once; outputs keep the build's name
if {[info exists ::env(V49_PROJ_TAG)] && $::env(V49_PROJ_TAG) ne ""} {
  append proj_name _$::env(V49_PROJ_TAG)
}
# the caller (make v49) deletes build/v49_qsfp/<this> once Vivado exits,
# however it exits: only the bitstream is kept
if {[info exists ::env(V49_PROJ_FILE)] && $::env(V49_PROJ_FILE) ne ""} {
  set fh [open $::env(V49_PROJ_FILE) w]; puts $fh $proj_name; close $fh
}
file mkdir $outdir
cd $outdir

# The RTL top = BD wrapper + cmac_100g (neither cmac_usplus nor
# gtwizard_ultrascale may sit in the block design, see zcu208_uhd_v49.tcl). Every
# wrapper port passes through unchanged, except the CMAC-side ports the design
# exports, which become nets on cmac_100g; the zSFP28 serial pins and the GT
# refclk are new top ports, named as in the design XDC.
proc v49_gen_top {wrapper out} {
  set f [open $wrapper]; set src [read $f]; close $f
  if {![regexp {module\s+(\w+)\s*\(} $src -> wname]} { error "v49_gen_top: no module in $wrapper" }
  set design [string range $wname 0 end-8]
  set cmac [dict create \
    cmac_usr_clk usr_clk  cmac_usr_rstn usr_rstn  cmac_ctl ctl  cmac_status status \
    cmac_init_clk init_clk  cmac_refclk_khz refclk_khz  cmac_usrclk_khz usrclk_khz \
    cmac_tx_tdata s_axis_tx_tdata  cmac_tx_tkeep s_axis_tx_tkeep  cmac_tx_tvalid s_axis_tx_tvalid \
    cmac_tx_tlast s_axis_tx_tlast  cmac_tx_tuser s_axis_tx_tuser  cmac_tx_tready s_axis_tx_tready \
    cmac_rx_tdata m_axis_rx_tdata  cmac_rx_tkeep m_axis_rx_tkeep  cmac_rx_tvalid m_axis_rx_tvalid \
    cmac_rx_tlast m_axis_rx_tlast  cmac_rx_tuser m_axis_rx_tuser]
  set ports {}
  foreach line [split $src "\n"] {
    if {[regexp {^\s*(input|output|inout)\s*(\[[^\]]+\])?\s*(\w+)\s*;} $line -> d w n]} {
      lappend ports [list $d [string map {" " ""} $w] $n]
    }
  }
  set have {}
  foreach p $ports { if {[dict exists $cmac [lindex $p 2]]} { lappend have [lindex $p 2] } }
  foreach k [dict keys $cmac] {
    if {$k ni {cmac_tx_tuser cmac_rx_tuser} && $k ni $have} { error "v49_gen_top: wrapper lacks $k" }
  }
  set decl {}
  foreach p $ports {
    lassign $p d w n
    if {$n ni $have} { lappend decl "    $d wire [expr {$w ne {} ? "$w " : {}}]$n" }
  }
  lappend decl "    input  wire \[3:0\] sfp_rxp" "    input  wire \[3:0\] sfp_rxn" \
               "    output wire \[3:0\] sfp_txp" "    output wire \[3:0\] sfp_txn" \
               "    input  wire sfp_refclk_p" "    input  wire sfp_refclk_n"
  set L [list "// GENERATED by v49_build.tcl (v49_gen_top) from [file tail $wrapper] -- do not edit." \
              "// ${design}_top = block design + cmac_100g (100GbE on the zSFP28 cages)." \
              "`timescale 1ps/1ps" "module ${design}_top (" [join $decl ",\n"] ");"]
  foreach p $ports {
    lassign $p d w n
    if {$n in $have} { lappend L "  wire [expr {$w ne {} ? "$w " : {}}]$n;" }
  }
  set conns {}
  foreach p $ports { lappend conns "    .[lindex $p 2]([lindex $p 2])" }
  lappend L "" "  $wname ${design}_i (" [join $conns ",\n"] "  );" "" "  cmac_100g cmac ("
  set c [list "    .gt_rxp_in(sfp_rxp)" "    .gt_rxn_in(sfp_rxn)" "    .gt_txp_out(sfp_txp)" \
              "    .gt_txn_out(sfp_txn)" "    .gt_ref_clk_p(sfp_refclk_p)" "    .gt_ref_clk_n(sfp_refclk_n)"]
  dict for {bd cm} $cmac {
    if {$bd in $have} { lappend c "    .$cm\($bd\)"
    } elseif {$bd eq "cmac_tx_tuser"} { lappend c "    .$cm\(1'b0\)"
    } elseif {$bd eq "cmac_rx_tuser"} { lappend c "    .$cm\(\)" }
  }
  lappend L [join $c ",\n"] "  );" "endmodule"
  set f [open $out w]; puts $f [join $L "\n"]; close $f
  puts "V49_TOP ${design}_top: [expr {[llength $ports] - [llength $have]}] pass-through ports, [llength $have] CMAC nets"
}

proc v49_write_outputs {proj_name design_name variant} {
  # the XDC finds the PL_CLK BUFG net by pattern (one file for every design
  # name): it must have matched exactly one net
  set n [get_nets -hierarchical -filter {NAME =~ "*/MTS_block/BUFG_PL_CLK/U0/BUFG_O*"}]
  if {[llength $n] != 1 || [get_property CLOCK_DEDICATED_ROUTE $n] ne "ANY_CMT_COLUMN"} {
    error "v49: XDC net */MTS_block/BUFG_PL_CLK/U0/BUFG_O* matched '$n' (CLOCK_DEDICATED_ROUTE '[get_property -quiet CLOCK_DEDICATED_ROUTE $n]')"
  }
  report_timing_summary -file ./$proj_name/timing_summary.rpt
  report_utilization    -file ./$proj_name/utilization.rpt
  file mkdir ./$proj_name/bitstream
  file copy -force ./$proj_name/$proj_name.runs/impl_1/${design_name}_top.bit \
      ./$proj_name/bitstream/${design_name}${variant}.bit
  file copy -force ./$proj_name/$proj_name.gen/sources_1/bd/$design_name/hw_handoff/${design_name}.hwh \
      ./$proj_name/bitstream/${design_name}${variant}.hwh
  # a timing-clean build's pair also lands in build/v49_qsfp/bitstreams (what
  # rfsoc_lib/uhd/server/deploy.sh BIT_DIR= points at); one that missed
  # timing goes to bitstreams_timing_fail instead, so it can never replace a
  # good one in the deploy set
  set wns [get_property STATS.WNS [get_runs impl_1]]
  set whs [get_property STATS.WHS [get_runs impl_1]]
  set dest [expr {($wns >= 0 && $whs >= 0) ? "./bitstreams" : "./bitstreams_timing_fail"}]
  file mkdir $dest
  foreach ext {bit hwh} {
    file copy -force ./$proj_name/bitstream/${design_name}${variant}.$ext $dest/
  }
  foreach r {timing_summary utilization} {
    file copy -force ./$proj_name/$r.rpt $dest/${design_name}${variant}.$r.rpt
  }
  puts "WNS: $wns  WHS: $whs  -> $dest"
  # the design is its .tcl/.xdc: drop the project (several GB) once its
  # outputs are copied out
  if {!([info exists ::env(V49_KEEP_PROJ)] && $::env(V49_KEEP_PROJ) eq "1")} {
    close_project
    file delete -force ./$proj_name
    puts "V49: deleted ./$proj_name (V49_KEEP_PROJ=1 keeps it)"
  }
}

if {$step eq "impl"} {
  open_project ./$proj_name/$proj_name.xpr
  if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
  }
  # post-route phys_opt: closes the last tenths of a ns on the CMAC-side
  # (322 MHz) paths placement leaves slightly short (4ch F=3: CMAC tready
  # -> axis_pkt_arb output register, -0.2 ns)
  # an implementation strategy from the environment (make v49 STRATEGY=...);
  # set first: a strategy rewrites the step options below it
  if {[info exists ::env(V49_IMPL_STRATEGY)] && $::env(V49_IMPL_STRATEGY) ne ""} {
    set_property strategy $::env(V49_IMPL_STRATEGY) [get_runs impl_1]
  }
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
  launch_runs impl_1 -to_step write_bitstream -jobs $jobs
  wait_on_run impl_1
  open_run impl_1
  v49_write_outputs $proj_name $design_name $variant
  exit
}

create_project $proj_name ./$proj_name -force -part xczu48dr-fsvg1517-2-e
set_property BOARD_PART xilinx.com:zcu208:part0:2.0 [current_project]
set_property target_language Verilog [current_project]
# ip/uhd_ip: the data-plane cores (sources, testbenches, packaging in
# ip_design/uhd_ip); the two I/Q joiners from ip/iprepo -- the design's only
# other non-Xilinx IP (named singly: nothing else in ip/iprepo is used)
set_property ip_repo_paths [list $hwd/ip/uhd_ip $hwd/ip/iprepo/dual_rf_adc_iq_merger_1.0 \
                                 $hwd/ip/iprepo/dual_channel_rf_adc_iq_packer_1.0] [current_project]
update_ip_catalog
foreach vlnv {user.org:uhd:udp_streamer:1.0 user.org:uhd:udp_player:1.0
              user.org:uhd:axis_pkt_arb:1.0 user.org:uhd:ch_interleave:1.0
              user.org:uhd:tx_beamformer:1.0 user.org:uhd:rx_beamformer:1.0} {
  if {[llength [get_ipdefs -all $vlnv]] == 0} {
    error "v49: IP $vlnv not in ip/uhd_ip -- run 'make package' in hw_design/ip_design/uhd_ip"
  }
}
source $hwd/ip_design/cmac_100g/create_cmac_ip.tcl
add_files -fileset constrs_1 -norecurse $here/zcu208_uhd_v49.xdc
source $here/zcu208_uhd_v49.tcl
validate_bd_design
save_bd_design
if {$step eq "bd"} { exit }

make_wrapper -files [get_files ${design_name}.bd] -top
set wrapper ./$proj_name/$proj_name.gen/sources_1/bd/$design_name/hdl/${design_name}_wrapper.v
add_files -norecurse $wrapper
v49_gen_top $wrapper ./$proj_name/${design_name}_top.v
add_files -norecurse ./$proj_name/${design_name}_top.v
set_property top ${design_name}_top [current_fileset]
update_compile_order -fileset sources_1

if {$step eq "synth"} {
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  exit
}
# post-route phys_opt: closes the last tenths of a ns on the CMAC-side
# (322 MHz) paths placement leaves slightly short (4ch F=3: CMAC tready
# -> axis_pkt_arb output register, -0.2 ns)
# an implementation strategy from the environment (make v49 STRATEGY=...);
# set first: a strategy rewrites the step options below it
if {[info exists ::env(V49_IMPL_STRATEGY)] && $::env(V49_IMPL_STRATEGY) ne ""} {
  set_property strategy $::env(V49_IMPL_STRATEGY) [get_runs impl_1]
}
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
open_run impl_1
v49_write_outputs $proj_name $design_name $variant
