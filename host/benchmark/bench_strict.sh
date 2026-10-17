#!/usr/bin/env bash
# bench_strict.sh -- one strict UHD benchmark_rate run against the ZCU216, as one
# result line. "Strict" means every error threshold is 0, so benchmark_rate's own
# exit status is the verdict (without the thresholds it exits 0 whatever happens),
# and every direction run must have moved >= 99 % of the nominal sample count:
# benchmark_rate exits 0 on a stream that only timed out (no link: rx 0 %).
#
#   benchmark/bench_strict.sh <rx|tx|rxtx> <rate per channel> [nchan] [cpu] [otw]
#   benchmark/bench_strict.sh rx 1.2e9                 # 1ch RX sc16 -> fc32 host
#   benchmark/bench_strict.sh rx 300e6 8 sc16 sc16
#   benchmark/bench_strict.sh tx 600e6 4 sc16 sc8
#
# Environment: ADDR (board LAN address) [discovery], DEV_ARGS (extra device args,
# e.g. "otw=sc8" on an sc8-only build), DUR (10 s), LOG (/tmp/zcu216_bench).
# Runs as root through zcu216-uhd (DPDK). Prints:
#   PASS|FAIL <dir> <nchan>x<rate> cpu=<> otw=<>  rx=<samples> drop=<> ovr=<> seq=<> tx=<> undr=<> late=<>  (<% of nominal>)
set -u
DIR=${1:?rx|tx|rxtx}; RATE=${2:?rate}; NCH=${3:-1}; CPU=${4:-fc32}; OTW=${5:-sc16}
DUR=${DUR:-10}; LOG=${LOG:-/tmp/zcu216_bench}; mkdir -p "$LOG"
HERE=$(cd "$(dirname "$0")" && pwd)
if command -v zcu216-uhd >/dev/null; then RUN=$(command -v zcu216-uhd); else RUN=$HERE/../tools/zcu216-uhd; fi
if [ -z "${ADDR:-}" ]; then
    ADDR=$(uhd_find_devices --args type=zcu216 2>/dev/null | awk '/^ +addr: /{print $2; exit}')
    [ -n "$ADDR" ] || { echo "no ZCU216 found by discovery; set ADDR=<board-ip>" >&2; exit 2; }
fi
A="type=zcu216,addr=$ADDR,nports=4${DEV_ARGS:+,$DEV_ARGS}"
CH=$(seq -s, 0 $((NCH - 1)))
OPTS=()
case $DIR in
  rx)   OPTS+=(--rx_rate "$RATE" --rx_channels "$CH" --rx_cpu "$CPU" --rx_otw "$OTW") ;;
  tx)   OPTS+=(--tx_rate "$RATE" --tx_channels "$CH" --tx_cpu "$CPU" --tx_otw "$OTW") ;;
  rxtx) OPTS+=(--rx_rate "$RATE" --rx_channels "$CH" --rx_cpu "$CPU" --rx_otw "$OTW"
               --tx_rate "$RATE" --tx_channels "$CH" --tx_cpu "$CPU" --tx_otw "$OTW") ;;
  *) echo "direction must be rx, tx or rxtx" >&2; exit 2 ;;
esac
F=$LOG/${DIR}_${NCH}x${RATE}_${CPU}_${OTW}.log
"$RUN" benchmark_rate --args "$A" --duration "$DUR" "${OPTS[@]}" \
    --overrun-threshold 0 --underrun-threshold 0 --drop-threshold 0 --seq-threshold 0 >"$F" 2>&1
rc=$?
num() { grep -m1 "$1" "$F" | awk '{print $NF}'; }
RX=$(num 'Num received samples:'); TX=$(num 'Num transmitted samples:')
PCT=$(python3 - "$DIR" "$RATE" "$NCH" "$DUR" "${RX:-0}" "${TX:-0}" <<'EOF'
import sys
d, rate, n, dur, rx, tx = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
nom = rate * n * dur
out, short = [], 0
if d in ("rx", "rxtx"):
    out.append("rx %.1f%%" % (100 * rx / nom)); short |= rx < 0.99 * nom
if d in ("tx", "rxtx"):
    out.append("tx %.1f%%" % (100 * tx / nom)); short |= tx < 0.99 * nom
print(", ".join(out) + (" SHORT" if short else ""))
EOF
)
V=FAIL; [ $rc -eq 0 ] && V=PASS
case $PCT in *SHORT) V="FAIL(< 99 % of the nominal samples)"; [ $rc -eq 0 ] && rc=1 ;; esac
grep -q "Num received samples" "$F" || grep -q "Num transmitted samples" "$F" || V="FAIL(no result, see $F)"
echo "$V $DIR ${NCH}x${RATE} cpu=$CPU otw=$OTW${DEV_ARGS:+ [$DEV_ARGS]}  rx=${RX:--} drop=$(num 'Num dropped samples:') ovr=$(num 'Num overruns detected:') seq=$(num 'Num sequence errors (Rx):') tx=${TX:--} undr=$(num 'Num underruns detected:') late=$(num 'Num late commands:')  ($PCT)"
exit $rc
