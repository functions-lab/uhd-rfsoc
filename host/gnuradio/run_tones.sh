#!/usr/bin/env bash
# run_tones.sh [<board>] <family> <N> [flowgraph options] -- compile one tones
# flowgraph (grc/<board>_tones_<family>_<N>ch.grc) and run it with the ZCU216
# UHD module (zcu216-uhd: root for DPDK, asks for the sudo password).
#
#   run_tones.sh normal 4                    # ZCU216 4T4R, 750 MS/s per channel
#   run_tones.sh normal 4 --addr <board-ip> -f 950e6
#   run_tones.sh rfsoc4x2 normal 2           # RFSoC 4x2 2T2R, 1250 MS/s per channel
#   run_tones.sh rfsoc4x2 normal 1 -t 20e6   # tone 20 MHz above the RF centre (default 10 MHz)
#   boards: zcu216 (default): normal (N = 1, 2, 4, 8, 16), sc8max (4, 8, 16);
#           rfsoc4x2: normal (N = 1, 2)
#
# Needs the board daemon serving (it loads the matching bitstream itself) and
# a display (run it from the PC's desktop session; sudo -E keeps DISPLAY).
# The compiled .py goes to ~/.cache/zcu216_gnuradio, rebuilt when the .grc is
# newer. /usr/bin/grcc explicitly: an old GNU Radio 3.8 grcc may sit earlier
# on PATH.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
B=zcu216
case ${1:-} in zcu216|rfsoc4x2) B=$1; shift ;; esac
[ $# -ge 2 ] || { sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2; }
G=$D/grc/${B}_tones_$1_$2ch.grc
[ -f "$G" ] || { echo "no flowgraph $G; have:" >&2; ls "$D/grc" >&2; exit 2; }
OUT=${XDG_CACHE_HOME:-$HOME/.cache}/zcu216_gnuradio
mkdir -p "$OUT"
PY=$OUT/${B}_tones_$1_$2ch.py
[ "$PY" -nt "$G" ] || /usr/bin/grcc -o "$OUT" "$G" > /dev/null
shift 2
exec zcu216-uhd python3 "$PY" "$@"
