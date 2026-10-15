#!/usr/bin/env bash
# rate_sweep.sh -- run-time rate change on one template bitstream: per rate a
# UHD session asks for it (the daemon retunes in place: RFDC factor, MMCM,
# MTS) and rate_loopback.py checks a TX->RX pulse at it.
#
#   ADDR=<board-ip> DEV_ARGS=channels=8 benchmark/rate_sweep.sh 375e6 281.25e6 ... 375e6
#
# Environment: ADDR [discovery], DEV_ARGS (e.g. channels=N), CHAN (0), LOG
# (/tmp/zcu216_rate_sweep). The daemon must run with the template loaded; its
# log shows each retune and its MTS result ("RATE CHANGE", "MTS LOCKED",
# "converter clock measured"). Prints one PASS|FAIL line per rate, then a total.
set -u
[ $# -gt 0 ] || { echo "usage: rate_sweep.sh <rate>..." >&2; exit 2; }
CHAN=${CHAN:-0}; LOG=${LOG:-/tmp/zcu216_rate_sweep}; mkdir -p "$LOG"
HERE=$(cd "$(dirname "$0")" && pwd)
if command -v zcu216-uhd >/dev/null; then RUN=$(command -v zcu216-uhd); else RUN=$HERE/../tools/zcu216-uhd; fi
if [ -z "${ADDR:-}" ]; then
    ADDR=$(uhd_find_devices --args type=zcu216 2>/dev/null | awk '/^ +addr: /{print $2; exit}')
    [ -n "$ADDR" ] || { echo "no ZCU216 found by discovery; set ADDR=<board-ip>" >&2; exit 2; }
fi
A="type=zcu216,addr=$ADDR${DEV_ARGS:+,$DEV_ARGS}"
pass=0; fail=0
for r in "$@"; do
    F=$LOG/rate_${r}_ch$CHAN.log
    if timeout 300 "$RUN" python3 "$HERE/rate_loopback.py" --args "$A" --rate "$r" --chan "$CHAN" >"$F" 2>&1; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
    grep -hE '^(PASS|FAIL) ' "$F" || echo "FAIL rate $r ch$CHAN: $(tail -1 "$F")"
done
echo "rate_sweep: $pass of $# rates PASS${DEV_ARGS:+ ($DEV_ARGS)}"
[ $fail = 0 ]
