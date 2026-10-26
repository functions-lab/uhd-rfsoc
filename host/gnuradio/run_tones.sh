#!/usr/bin/env bash
# run_tones.sh <N> [flowgraph options] -- compile the N-channel tones flowgraph
# (grc/tones_<N>ch.grc) and run it as root through uhd-rfsoc (DPDK; asks for
# the sudo password). Any board with N-channel builds: pick it with --addr.
#
#   run_tones.sh 4                                   # 4T4R at 625 MS/s per channel
#   run_tones.sh 1 --addr <board-ip> -r 2.5e9        # 1ch at 2500 MS/s (RFSoC 4x2)
#   run_tones.sh 4 -f 950e6 -t 20e6 --tx-phases 0,90,180,-90 --tx-amps 0.25,0.25,0.25,0.25
#   N: 1, 2, 4, 8, 16 (the board must have an N-channel build); -r: per-channel
#   rate (default: N's fastest sc16 rate on the ZCU216), served from below.
#
#   SECONDS_HEADLESS=<s>  run without a display (Qt offscreen) for <s> seconds,
#                         save the window to $SNAPSHOT (default
#                         ./tones_<N>ch.png) and exit; prints the bursts sent.
#
# Needs the board daemon serving (it loads the matching bitstream itself) and,
# unless headless, a display (run it from the PC's desktop session; sudo -E
# keeps DISPLAY). The compiled .py goes to ~/.cache/uhd_rfsoc_gnuradio,
# rebuilt when the .grc is newer, with GNU Radio 3.10's grcc (GRCC=<path>).
set -euo pipefail
GRCC=${GRCC:-grcc}
D=$(cd "$(dirname "$0")" && pwd)
[ "${1:-}" = normal ] && shift          # the old "<family> <N>" form
[ $# -ge 1 ] || { sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2; }
N=$1; shift
G=$D/grc/tones_${N}ch.grc
[ -f "$G" ] || { echo "no flowgraph $G; have:" >&2; ls "$D/grc" >&2; exit 2; }
OUT=${XDG_CACHE_HOME:-$HOME/.cache}/uhd_rfsoc_gnuradio
mkdir -p "$OUT"
PY=$OUT/tones_${N}ch.py
[ "$PY" -nt "$G" ] || "$GRCC" -o "$OUT" "$G" > /dev/null
if [ -n "${SECONDS_HEADLESS:-}" ]; then
    export QT_QPA_PLATFORM=offscreen
    export UHD_RFSOC_GR_SNAPSHOT=${SNAPSHOT:-$PWD/tones_${N}ch.png} UHD_RFSOC_GR_SNAPSHOT_S=$SECONDS_HEADLESS
fi
exec uhd-rfsoc python3 "$PY" "$@"
