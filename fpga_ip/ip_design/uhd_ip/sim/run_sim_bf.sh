#!/usr/bin/env bash
# Simulate tx_beamformer (with the unmodified beamformer_1.0 datapath,
# src/beamformer_v1_0.sv + src/beamformer_channel.sv) with xsim
# for every (N_CH, BEAT_W) a v49 build uses, then check every beat with
# check_bf.py (bit-exact bypass, the IP's exact arithmetic, atomic weight /
# enable switching, no lost / duplicated / reordered beats).
#   ./run_sim_bf.sh        (needs Vivado 2021.1 on PATH or at VIVADO_ROOT)
# COMBOS overrides the list ("N:BEAT_W:ACLK_PS ..."); the converter clock is
# the build's fabric clock, s_axi is 100 MHz. Every combo runs with PIPE=0
# (the IP) and PIPE=1 (re-pipelined core); PIPES overrides ("0 1").
# Builds in build_bf_<N>_<W>_<ps>_p<PIPE>/.
set -euo pipefail
cd "$(dirname "$0")"
VIVADO_ROOT=${VIVADO_ROOT:-$(v=$(command -v vivado) && dirname "$(dirname "$(readlink -f "$v")")" || echo /tools/Xilinx/Vivado/2021.1)}
source "$VIVADO_ROOT/settings64.sh"
XPM=$VIVADO_ROOT/data/ip/xpm
IP=${BF_IP_HDL:-$PWD/../src}
HERE=$PWD

# N:BEAT_W:aclk period (ps) -- zcu216_uhd_v49.tcl v49_geometry rows with N >= 2
# (1024: the sc8max 8ch F3 / 16ch F6 builds at 187.5 MHz)
COMBOS=${COMBOS:-"2:128:3333 2:256:3333 4:128:3333 4:256:3333 4:512:3333 \
8:256:6667 8:256:3333 8:512:3333 16:512:16667 16:512:6667 16:512:3333 \
8:1024:5333 16:1024:5333"}

fail=0
for P in ${PIPES:-0 1}; do
for c in $COMBOS; do
    IFS=: read -r N BW PS <<< "$c"
    work=build_bf_${N}_${BW}_${PS}_p${P}
    echo "== tx_beamformer N_CH=$N BEAT_W=$BW PIPE=$P aclk ${PS} ps"
    mkdir -p "$work" && cd "$work"
    python3 "$HERE/check_bf.py" gen --nch "$N" --out weights.hex > gen.log
    xvlog -sv "$XPM/xpm_cdc/hdl/xpm_cdc.sv" --work xpm=xsim.dir/xpm > xvlog_xpm.log
    xvlog -sv "$IP/beamformer_channel.sv" "$IP/beamformer_v1_0.sv" > xvlog_ip.log
    xvlog "$VIVADO_ROOT/data/verilog/src/glbl.v" "$HERE/../src/tx_beamformer.v" > xvlog_rtl.log
    xvlog -sv "$HERE/tb_tx_beamformer.sv" > xvlog_tb.log
    xelab -L xpm -debug off --timescale 1ns/1ps -generic_top "N_CH=$N" -generic_top "BEAT_W=$BW" \
          -generic_top "ACLK_PS=$PS" -generic_top "PIPE=$P" tb_tx_beamformer glbl -s tb > xelab.log
    xsim tb -runall -testplusarg LOG=bf.log -log xsim.log > /dev/null
    grep -E "ERROR|Fatal|TB_DONE|LATENCY" xsim.log | head -20 || true
    grep -q "TB_ERRORS=0" xsim.log || fail=1
    python3 "$HERE/check_bf.py" check bf.log || fail=1
    cd "$HERE"
done
done

# an illegal geometry must fail elaboration
mkdir -p build_bf_bad && cd build_bf_bad
xvlog -sv "$IP/beamformer_channel.sv" "$IP/beamformer_v1_0.sv" > xvlog_ip.log
xvlog "$HERE/../src/tx_beamformer.v" > xvlog_rtl.log
if xelab -L xpm -debug off tx_beamformer -generic_top N_CH=16 -generic_top BEAT_W=256 -s bad > xelab_bad.log 2>&1; then
    echo "FAIL: N_CH 16 x BEAT_W 256 elaborated"; fail=1
else
    echo "illegal N_CH 16 x BEAT_W 256: elaboration refused (ok)"
fi
cd "$HERE"

if [ $fail = 0 ]; then echo "TX_BEAMFORMER PASS"; else echo "TX_BEAMFORMER FAIL"; exit 1; fi
