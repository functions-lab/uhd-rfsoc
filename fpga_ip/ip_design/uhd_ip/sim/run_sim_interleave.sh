#!/usr/bin/env bash
# Simulate ch_interleave (every legal N_CH / BEAT_W, DIR 0, DIR 1, DIR 0 -> 1,
# REG 0 and 1) with xsim; the testbench is self-checking. Also checks that an
# illegal combination (N_CH 8 at BEAT_W 128) fails elaboration.
#   ./run_sim_interleave.sh   (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$HOME/Xilinx/Vivado/2021.1}
source "$VIVADO_ROOT/settings64.sh"
HERE=$PWD
mkdir -p build_interleave && cd build_interleave
xvlog "$HERE/../src/ch_interleave.v" > xvlog_rtl.log
xvlog -sv "$HERE/tb_ch_interleave.sv" > xvlog_tb.log
xelab -debug off --timescale 1ns/1ps tb_ch_interleave -s tb > xelab.log
xsim tb -runall -log xsim.log > /dev/null
grep -E "REG BEAT_W|PASS|FAIL|ERROR|Fatal" xsim.log
grep -q "CH_INTERLEAVE PASS" xsim.log
if xelab -debug off ch_interleave -generic_top N_CH=8 -generic_top BEAT_W=128 -s bad > xelab_bad.log 2>&1; then
    echo "FAIL: N_CH 8 x BEAT_W 128 elaborated"; exit 1
else
    echo "illegal N_CH 8 x BEAT_W 128: elaboration refused (ok)"
fi
