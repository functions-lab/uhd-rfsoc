#!/usr/bin/env bash
# Simulate udp_streamer with xsim and check every frame it emits.
#   ./run_sim.sh            (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
# Runs once per S_WIDTH in $WIDTHS (default "128 256 512"; converter-side beat
# width), TICK_STEP in $TICK_STEPS (default "1 2"; ticks per slot) and
# over-the-wire format in $FMTS (default "0"; 0 sc16, 1 sc8, 2 sc12, 3 fc32 --
# PROTOCOL.md 10). Width 128 step 1 builds in build/, width 128 step N in
# build_tsN/, width W in build_wW/ and build_wW_tsN/; FMT F != 0 appends _fmtF.
# FAST=1 runs adc_clk at 300 MHz at every width (512 b: one group per cycle,
# the max-rate geometry) and appends _fast.
#   FMTS="0 1 2 3" TICK_STEPS=1 ./run_sim.sh      # the format sweep
#   FAST=1 WIDTHS=512 TICK_STEPS=1 FMTS="1 2" ./run_sim.sh   # sc8/sc12 at 4.8 GS/s
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$HOME/Xilinx/Vivado/2021.1}
source "$VIVADO_ROOT/settings64.sh"
XPM=$VIVADO_ROOT/data/ip/xpm
HERE=$PWD

for F in ${FMTS:-0}; do
for W in ${WIDTHS:-128 256 512}; do
for TS in ${TICK_STEPS:-1 2}; do
    echo "== udp_streamer, S_WIDTH=$W TICK_STEP=$TS FMT=$F"
    if [ "$W" = 128 ]; then WORK=build; else WORK=build_w$W; fi
    if [ "$TS" != 1 ]; then WORK=${WORK}_ts$TS; fi
    if [ "$F" != 0 ]; then WORK=${WORK}_fmt$F; fi
    if [ "${FAST:-0}" != 0 ]; then WORK=${WORK}_fast; fi
    mkdir -p "$WORK" && cd "$WORK"
    xvlog -sv "$XPM/xpm_cdc/hdl/xpm_cdc.sv" "$XPM/xpm_memory/hdl/xpm_memory.sv" \
              "$XPM/xpm_fifo/hdl/xpm_fifo.sv" --work xpm=xsim.dir/xpm > xvlog_xpm.log
    xvlog "$VIVADO_ROOT/data/verilog/src/glbl.v" "$HERE/../src/udp_streamer.v" > xvlog_rtl.log
    xvlog -sv "$HERE/tb_udp_streamer.sv" > xvlog_tb.log
    xelab -L xpm -debug off --timescale 1ns/1ps -generic_top "TICK_STEP=$TS" \
          -generic_top "S_WIDTH=$W" -generic_top "FMT=$F" -generic_top "FAST=${FAST:-0}" tb_udp_streamer glbl -s tb > xelab.log
    xsim tb -runall -log xsim.log > /dev/null
    grep -E "ID=|OVERFLOWS|PKTS|CMDS|STATUS|FIFO_HWM|FRAMES|SPP_COERCION|Fatal|ERROR" xsim.log || true
    grep -q SPP_COERCION xsim.log || { echo "FAIL: testbench did not finish"; exit 1; }
    python3 "$HERE/check_frames.py" --tick-step "$TS" --width "$W" --fmt "$F" frames.hex
    cd "$HERE"
done
done
done
