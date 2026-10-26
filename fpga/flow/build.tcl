# build.tcl -- build one bitstream of one board: <board>_v49_<N>ch_qsfp_f<F>_fs<fs>
# (the board as a UHD device over 100 GbE). `make -C fpga BOARD=<board> bitstream
# N=<N> [F=<F>] [FS=<fs>]` (and the templates / ladder targets) call it; directly:
#
#   vivado -mode batch -nojournal -nolog -source fpga/flow/build.tcl \
#          -tclargs <board> <N> [bd|synth|bit|impl] [jobs] [factor] [fs]
#
#   bd     block design only (validates it and runs every v49 check)
#   synth  + synthesis
#   bit    + implementation and bitstream (default)
#   impl   continue an existing synthesized project to a bitstream
#
# Inputs:
#   fpga/boards/<board>/board.tcl     the board's facts (part, clock families, link, ...)
#   fpga/boards/<board>/block_designs/<bd>/<bd>.{tcl,xdc}
#                                     the design, every N, one per clock family,
#                                     chosen by fs: the family whose LMX2594 reference
#                                     has a register file for fs in
#                                     rfsoc/rfsoc_lib/xrfclk/<board_xrfclk>/ (the board
#                                     needs the same file to run the build)
#   fpga/ip/repo/uhd_ip               the packaged cores (`make -C fpga package` first)
#   fpga/ip/src/cmac_100g             CMAC + GT wrapper RTL (board_cmac_lanes)
# Output: fpga/build/<board>/bitstreams/<board>_v49_<N>ch_qsfp_f<F>_fs<fs>.{bit,hwh}
#         (fs with its decimal point as p: _fs2457p6) with its timing and
#         utilization reports; a build that misses timing goes to
#         bitstreams_timing_fail/ instead. The Vivado project
#         (fpga/build/<board>/<name>_proj) is deleted once the bitstream is out
#         unless V49_KEEP_PROJ=1 is in the environment.
#
# factor = RFDC converter factor, a v49_geometry row of the design (default:
# that N's first row, the template); fs = converter rate in MS/s (default:
# board_fs_default).

set flow        [file dirname [file normalize [info script]]]
set fpga        [file normalize $flow/..]
set repo_root   [file normalize $fpga/..]
if {$argc < 2} { error "usage: build.tcl -tclargs <board> <N> [bd|synth|bit|impl] [jobs] [factor] [fs]" }
set board       [lindex $argv 0]
set board_dir   $fpga/boards/$board
if {![file exists $board_dir/board.tcl]} { error "v49: no board $board (no $board_dir/board.tcl)" }
source $board_dir/board.tcl
set V49_NCH     [lindex $argv 1]
set step        [expr {$argc > 2 ? [lindex $argv 2] : "bit"}]
set jobs        [expr {$argc > 3 ? [lindex $argv 3] : 8}]
set V49_FS      [expr {$argc > 5 && [lindex $argv 5] ne "" ? double([lindex $argv 5]) : $board_fs_default}]
set outdir      $fpga/build/$board
# cmac_100g's GT sites (create_cmac_ip.tcl reads it)
set CMAC_LANES  $board_cmac_lanes

# the clock family of fs: the LMX2594 register file that makes it
proc v49_bd_of_fs {fs xrfclk families} {
  set hits {}
  foreach {ref bd} $families {
    set pre LMX2594_${ref}_
    foreach f [glob -nocomplain -directory $xrfclk ${pre}*.txt] {
      set out [string range [file rootname [file tail $f]] [string length $pre] end]
      if {[string is double -strict $out] && abs($out - $fs) < 1e-6} { lappend hits $bd }
    }
  }
  if {[llength $hits] != 1} { error "v49: fs $fs MS/s: [llength $hits] LMX2594 register files make it in $xrfclk ($hits); expected one" }
  return [lindex $hits 0]
}
set bd          [v49_bd_of_fs $V49_FS $repo_root/rfsoc/rfsoc_lib/xrfclk/$board_xrfclk $board_families]
set here        $board_dir/block_designs/$bd
if {![file exists $here]} { error "v49: no design directory $here" }
puts "V49_BD $bd (board $board, fs $V49_FS MS/s)"
# the design's procs only (v49_geometry: the factor names the build)
set V49_DEFINE_ONLY 1
source $here/$bd.tcl
unset V49_DEFINE_ONLY
set design_name ${board}_v49_${V49_NCH}ch_qsfp
set V49_FACTOR  [dict get [v49_geometry $V49_NCH [expr {$argc > 4 ? [lindex $argv 4] : ""}]] F]
set variant     "_f${V49_FACTOR}_fs[string map {. p} [format %g $V49_FS]]"
set proj_name   ${design_name}${variant}_proj
# V49_PROJ_TAG=<t>: a separate project (<name>_proj_<t>), so the same build can
# run several implementation strategies at once; outputs keep the build's name
if {[info exists ::env(V49_PROJ_TAG)] && $::env(V49_PROJ_TAG) ne ""} {
  append proj_name _$::env(V49_PROJ_TAG)
}
# the caller (make bitstream) deletes fpga/build/<board>/<this> once Vivado
# exits, however it exits: only the bitstream is kept
if {[info exists ::env(V49_PROJ_FILE)] && $::env(V49_PROJ_FILE) ne ""} {
  set fh [open $::env(V49_PROJ_FILE) w]; puts $fh $proj_name; close $fh
}
file mkdir $outdir
cd $outdir
if {$board_files ne ""} { set_param board.repoPaths [list $board_dir/$board_files] }

