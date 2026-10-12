#!/usr/bin/env bash
# Simulate axis_pkt_arb against its previous form (axis_pkt_arb_skid_ref.v):
# random AXIS traffic and backpressure, every port compared on every cycle;
# the testbench is self-checking.
#   ./run_sim_arb.sh   (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$HOME/Xilinx/Vivado/2021.1}
source "$VIVADO_ROOT/settings64.sh"
HERE=$PWD
mkdir -p build_arb && cd build_arb
xvlog "$HERE/../src/axis_pkt_arb.v" "$HERE/axis_pkt_arb_skid_ref.v" > xvlog_rtl.log
xvlog -sv "$HERE/tb_axis_pkt_arb.sv" > xvlog_tb.log
xelab -debug off --timescale 1ns/1ps tb_axis_pkt_arb -s tb > xelab.log
xsim tb -runall -log xsim.log > /dev/null
grep -E "^phase|cycles|PASS|FAIL|ERROR|Fatal" xsim.log
grep -q "AXIS_PKT_ARB PASS" xsim.log
