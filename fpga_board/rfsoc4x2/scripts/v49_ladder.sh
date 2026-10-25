#!/usr/bin/env bash
# v49_ladder.sh [STEP] (RFSoC 4x2) -- build every v49 bitstream (`make
# v49-ladder`; with ONLY=<regex>, `make v49-templates[-245m76]`): the 250 MHz
# clock family at fs 5000 (the sc16 top factor of each channel count, 1ch F2
# / 2ch F4, every RFDC factor below it down to 40, and the sc8-only 2ch F2),
# then the 245.76 MHz family's templates (fs 4915.2). See v49_geometry in
# block_designs/<design>/<design>.tcl for the tables;
# host/benchmark/oracle_builds_rfsoc4x2.txt lists the same builds for the board tests.
#
#   STEP          bd | synth | bit (default bit; bd checks every block design fast)
#   MAXPAR=3      builds at a time
#   MIN_FREE_GB=12  start the next build only with this much disk free
#   JOBS=8        Vivado threads per build
#   ONLY=<regex>  only the builds whose name matches
#   SKIP_EXISTING=1  skip a build whose .bit is already in build/v49_qsfp/bitstreams
#
# Each build's Vivado project is deleted when it exits (the bitstream, .hwh and
# reports are copied out first; V49_KEEP_PROJ=1 keeps projects). Logs:
# build/v49_qsfp/logs/ladder_<name>.log; a summary at the end.
set -o pipefail   # (no -u: an empty associative array counts as unset in bash 5.1)
cd "$(dirname "$0")/.."
STEP=${1:-bit}
MAXPAR=${MAXPAR:-3}; MIN_FREE_GB=${MIN_FREE_GB:-12}; JOBS=${JOBS:-8}
OUT=build/v49_qsfp; LOGS=$OUT/logs; mkdir -p "$LOGS"

# N:F:fs -- the templates and the sc8-only 2ch F2 first, then the rest of the
# fs 5000 ladder
BUILDS=("1:2:5000" "2:4:5000" "2:2:5000")
for f in 3 4 5 6 8 10 12 16 20 24 40; do BUILDS+=("1:$f:5000"); done
for f in 5 6 8 10 12 16 20 24 40; do BUILDS+=("2:$f:5000"); done
# 245.76 MHz clock family: one run-time-rate template per channel count
BUILDS+=("1:2:4915.2" "2:2:4915.2")

name_of() { local n=$1 f=$2 fs=$3; echo "rfsoc4x2_v49_${n}ch_qsfp_f${f}_fs${fs/./p}"; }
# implementation strategy per build (default: Vivado's). On this part
# (xczu48dr) these builds miss timing by 0.02-0.24 ns with the default
# strategy, each on a routing-dominated path in the CMAC 322 MHz domain
# (udp_player / axis_pkt_arb); Performance_ExtraTimingOpt closes them, except
# 2ch F16, which needs Performance_Explore.
strategy_of() {
    case $1 in
        rfsoc4x2_v49_1ch_qsfp_f2_fs4915p2|rfsoc4x2_v49_2ch_qsfp_f2_fs4915p2|\
        rfsoc4x2_v49_1ch_qsfp_f2_fs5000|rfsoc4x2_v49_2ch_qsfp_f2_fs5000|rfsoc4x2_v49_1ch_qsfp_f10_fs5000|rfsoc4x2_v49_1ch_qsfp_f20_fs5000|rfsoc4x2_v49_2ch_qsfp_f5_fs5000)
            echo Performance_ExtraTimingOpt ;;
        rfsoc4x2_v49_2ch_qsfp_f16_fs5000)
            echo Performance_Explore ;;
    esac
}
free_gb() { df -BG --output=avail "$OUT" | tail -1 | tr -dc 0-9; }

declare -A PID
run_one() {
    local n=$1 f=$2 fs=$3 name; name=$(name_of "$n" "$f" "$fs")
    (
        V49_IMPL_STRATEGY=$(strategy_of "$name") vivado -mode batch -nojournal -nolog -source scripts/v49_build.tcl \
            -tclargs "$n" "$STEP" "$JOBS" "$f" "$fs" > "$LOGS/ladder_$name.log" 2>&1
        rc=$?
        [ "${V49_KEEP_PROJ:-0}" = 1 ] || rm -rf "$OUT/${name}_proj"
        echo "exit $rc" >> "$LOGS/ladder_$name.log"
    ) &
    PID[$name]=$!
    echo "$(date +%T) start $name (free $(free_gb) GB)"
}

for b in "${BUILDS[@]}"; do
    IFS=: read -r n f fs <<< "$b"
    name=$(name_of "$n" "$f" "$fs")
    [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]] && continue
    if [ "${SKIP_EXISTING:-0}" = 1 ] && [ -f "$OUT/bitstreams/$name.bit" ]; then
        echo "skip $name (built)"; continue
    fi
    while :; do
        for k in "${!PID[@]}"; do kill -0 "${PID[$k]}" 2>/dev/null || { echo "$(date +%T) done  $k: $(tail -1 "$LOGS/ladder_$k.log")"; unset "PID[$k]"; }; done
        [ "${#PID[@]}" -lt "$MAXPAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ] && break
        sleep 30
    done
    run_one "$n" "$f" "$fs"
    sleep 20
done
wait
for k in "${!PID[@]}"; do echo "$(date +%T) done  $k: $(tail -1 "$LOGS/ladder_$k.log")"; done

echo "== summary ($STEP)"
for b in "${BUILDS[@]}"; do
    IFS=: read -r n f fs <<< "$b"; name=$(name_of "$n" "$f" "$fs")
    [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]] && continue
    l=$LOGS/ladder_$name.log; [ -f "$l" ] || continue
    printf "%-38s %-8s %s\n" "$name" "$(tail -1 "$l")" \
        "$(grep -hE '^WNS|^ERROR|error:' "$l" | tail -1 | cut -c1-120)"
done