# The RTL top = BD wrapper + cmac_100g (neither cmac_usplus nor
# gtwizard_ultrascale may sit in the block design: fpga/ip/src/cmac_100g/AGENTS.md).
# Every wrapper port passes through unchanged, except the CMAC-side ports the
# design exports, which become nets on cmac_100g; the 100G serial pins, the GT
# refclk and the board's constant outputs (board_top_ties) are new top ports,
# named as in the design XDC.
proc v49_gen_top {wrapper out link ties} {
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
  foreach {port v} $ties { lappend decl "    output wire $port" }
  set L [list "// GENERATED by build.tcl (v49_gen_top) from [file tail $wrapper] -- do not edit." \
              "// ${design}_top = block design + cmac_100g (100GbE on $link)." \
              "`timescale 1ps/1ps" "module ${design}_top (" [join $decl ",\n"] ");"]
  foreach p $ports {
    lassign $p d w n
    if {$n in $have} { lappend L "  wire [expr {$w ne {} ? "$w " : {}}]$n;" }
  }
  foreach {port v} $ties { lappend L "  assign $port = 1'b$v;" }
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

proc v49_write_outputs {proj_name design_name variant xdc_nets} {
  # the XDC finds these nets by pattern (one file for every design name):
  # each must have matched exactly one net
  foreach {pat want} $xdc_nets {
    set n [get_nets -hierarchical -filter "NAME =~ \"$pat\""]
    if {[llength $n] != 1 || [get_property CLOCK_DEDICATED_ROUTE $n] ne $want} {
      error "v49: XDC net $pat matched '$n' (CLOCK_DEDICATED_ROUTE '[get_property -quiet CLOCK_DEDICATED_ROUTE $n]', expected $want)"
    }
  }
  report_timing_summary -file ./$proj_name/timing_summary.rpt
  report_utilization    -file ./$proj_name/utilization.rpt
  file mkdir ./$proj_name/bitstream
  file copy -force ./$proj_name/$proj_name.runs/impl_1/${design_name}_top.bit \
      ./$proj_name/bitstream/${design_name}${variant}.bit
  file copy -force ./$proj_name/$proj_name.gen/sources_1/bd/$design_name/hw_handoff/${design_name}.hwh \
      ./$proj_name/bitstream/${design_name}${variant}.hwh
  # a timing-clean build's pair lands in bitstreams/ (what
  # rfsoc/push_bitstreams.sh copies); one that missed timing goes to
  # bitstreams_timing_fail/ instead, so it can never replace a good one
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

# Implementation to a bitstream, then the outputs. An implementation strategy
# from the environment (make bitstream STRATEGY=..., builds.txt via ladder.sh)
# is set first: a strategy rewrites the step options below it. Post-route
# phys_opt closes the last tenths of a ns on the CMAC-side (322 MHz) paths
# placement leaves slightly short.
proc v49_implement {proj_name design_name variant jobs xdc_nets} {
  if {[info exists ::env(V49_IMPL_STRATEGY)] && $::env(V49_IMPL_STRATEGY) ne ""} {
    set_property strategy $::env(V49_IMPL_STRATEGY) [get_runs impl_1]
  }
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
  launch_runs impl_1 -to_step write_bitstream -jobs $jobs
  wait_on_run impl_1
  open_run impl_1
  v49_write_outputs $proj_name $design_name $variant $xdc_nets
}

if {$step eq "impl"} {
  open_project ./$proj_name/$proj_name.xpr
  if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
  }
  v49_implement $proj_name $design_name $variant $jobs $board_xdc_nets
  exit
}

create_project $proj_name ./$proj_name -force -part $board_part
set_property BOARD_PART $board_board_part [current_project]
set_property target_language Verilog [current_project]
# fpga/ip/repo/uhd_ip: the data-plane cores (sources, testbenches, packaging
# in fpga/ip/src/uhd_ip); plus the board's own repositories (board_ip_repos):
# the design's only non-Xilinx IP, each named singly
set repos [list $fpga/ip/repo/uhd_ip]
foreach r $board_ip_repos { lappend repos $fpga/ip/repo/$r }
set_property ip_repo_paths $repos [current_project]
update_ip_catalog
foreach vlnv {user.org:uhd:udp_streamer:1.0 user.org:uhd:udp_player:1.0
              user.org:uhd:axis_pkt_arb:1.0 user.org:uhd:ch_interleave:1.0
              user.org:uhd:tx_beamformer:1.0 user.org:uhd:rx_beamformer:1.0} {
  if {[llength [get_ipdefs -all $vlnv]] == 0} {
    error "v49: IP $vlnv not in fpga/ip/repo/uhd_ip -- run 'make -C fpga package'"
  }
}
source $fpga/ip/src/cmac_100g/create_cmac_ip.tcl
add_files -fileset constrs_1 -norecurse $here/$bd.xdc
source $here/$bd.tcl
validate_bd_design
save_bd_design
if {$step eq "bd"} { exit }

make_wrapper -files [get_files ${design_name}.bd] -top
set wrapper ./$proj_name/$proj_name.gen/sources_1/bd/$design_name/hdl/${design_name}_wrapper.v
add_files -norecurse $wrapper
v49_gen_top $wrapper ./$proj_name/${design_name}_top.v $board_link $board_top_ties
add_files -norecurse ./$proj_name/${design_name}_top.v
set_property top ${design_name}_top [current_fileset]
update_compile_order -fileset sources_1

if {$step eq "synth"} {
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  exit
}
v49_implement $proj_name $design_name $variant $jobs $board_xdc_nets
