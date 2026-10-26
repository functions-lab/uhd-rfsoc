#!/usr/bin/env bash
# rfsoc/setup_board.sh -- one-time setup of a PYNQ board for the UHD daemon.
# Run ON THE BOARD, in its checkout of this repository (sudo is taken if
# needed). Safe to run again: every step is a no-op where it has been done.
#
#   sudo rfsoc/setup_board.sh            do the setup
#   rfsoc/setup_board.sh --check         report what is missing, change nothing
#
# Steps:
#   1. xrfdc MTS bindings: PYNQ 2.7's xrfdc Python wrapper (RFSoC 4x2 image)
#      lacks the multi-tile-sync API the daemon needs; rfsoc/xrfdc_mts_patch.py
#      adds it to the venv's copy (originals kept as *.stock) and the import
#      is verified. Images whose xrfdc already has it (PYNQ 3.x) are left alone.
#   2. rfsoc/server/uhd_rfsoc.conf from uhd_rfsoc.conf.example, if there is
#      none (never overwritten): then set data_ip in it.
#   3. Reports the bitstreams in rfsoc/server/ (rfsoc/push_bitstreams.sh or a
#      release's .bit/.hwh files put them there).
# Then: ./run_daemon.sh (top of the checkout).
#
# UHD_DAEMON_PYTHON overrides the PYNQ venv's python3 (as for run_daemon.sh).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRV=$ROOT/rfsoc/server
PY=${UHD_DAEMON_PYTHON:-/usr/local/share/pynq-venv/bin/python3}
CHECK=0
case ${1:-} in
    -h|--help) sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --check) CHECK=1 ;;
    "") ;;
    *) echo "unknown option $1 (--check, --help)" >&2; exit 2 ;;
esac
[ -x "$PY" ] || { echo "no PYNQ python at $PY: run this on the board (or set UHD_DAEMON_PYTHON)" >&2; exit 1; }
if [ "$CHECK" = 0 ] && [ "$(id -u)" != 0 ]; then
    exec sudo env UHD_DAEMON_PYTHON="$PY" "$0" "$@"
fi
# PYNQ's board name, as /etc/profile.d/boardname.sh sets it (xrfclk needs it)
BOARD=${BOARD:-$(tr -d '\0' 2>/dev/null < /proc/device-tree/chosen/pynq_board || echo ZCU216)}
export BOARD XILINX_XRT=/usr
rc=0

echo "[1] xrfdc multi-tile-sync bindings (PYNQ venv $PY, board $BOARD)"
if ! XRFDC_DIR=$("$PY" -c 'import os, xrfdc; print(os.path.dirname(os.path.abspath(xrfdc.__file__)))' 2>/dev/null); then
    echo "    cannot import xrfdc with $PY: not a PYNQ image?" >&2; exit 1
fi
if "$PY" -c 'import xrfdc, sys; sys.exit(0 if all(hasattr(xrfdc.RFdc, m) for m in ("mts_dac", "mts_adc")) else 1)'; then
    echo "    present in $XRFDC_DIR: nothing to do"
elif [ "$CHECK" = 1 ]; then
    echo "    MISSING in $XRFDC_DIR (the daemon cannot lock MTS): run 'sudo $0'"; rc=1
else
    "$PY" "$ROOT/rfsoc/xrfdc_mts_patch.py" --apply "$XRFDC_DIR" | sed 's/^/    /'
    find "$XRFDC_DIR" -name __pycache__ -type d -prune -exec rm -rf {} +
    if "$PY" -c 'import xrfdc, sys; sys.exit(0 if all(hasattr(xrfdc.RFdc, m) for m in ("mts_dac", "mts_adc")) else 1)'; then
        echo "    verified: xrfdc imports and RFdc has mts_dac / mts_adc"
    else
        echo "    xrfdc still has no MTS bindings after the patch; the originals are $XRFDC_DIR/*.stock" >&2; exit 1
    fi
fi

echo "[2] board settings $SRV/uhd_rfsoc.conf"
if [ -f "$SRV/uhd_rfsoc.conf" ]; then
    if grep -qE '^\s*data_ip\s*=\s*<' "$SRV/uhd_rfsoc.conf"; then
        echo "    exists, but data_ip is still the placeholder: set the FPGA's 100G address in it"; rc=1
    else
        echo "    exists ($(grep -E '^\s*data_ip' "$SRV/uhd_rfsoc.conf" | tr -s ' ' || true))"
    fi
elif [ "$CHECK" = 1 ]; then
    echo "    MISSING: 'sudo $0' creates it from uhd_rfsoc.conf.example"; rc=1
else
    cp "$SRV/uhd_rfsoc.conf.example" "$SRV/uhd_rfsoc.conf"
    chown --reference="$SRV/uhd_rfsoc.conf.example" "$SRV/uhd_rfsoc.conf" 2>/dev/null || true
    echo "    created from uhd_rfsoc.conf.example: set data_ip (the FPGA's address on the PC's 100G subnet) in it"; rc=1
fi

echo "[3] bitstreams in $SRV"
n=0
shopt -s nullglob
for bit in "$SRV"/*_v49_*ch_qsfp*.bit; do
    if [ -f "${bit%.bit}.hwh" ]; then echo "    $(basename "$bit")"; n=$((n + 1)); else echo "    $(basename "$bit"): no .hwh next to it (skipped by the daemon)"; fi
done
if [ "$n" = 0 ]; then
    echo "    none: copy a build's .bit + .hwh here (from the build machine: rfsoc/push_bitstreams.sh <bit_dir> <user>@<this board>; or a release's files)"; rc=1
fi

if [ "$rc" = 0 ]; then
    echo "ready: ./run_daemon.sh starts the daemon"
else
    echo "not ready yet: see above"
fi
exit $rc
