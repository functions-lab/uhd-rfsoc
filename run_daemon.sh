#!/usr/bin/env bash
# run_daemon.sh -- run the UHD daemon on the board (in its checkout of this
# repository). After it says "serving", the PC finds the board with
# `uhd_find_devices --args type=zcu216` and `sudo uhd_usrp_probe --args type=zcu216`.
#
#   ./run_daemon.sh [start] [daemon options]   start in the background, wait until it serves
#   ./run_daemon.sh fg [daemon options]        run in the foreground (Ctrl-C stops it)
#   ./run_daemon.sh stop | restart | status
#   ./run_daemon.sh log                        follow the log
#
# Daemon options go to rfsoc/server/zcu216_uhd_daemon.py (e.g. --bitstream X.bit;
# its --help lists them); --allow-unlocked is always given. It loads the
# bitstreams in rfsoc/server/ (rfsoc/push_bitstreams.sh puts them there) and
# reads rfsoc/server/zcu216_uhd.conf (from zcu216_uhd.conf.example). Root via
# sudo, Python from the PYNQ venv. Log: /tmp/uhd_daemon.log (the previous
# run's: /tmp/uhd_daemon.log.1).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRV=$ROOT/rfsoc/server
PY=${PYNQ_PYTHON:-/usr/local/share/pynq-venv/bin/python3}
LOG=/tmp/uhd_daemon.log
OUT=/tmp/uhd_daemon.out

pids() { pgrep -f '[z]cu216_uhd_daemon[.]py' || true; }

addr() { ip -4 -br addr show eth0 2>/dev/null | awk '{print $3}' | cut -d/ -f1; }

check() {
    [ -x "$PY" ] || { echo "no PYNQ Python at $PY: run this on the board (or set PYNQ_PYTHON)" >&2; exit 1; }
    [ -f "$SRV/zcu216_uhd.conf" ] || { echo "no $SRV/zcu216_uhd.conf: cp $SRV/zcu216_uhd.conf.example $SRV/zcu216_uhd.conf and set data_ip" >&2; exit 1; }
    compgen -G "$SRV/*_v49_*ch_qsfp*.bit" > /dev/null || { echo "no bitstreams in $SRV: copy them with rfsoc/push_bitstreams.sh (on the PC)" >&2; exit 1; }
}

serving_hint() {
    echo "on the PC:  uhd_find_devices --args type=zcu216"
    echo "            sudo uhd_usrp_probe --args type=zcu216,addr=$(addr),channels=4   # channels=1/2/4/8/16"
}

start() {
    check
    if [ -n "$(pids)" ]; then
        echo "already running (pid $(pids | paste -sd' ')): ./run_daemon.sh restart to restart it"
        grep -h 'serving' "$LOG" 2>/dev/null | tail -n 1
        return 0
    fi
    sudo true                                   # ask for the password before going to the background
    [ -f "$LOG" ] && sudo mv -f "$LOG" "$LOG.1"
    cd "$SRV"
    sudo env BOARD=${BOARD:-ZCU216} XILINX_XRT=/usr setsid nohup "$PY" zcu216_uhd_daemon.py \
        --allow-unlocked --log "$LOG" "$@" > "$OUT" 2>&1 < /dev/null &
    echo "starting (loads the bitstream and locks MTS; ~20 s), log $LOG"
    for _ in $(seq 120); do
        sleep 1
        if l=$(grep -h 'serving' "$LOG" 2>/dev/null | tail -n 1) && [ -n "$l" ]; then
            case $l in
            *"not serving"*) echo "$l" >&2; tail -n 20 "$OUT" >&2; exit 1 ;;
            *) echo "${l#*INFO }"; serving_hint; return 0 ;;
            esac
        fi
        if [ -z "$(pids)" ]; then
            echo "the daemon exited before serving:" >&2; tail -n 30 "$OUT" >&2; exit 1
        fi
    done
    echo "not serving after 120 s; see $LOG and $OUT" >&2; exit 1
}

stop() {
    local p
    p=$(pids)
    [ -n "$p" ] || { echo "not running"; return 0; }
    sudo kill $p
    for _ in $(seq 30); do [ -z "$(pids)" ] && { echo "stopped"; return 0; }; sleep 0.5; done
    sudo kill -9 $(pids) 2>/dev/null || true
    echo "stopped (killed)"
}

status() {
    local p
    p=$(pids)
    if [ -n "$p" ]; then
        echo "running (pid $(echo $p | tr '\n' ' '))"
        grep -hE 'serving|==== now|RATE CHANGE' "$LOG" 2>/dev/null | tail -n 2 | sed 's/^[^ ]* [^ ]* [A-Z]* //'
        serving_hint
    else
        echo "not running"
    fi
}

case ${1:-start} in
start)   shift || true; start "$@" ;;
fg)      shift; check; cd "$SRV"; [ -z "$(pids)" ] || { echo "already running: ./run_daemon.sh stop first" >&2; exit 1; }
         exec sudo env BOARD=${BOARD:-ZCU216} XILINX_XRT=/usr "$PY" zcu216_uhd_daemon.py --allow-unlocked "$@" ;;
stop)    stop ;;
restart) shift; stop; start "$@" ;;
status)  status ;;
log)     exec tail -n 50 -F "$LOG" ;;
-h|--help|help) sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
-*)      start "$@" ;;
*)       echo "unknown command $1 (start, fg, stop, restart, status, log)" >&2; exit 2 ;;
esac
