#!/usr/bin/env bash
# v49_ladder.sh [STEP] -- build every v49 bitstream (`make v49-ladder`; with
# ONLY=<regex>, `make v49-templates[-245m76]`): the 250 MHz clock family at
# fs 2500 (each channel count's template, the highest rate that fits the link
# in some wire format, and every RFDC factor below it, down to 40), then the
# 245.76 MHz family's templates (fs 2457.6). See v49_geometry in
# block_designs/<design>/<design>.tcl for the tables;
# host/benchmark/oracle_builds.txt lists the same builds for the board tests.
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

# N:F:fs -- the templates first (they are tested first), then the rest of
# the ladder
BUILDS=("1:2:2500" "2:2:2500" "4:2:2500" "8:4:2500" "16:8:2500")   # templates
for f in 3 4 5 6 8 10 12 16 20 24 40; do BUILDS+=("1:$f:2500" "2:$f:2500" "4:$f:2500"); done
for f in 5 6 8 10 12 16 20 24 40; do BUILDS+=("8:$f:2500"); done
for f in 10 12 16 20 24 40; do BUILDS+=("16:$f:2500"); done
# 245.76 MHz clock family: one run-time-rate template per channel count
BUILDS+=("1:2:2457.6" "2:2:2457.6" "4:2:2457.6" "8:4:2457.6" "16:8:2457.6")

name_of() { local n=$1 f=$2 fs=$3; echo "zcu216_v49_${n}ch_qsfp_f${f}_fs${fs/./p}"; }
# implementation strategy per build (default: Vivado's). The 512-bit-beat
# templates (4ch F2, 8ch F4, 16ch F8 of both families, fabric at 312.5 /
# 307.2 MHz) miss timing by ~0.3 ns on the CMAC-side (322 MHz) tready ->
# axis_pkt_arb paths with the default strategy; Performance_ExtraTimingOpt
# closes them.
strategy_of() { case $1 in zcu216_v49_4ch_qsfp_f2_fs2500|zcu216_v49_8ch_qsfp_f4_fs2500|\
                           zcu216_v49_16ch_qsfp_f8_fs2500|zcu216_v49_4ch_qsfp_f2_fs2457p6|\
                           zcu216_v49_8ch_qsfp_f4_fs2457p6|zcu216_v49_16ch_qsfp_f8_fs2457p6)
                    echo Performance_ExtraTimingOpt ;; esac; }
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
