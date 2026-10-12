#!/usr/bin/env bash
# Simulate udp_player (and, with the INTEG build, udp_streamer + axis_pkt_arb)
# with xsim, then check every DAC beat and every returned frame.
#   ./run_sim_player.sh         (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
# Runs once per M_WIDTH in $WIDTHS (default "128 256 512"; DAC beat width,
# the INTEG streamer gets S_WIDTH = M_WIDTH), TICK_STEP in $TICK_STEPS
# (default "1 2"; ticks per slot) and over-the-wire format in $FMTS (default
# "0"; 0 sc16, 1 sc8, 2 sc12, 3 fc32 -- PROTOCOL.md 10). Width 128 step 1
# builds in build_player/ and build_integ/, width 128 step N in
# build_player_tsN/ and build_integ_tsN/, width W in build_player_wW[_tsN]/
# and build_integ_wW[_tsN]/; FMT F != 0 appends _fmtF. FAST=1 runs adc_clk at
# 300 MHz at every width (512 b: one group per cycle) and appends _fast;
# TXBW=<words> sets TX_BUF_WORDS (default 256) and appends _bufN. CHAIN=<n>
# [CHAIN_D=<words>, default 64] adds the deep play-out chain and appends _chN.
#   FMTS="0 1 2 3" TICK_STEPS=1 ./run_sim_player.sh      # the format sweep
#   FAST=1 WIDTHS=512 TICK_STEPS=1 FMTS="1 2" ./run_sim_player.sh
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$HOME/Xilinx/Vivado/2021.1}
source "$VIVADO_ROOT/settings64.sh"
XPM=$VIVADO_ROOT/data/ip/xpm
HERE=$PWD

run() {   # $1 = build dir, $2 = TICK_STEP, $3 = M_WIDTH, $4 = FMT, rest = extra xvlog args
    local work=$1 ts=$2 w=$3 f=$4; shift 4
    mkdir -p "$work" && cd "$work"
    xvlog -sv "$XPM/xpm_cdc/hdl/xpm_cdc.sv" "$XPM/xpm_memory/hdl/xpm_memory.sv" \
              "$XPM/xpm_fifo/hdl/xpm_fifo.sv" --work xpm > xvlog_xpm.log
    xvlog "$VIVADO_ROOT/data/verilog/src/glbl.v" "$HERE/../src/udp_player.v" \
          "$HERE/../src/axis_pkt_arb.v" "$HERE/../src/udp_streamer.v" > xvlog_rtl.log
    xvlog -sv "$@" "$HERE/tb_udp_player.sv" > xvlog_tb.log
    xelab -L xpm -debug off --timescale 1ns/1ps -generic_top "TICK_STEP=$ts" \
          -generic_top "M_WIDTH=$w" -generic_top "FMT=$f" -generic_top "FAST=${FAST:-0}" \
          -generic_top "TXBW=${TXBW:-256}" -generic_top "CHAIN=${CHAIN:-0}" \
          -generic_top "CHAIN_D=${CHAIN_D:-64}" tb_udp_player glbl -s tb > xelab.log
    xsim tb -runall -log xsim.log > /dev/null
    grep -E "ERROR|Fatal|TB_ERRORS|DMA|FRAMES_SENT|INTEG|overflow:" xsim.log || true
    cd "$HERE"
}

for F in ${FMTS:-0}; do
for W in ${WIDTHS:-128 256 512}; do
for TS in ${TICK_STEPS:-1 2}; do
    SFX=
    if [ "$W" != 128 ]; then SFX=_w$W; fi
    if [ "$TS" != 1 ]; then SFX=${SFX}_ts$TS; fi
    if [ "$F" != 0 ]; then SFX=${SFX}_fmt$F; fi
    if [ "${FAST:-0}" != 0 ]; then SFX=${SFX}_fast; fi
    if [ "${TXBW:-256}" != 256 ]; then SFX=${SFX}_buf$TXBW; fi
    if [ "${CHAIN:-0}" != 0 ]; then SFX=${SFX}_ch$CHAIN; fi

    echo "== udp_player, M_WIDTH=$W TICK_STEP=$TS FMT=$F"
    run build_player$SFX "$TS" "$W" "$F"
    python3 check_player.py --tick-step "$TS" --width "$W" --fmt "$F" build_player$SFX/player.log

    echo "== integration: udp_streamer + udp_player -> axis_pkt_arb, M_WIDTH=$W TICK_STEP=$TS FMT=$F"
    run build_integ$SFX "$TS" "$W" "$F" -d INTEG
    python3 check_player.py --integ --tick-step "$TS" --width "$W" --fmt "$F" build_integ$SFX/player.log
done
done
done
