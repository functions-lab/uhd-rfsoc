#!/usr/bin/env bash
# run_sim_rate.sh -- the low-rate chains with their real FIR Compiler stages,
# every geometry of the v49 designs, every depth, checked bit-exact by
# check_rate.py.
#   DIR=rx|tx (default both)  GEOMS="N:SPC:K:G ..." (default: the designs')
#   RATE_TAG=<t>: build dirs build_rate_<t>_... (another Vivado release)
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$(v=$(command -v vivado) && dirname "$(dirname "$(readlink -f "$v")")" || echo /tools/Xilinx/Vivado/2021.1)}
source "$VIVADO_ROOT/settings64.sh"
HERE=$PWD
# ZCU216 1/2/4/8/16 ch (SPC 4 4 4 2 1, K 5), RFSoC 4x2 1/2 ch (SPC 8, and 4
# for 2ch at fs 5000; K 6)
GEOMS=${GEOMS:-"1:4:5:1 2:4:5:1 4:4:5:1 8:2:5:1 16:1:5:2 1:8:6:1 2:8:6:1 2:4:6:1"}
python3 check_rate.py selftest > /dev/null
fail=0
for d in ${DIR:-rx tx}; do
  for geo in $GEOMS; do
    IFS=: read -r n s k g <<< "$geo"
    w=build_rate${RATE_TAG:+_$RATE_TAG}_${d}_n${n}_s${s}_k${k}_g${g}
    echo "== ${d}_rate N_CH=$n SPC=$s K=$k G=$g"
    RATE_NIN=${RATE_NIN:-} vivado -mode batch -nojournal -nolog -source rate_fir_ip.tcl \
      -tclargs "$d" "$n" "$s" "$k" "$g" "$HERE/$w" > "$HERE/$w.log" 2>&1 || { echo "FAIL: vivado ($w.log)"; fail=1; continue; }
    simdir=$(dirname "$(find "$HERE/$w" -name simulate.log | head -1)")
    grep -E "^(DEPTH|ASSERT_|INFO=)|Fatal|ERROR" "$simdir/simulate.log" || true
    grep -q "ASSERT_RX_NO_STALL ok\|ASSERT_TX_CONTINUOUS ok" "$simdir/simulate.log" || { echo "FAIL: assertion"; fail=1; }
    for f in "$simdir"/${d}_d*.txt; do python3 check_rate.py "$d" "$f" || fail=1; done
  done
done
[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
