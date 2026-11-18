# fir_spike.tcl -- Gate 0 of the low-rate FIR chains: one FIR Compiler 7.2
# stage, generated, synthesised out of context (and with IMPL=1 placed and
# routed) at the templates' top converter clock, its DSP / BRAM / timing
# printed as one SPIKE_RESULT line.
#
#   vivado -mode batch -source fir_spike.tcl -tclargs <dir rx|tx> <p> <paths> [<out_dir>]
#
# p is the stage's converter-side parallelism (samples per clock per path:
# 8 4 2 1 0.5 .. 1/32); paths = I/Q lanes of the instance (<= 16).
# rate_stage_cfg is THE stage configuration: the block designs and
# sim/rate_fir_ip.tcl carry a verbatim copy.

# ---- rate_stage_cfg (copied verbatim into the designs and the sims) ----
# One ÷2 (rx) / ×2 (tx) stage of the low-rate chains, p its converter-side
# parallelism (RX: input samples per clock per path; TX: output samples per
# clock per path). FIR Compiler's architecture depends on the ratio only, so
# the clock is a nominal 100 MHz. Full-precision output (the hub rounds and
# saturates); 18-bit integer coefficients from rate_hb.coe; above one sample
# per clock (super sample rate) half-band is not offered: Inferred.
proc rate_stage_cfg {dir p paths coe} {
  if {$paths < 1 || $paths > 16} { error "rate_stage_cfg: $paths paths (1..16)" }
  set in [expr {$dir eq "rx" ? $p : $p / 2.0}]
  set ssr [expr {$p > 1}]
  set d [list \
    CONFIG.CoefficientSource Vector CONFIG.CoefficientVector $coe \
    CONFIG.Coefficient_Width 18 CONFIG.Coefficient_Sign Signed \
    CONFIG.Quantization Integer_Coefficients CONFIG.Coefficient_Fractional_Bits 0 \
    CONFIG.Coefficient_Structure [expr {$ssr ? "Inferred" : "Half_Band"}] \
    CONFIG.Data_Width 16 CONFIG.Data_Fractional_Bits 0 CONFIG.Data_Sign Signed \
    CONFIG.Output_Rounding_Mode Full_Precision \
    CONFIG.Number_Channels 1 CONFIG.Number_Paths $paths \
    CONFIG.RateSpecification Frequency_Specification \
    CONFIG.Clock_Frequency 100 CONFIG.Sample_Frequency [expr {100.0 * $in}] \
    CONFIG.Rate_Change_Type Integer \
    CONFIG.Has_ARESETn true CONFIG.M_DATA_Has_TREADY true CONFIG.S_DATA_Has_FIFO true]
  if {$dir eq "rx"} {
    lappend d CONFIG.Filter_Type Decimation CONFIG.Decimation_Rate 2
  } else {
    lappend d CONFIG.Filter_Type Interpolation CONFIG.Interpolation_Rate 2
  }
  return $d
}
# ---- end rate_stage_cfg ----

# The odd polyphase branch of a half-band as a single-rate symmetric FIR
# (dir "sr", p its samples per clock): the even branch is the centre tap
# alone (a delay and a shift in the hub), so a super-sample-rate ÷2 / ×2 is
# this filter at p/2 samples per clock plus the hub's interleave.
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

proc rate_odd_coe {coe} {
  set l [split $coe ","]
  set out {}
  for {set i 0} {$i < [llength $l]} {incr i 2} { lappend out [lindex $l $i] }
  return [join $out ","]
}

proc rate_coe {file} {
  set f [open $file]
  set v [join [split [string trim [read $f]] "\n"] ","]
  close $f
  return $v
}

if {![info exists ::rate_lib_only] && [info exists argv] && [llength $argv] >= 3} {
  lassign $argv dir p paths out
  if {$out eq ""} { set out [pwd] }
  set here [file dirname [file normalize [info script]]]
  set coe [rate_coe $here/../rate_hb.coe]
  set impl [expr {[info exists ::env(IMPL)] && $::env(IMPL)}]
  set tag "${dir}_p${p}_n${paths}"
  file mkdir $out/$tag
  cd $out/$tag
  create_project -in_memory -part xczu49dr-ffvf1760-2-e
  create_ip -vlnv xilinx.com:ip:fir_compiler:7.2 -module_name fir -dir .
  set ip [get_ips fir]
  if {$dir eq "sr"} {
    set_property -dict [rate_sr_cfg $p $paths [rate_odd_coe $coe]] $ip
  } else {
    set_property -dict [rate_stage_cfg $dir $p $paths $coe] $ip
  }
  generate_target {synthesis} $ip
  synth_design -top fir -mode out_of_context -part xczu49dr-ffvf1760-2-e
  create_clock -period 3.2 -name aclk [get_ports aclk]
  if {$impl} { opt_design; place_design; route_design }
  set dsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2}]]
  set bram [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] + 0.5 * [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
  set lut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
  set in_w [llength [get_ports s_axis_data_tdata*]]
  set out_w [llength [get_ports m_axis_data_tdata*]]
  puts "SPIKE_RESULT ver=[version -short] dir=$dir p=$p paths=$paths impl=$impl dsp=$dsp bram=$bram lut=$lut wns=$wns in_w=$in_w out_w=$out_w ok=[expr {$wns >= 0}]"
}
