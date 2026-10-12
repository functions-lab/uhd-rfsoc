#!/usr/bin/env bash
# Simulate rx_beamformer with xsim for every (N_CH, BEAT_W) a v49 build uses,
# then check every beat with check_rbf.py (bit-exact bypass, the exact beam
# arithmetic with rounding and saturation on channel 0, channels 1..N-1
# untouched, atomic weight / shift / enable switching, no lost / duplicated
# / reordered beats).
#   ./run_sim_rbf.sh        (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
# COMBOS overrides the list ("N:BEAT_W:ACLK_PS ..."); the converter clock is
# the build's fabric clock, s_axi is 100 MHz. Builds in build_rbf_<N>_<W>_<ps>/.
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$HOME/Xilinx/Vivado/2021.1}
source "$VIVADO_ROOT/settings64.sh"
XPM=$VIVADO_ROOT/data/ip/xpm
HERE=$PWD

# N:BEAT_W:aclk period (ps) -- the zcu216_v49_qsfp.tcl v49_geometry rows with N >= 2
# (1024: the sc8max 8ch F3 / 16ch F6 builds at 187.5 MHz)
COMBOS=${COMBOS:-"2:128:3333 2:256:3333 4:128:3333 4:256:3333 4:512:3333 \
8:256:6667 8:256:3333 8:512:3333 16:512:16667 16:512:6667 16:512:3333 \
8:1024:5333 16:1024:5333"}

fail=0
for c in $COMBOS; do
    IFS=: read -r N BW PS <<< "$c"
    work=build_rbf_${N}_${BW}_${PS}
    echo "== rx_beamformer N_CH=$N BEAT_W=$BW aclk ${PS} ps"
    mkdir -p "$work" && cd "$work"
    python3 "$HERE/check_rbf.py" gen --nch "$N" --out weights.hex --shifts shifts.hex > gen.log
    xvlog -sv "$XPM/xpm_cdc/hdl/xpm_cdc.sv" --work xpm=xsim.dir/xpm > xvlog_xpm.log
    xvlog "$VIVADO_ROOT/data/verilog/src/glbl.v" "$HERE/../src/rx_beamformer.v" > xvlog_rtl.log
    xvlog -sv "$HERE/tb_rx_beamformer.sv" > xvlog_tb.log
    xelab -L xpm -debug off --timescale 1ns/1ps -generic_top "N_CH=$N" -generic_top "BEAT_W=$BW" \
          -generic_top "ACLK_PS=$PS" tb_rx_beamformer glbl -s tb > xelab.log
    xsim tb -runall -testplusarg LOG=rbf.log -log xsim.log > /dev/null
    grep -E "ERROR|Fatal|TB_DONE|LATENCY" xsim.log | head -20 || true
    grep -q "TB_ERRORS=0" xsim.log || fail=1
    python3 "$HERE/check_rbf.py" check rbf.log || fail=1
    cd "$HERE"
done

# an illegal geometry must fail elaboration
mkdir -p build_rbf_bad && cd build_rbf_bad
xvlog "$HERE/../src/rx_beamformer.v" > xvlog_rtl.log
if xelab -L xpm -debug off rx_beamformer -generic_top N_CH=16 -generic_top BEAT_W=256 -s bad > xelab_bad.log 2>&1; then
    echo "FAIL: N_CH 16 x BEAT_W 256 elaborated"; fail=1
else
    echo "illegal N_CH 16 x BEAT_W 256: elaboration refused (ok)"
fi
cd "$HERE"

if [ $fail = 0 ]; then echo "RX_BEAMFORMER PASS"; else echo "RX_BEAMFORMER FAIL"; exit 1; fi
