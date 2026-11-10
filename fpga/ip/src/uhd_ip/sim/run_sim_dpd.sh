#!/usr/bin/env bash
# Simulate tx_dpd (with its datapath src/dpd_*.sv) with xsim for every
# (N_CH, BEAT_W) a v49 build uses, then check every cycle with check_dpd.py
# (bit-exact against rfsoc_lib/dsp/dpd.py, atomic COMMIT / bypass switching on
# one beat, fixed 32-cycle latency, statistics, the registers).
#   ./run_sim_dpd.sh       (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
# COMBOS overrides the list ("N:BEAT_W:ACLK_PS ..."); s_axi is 100 MHz.
# Builds in build_dpd_<N>_<W>_<ps>/.
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$(v=$(command -v vivado) && dirname "$(dirname "$(readlink -f "$v")")" || echo /tools/Xilinx/Vivado/2021.1)}
source "$VIVADO_ROOT/settings64.sh"
XPM=$VIVADO_ROOT/data/ip/xpm
SRC=$PWD/../src
HERE=$PWD

# N:BEAT_W:aclk period (ps) -- the v49_geometry rows of both boards at the
# templates' 312.5 MHz (ZCU216 1:128 2:256 4:512 8:512 16:512, RFSoC 4x2
# 1:256 2:512: SSR 4, 4, 4, 2, 1, 8, 8), and a slow converter clock (F40)
COMBOS=${COMBOS:-"1:128:3200 2:256:3200 4:512:3200 8:512:3200 16:512:3200 1:256:3200 2:512:3200 \
1:128:64000 16:512:16000"}

fail=0
for c in $COMBOS; do
    IFS=: read -r N BW PS <<< "$c"
    work=build_dpd_${N}_${BW}_${PS}
    echo "== tx_dpd N_CH=$N BEAT_W=$BW aclk ${PS} ps"
    mkdir -p "$work" && cd "$work"
    python3 "$HERE/check_dpd.py" gen --out coefs.hex > gen.log
    xvlog -sv "$XPM/xpm_cdc/hdl/xpm_cdc.sv" --work xpm=xsim.dir/xpm > xvlog_xpm.log
    xvlog -sv "$SRC"/dpd_*.sv > xvlog_ip.log
    xvlog "$VIVADO_ROOT/data/verilog/src/glbl.v" "$SRC/tx_dpd.v" > xvlog_rtl.log
    xvlog -sv "$HERE/tb_tx_dpd.sv" > xvlog_tb.log
    xelab -L xpm -debug off --timescale 1ns/1ps -generic_top "N_CH=$N" -generic_top "BEAT_W=$BW" \
          -generic_top "ACLK_PS=$PS" tb_tx_dpd glbl -s tb > xelab.log
    xsim tb -runall -testplusarg LOG=dpd.log -log xsim.log > /dev/null
    grep -E "ERROR|Fatal|TB_DONE" xsim.log | head -20 || true
    grep -q "TB_ERRORS=0" xsim.log || fail=1
    python3 "$HERE/check_dpd.py" check dpd.log || fail=1
    cd "$HERE"
done

# an illegal geometry must fail elaboration
mkdir -p build_dpd_bad && cd build_dpd_bad
xvlog -sv "$SRC"/dpd_*.sv > xvlog_ip.log
xvlog "$SRC/tx_dpd.v" > xvlog_rtl.log
if xelab -L xpm -debug off tx_dpd -generic_top N_CH=16 -generic_top BEAT_W=256 -s bad > xelab_bad.log 2>&1; then
    echo "FAIL: N_CH 16 x BEAT_W 256 elaborated"; fail=1
else
    echo "illegal N_CH 16 x BEAT_W 256: elaboration refused (ok)"
fi
cd "$HERE"

if [ $fail = 0 ]; then echo "TX_DPD PASS"; else echo "TX_DPD FAIL"; exit 1; fi
