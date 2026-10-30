#!/usr/bin/env bash
# ladder.sh <board> [STEP] -- build a board's bitstreams from
# fpga/boards/<board>/builds.txt (`make -C fpga BOARD=<board> templates` /
# `ladder`), several at a time, each with its implementation strategy.
#
#   STEP             bd | synth | bit (default bit; bd checks every block design fast)
#   KIND=<kind>      only the builds of that kind (template | ladder); empty = all
#   FS=<MS/s>        only the builds at that converter rate
#   ONLY=<regex>     only the builds whose name matches
#   MAXPAR=2         builds at a time (each needs ~10-16 GB of RAM)
#   MIN_FREE_GB=12   start the next build only with this much disk free
#   JOBS=6           Vivado threads per build
#   SKIP_EXISTING=1  skip a build whose .bit is already in bitstreams/
#   V49_OUT=<dir>    output directory instead of fpga/build/<board> (the
#                    Makefile sets it per PYNQ version, flow/versions.sh builddir)
#
# Each build's Vivado project is deleted when it exits (the bitstream, .hwh and
# reports are copied out first; V49_KEEP_PROJ=1 keeps projects). Logs:
# <output dir>/logs/<name>.log; a summary at the end. Exit status 1 if
# any build failed or missed timing.
set -o pipefail   # (no -u: an empty associative array counts as unset in bash 5.1)
FPGA=$(cd "$(dirname "$0")/.." && pwd)
BOARD=${1:?usage: ladder.sh <board> [STEP]}
STEP=${2:-bit}
LIST=$FPGA/boards/$BOARD/builds.txt
[ -f "$LIST" ] || { echo "no $LIST" >&2; exit 2; }
MAXPAR=${MAXPAR:-2}; MIN_FREE_GB=${MIN_FREE_GB:-12}; JOBS=${JOBS:-6}
OUT=${V49_OUT:-$FPGA/build/$BOARD}; LOGS=$OUT/logs; mkdir -p "$LOGS"; OUT=$(cd "$OUT" && pwd)
export V49_OUT=$OUT

name_of() { local n=$1 f=$2 fs=$3; echo "${BOARD}_v49_${n}ch_qsfp_f${f}_fs${fs/./p}"; }
free_gb() { df -BG --output=avail "$OUT" | tail -1 | tr -dc 0-9; }

# the selected builds, "N F fs strategy" each
SEL=()
while read -r n f fs kind strategy; do
    [[ -z $n || $n == \#* ]] && continue
    [ -n "${KIND:-}" ] && [ "$kind" != "$KIND" ] && continue
    [ -n "${FS:-}" ] && ! awk -v a="$fs" -v b="$FS" 'BEGIN { exit !(a == b) }' && continue
    name=$(name_of "$n" "$f" "$fs")
    [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]] && continue
    SEL+=("$n $f $fs ${strategy:-}")
done < "$LIST"
[ ${#SEL[@]} -gt 0 ] || { echo "no build of $BOARD matches (KIND=${KIND:-} FS=${FS:-} ONLY=${ONLY:-})" >&2; exit 2; }
echo "$BOARD: ${#SEL[@]} build(s), STEP=$STEP MAXPAR=$MAXPAR JOBS=$JOBS${V49_PYNQ:+ PYNQ=$V49_PYNQ} -> $OUT"

declare -A PID
reap() {
    for k in "${!PID[@]}"; do
        kill -0 "${PID[$k]}" 2>/dev/null && continue
        echo "$(date +%T) done  $k: $(tail -1 "$LOGS/$k.log")"; unset "PID[$k]"
    done
}
run_one() {
    local n=$1 f=$2 fs=$3 strategy=$4 name; name=$(name_of "$n" "$f" "$fs")
    (
        V49_IMPL_STRATEGY=$strategy vivado -mode batch -nojournal -nolog \
            -source "$FPGA/flow/build.tcl" -tclargs "$BOARD" "$n" "$STEP" "$JOBS" "$f" "$fs" \
            > "$LOGS/$name.log" 2>&1
        rc=$?
        [ "${V49_KEEP_PROJ:-0}" = 1 ] || rm -rf "$OUT/${name}_proj"
        echo "exit $rc" >> "$LOGS/$name.log"
    ) &
    PID[$name]=$!
    echo "$(date +%T) start $name${strategy:+ ($strategy)} (free $(free_gb) GB)"
}

for b in "${SEL[@]}"; do
    read -r n f fs strategy <<< "$b"
    name=$(name_of "$n" "$f" "$fs")
    if [ "${SKIP_EXISTING:-0}" = 1 ] && [ -f "$OUT/bitstreams/$name.bit" ]; then
        echo "skip $name (built)"; continue
    fi
    while :; do
        reap
        [ "${#PID[@]}" -lt "$MAXPAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ] && break
        sleep 30
    done
    run_one "$n" "$f" "$fs" "$strategy"
    sleep 20
done
wait
reap

echo "== summary: $BOARD ($STEP)"
bad=0
for b in "${SEL[@]}"; do
    read -r n f fs strategy <<< "$b"; name=$(name_of "$n" "$f" "$fs")
    l=$LOGS/$name.log; [ -f "$l" ] || continue
    st=$(tail -1 "$l")
    if [ "$STEP" = bit ]; then
        if [ -f "$OUT/bitstreams/$name.bit" ] && [ "$st" = "exit 0" ]; then res=OK
        elif [ -f "$OUT/bitstreams_timing_fail/$name.bit" ]; then res=TIMING; bad=1
        else res=FAILED; bad=1; fi
    else
        [ "$st" = "exit 0" ] && res=OK || { res=FAILED; bad=1; }
    fi
    printf "%-38s %-7s %s\n" "$name" "$res" \
        "$(grep -hE '^WNS|^ERROR|error:' "$l" | tail -1 | cut -c1-120)"
done
exit $bad
