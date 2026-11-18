# rate_fir_ip.tcl -- xsim of a low-rate chain with its real FIR Compiler
# stages: a project with rfir_1 .. rfir_K (rate_sr_cfg, the stage
# configuration the block designs carry verbatim), the hub and its testbench.
#
#   vivado -mode batch -source rate_fir_ip.tcl -tclargs <rx|tx> <N_CH> <SPC> <K> <G> <work_dir>
#
# Run by run_sim_rate.sh, which then checks the dumps with check_rate.py.

# ---- rate_sr_cfg (verbatim in every design and in fpga/ip/src/uhd_ip/rate/spike/fir_spike.tcl) ----
# One stage's FIR: the 26-tap odd polyphase branch of the half-band
# (rate_hb.coe, even taps), single rate, symmetric, p samples per clock per
# path (p = max(SPC >> i, 1) per valid at the rate of stage i), full precision
# out (the hub adds the centre tap, rounds and saturates).
proc rate_sr_cfg {p paths coe} {
  if {$paths < 1 || $paths > 16} { error "rate_sr_cfg: $paths paths (1..16)" }
  return [list \
    CONFIG.CoefficientSource Vector CONFIG.CoefficientVector $coe \
    CONFIG.Coefficient_Width 18 CONFIG.Coefficient_Sign Signed \
    CONFIG.Quantization Integer_Coefficients CONFIG.Coefficient_Fractional_Bits 0 \
    CONFIG.Coefficient_Structure Symmetric \
    CONFIG.Data_Width 16 CONFIG.Data_Fractional_Bits 0 CONFIG.Data_Sign Signed \
    CONFIG.Output_Rounding_Mode Full_Precision \
    CONFIG.Number_Channels 1 CONFIG.Number_Paths $paths \
    CONFIG.RateSpecification Frequency_Specification \
    CONFIG.Clock_Frequency 100 CONFIG.Sample_Frequency [expr {100.0 * $p}] \
    CONFIG.Filter_Type Single_Rate \
    CONFIG.Has_ARESETn true CONFIG.M_DATA_Has_TREADY true CONFIG.S_DATA_Has_FIFO true]
}
proc rate_odd_coe {file} {
  set f [open $file]; set l [split [string trim [read $f]] "\n"]; close $f
  set out {}
  for {set i 0} {$i < [llength $l]} {incr i 2} { lappend out [string trim [lindex $l $i]] }
  return [join $out ","]
}
# the FIR rate of stage i (1 = next to the RFDC): samples per clock per path
proc rate_stage_p {dir spc i} {
  # RX stage i takes max(spc>>(i-1),1) samples, its FIR the even half;
  # TX stage i takes max(spc>>i,1) samples (the FIR on all of them). Both:
  return [expr {double($spc) / (1 << $i)}]
}
# ---- end rate_sr_cfg ----

lassign $argv dir nch spc k g work
set here [file dirname [file normalize [info script]]]
set coe [rate_odd_coe $here/../rate/rate_hb.coe]
file delete -force $work
create_project rate_sim $work -part xczu49dr-ffvf1760-2-e
set paths [expr {2 * $nch / $g}]
for {set i 1} {$i <= $k} {incr i} {
  create_ip -vlnv xilinx.com:ip:fir_compiler:7.2 -module_name rfir_$i
  set_property -dict [rate_sr_cfg [rate_stage_p $dir $spc $i] $paths $coe] [get_ips rfir_$i]
}
generate_target {simulation} [get_ips]
add_files -fileset sim_1 [list $here/../src/${dir}_rate.v $here/tb_${dir}_rate.sv]
set_property top tb_${dir}_rate [get_filesets sim_1]
set nin [expr {$::env(RATE_NIN) ne "" ? $::env(RATE_NIN) : 512}]
set_property generic "N_CH=$nch SPC=$spc K=$k G=$g NIN=$nin" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
puts "RATE_SIM_DONE $dir $nch $spc $k $g [get_property DIRECTORY [current_project]]"
