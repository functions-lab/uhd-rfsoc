#!/usr/bin/env bash
# run_waterfall.sh <N> [flowgraph options] -- compile the N-channel waterfall
# flowgraph (grc/waterfall_<N>ch.grc) and run it as root through uhd-rfsoc
# (DPDK; asks for the sudo password). Gap-free GPU spectrogram of every channel:
# the samples go from UHD to the GPU (CUDA, cuFFT), not through GNU Radio.
#
#   run_waterfall.sh 4                                  # 4 channels at 625 MS/s each
#   run_waterfall.sh 16 --addr <board-ip>               # 16 channels at 156.25 MS/s each
#   run_waterfall.sh 2 -r 625e6 -f 1.1e9 --nfft 8192    # 2 channels, rate and centre, FFT size
#   run_waterfall.sh 1 --sim 1                          # synthetic source, no board
#   N: 1, 2, 4, 8, 16 (the board must have an N-channel build); -r: per-channel
#   rate (default: N's fastest sc16 rate on the ZCU216), served from below.
#
#   SECONDS_HEADLESS=<s>  run without a display (Qt offscreen) for <s> seconds,
#                         save the window to $SNAPSHOT (default ./waterfall_<N>ch.png)
#                         and exit.
#
# Needs a CUDA GPU with the toolkit (nvcc, cuFFT), cmake and libuhd-dev: the
# library rfsoc_spectrogram/build/librfsoc_waterfall.so is built on first use.
# The compiled .py goes to ~/.cache/uhd_rfsoc_gnuradio, rebuilt when the .grc
# is newer, with GNU Radio 3.10's grcc (GRCC=<path>).
set -euo pipefail
GRCC=${GRCC:-grcc}
D=$(cd "$(dirname "$0")" && pwd)
LIB=$D/rfsoc_spectrogram
[ $# -ge 1 ] || { sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2; }
N=$1; shift
G=$D/grc/waterfall_${N}ch.grc
[ -f "$G" ] || { echo "no flowgraph $G; have:" >&2; ls "$D/grc" | grep waterfall >&2; exit 2; }

if [ ! -e "$LIB/build/librfsoc_waterfall.so" ]; then
    echo "building $LIB/build/librfsoc_waterfall.so" >&2
    cmake -S "$LIB" -B "$LIB/build" -DCMAKE_BUILD_TYPE=Release > /dev/null
    cmake --build "$LIB/build" -j "$(nproc)" > /dev/null
fi

OUT=${XDG_CACHE_HOME:-$HOME/.cache}/uhd_rfsoc_gnuradio
mkdir -p "$OUT"
PY=$OUT/waterfall_${N}ch.py
export GRC_BLOCKS_PATH=$LIB${GRC_BLOCKS_PATH:+:$GRC_BLOCKS_PATH}
[ "$PY" -nt "$G" ] && [ "$PY" -nt "$LIB/rfsoc_spectrogram.block.yml" ] || "$GRCC" -o "$OUT" "$G" > /dev/null
export PYTHONPATH=$LIB${PYTHONPATH:+:$PYTHONPATH}
if [ -n "${SECONDS_HEADLESS:-}" ]; then
    export QT_QPA_PLATFORM=offscreen
    export UHD_RFSOC_GR_SNAPSHOT=${SNAPSHOT:-$PWD/waterfall_${N}ch.png} UHD_RFSOC_GR_SNAPSHOT_S=$SECONDS_HEADLESS
fi
# sudo drops PYTHONPATH, so it is handed over through env
exec uhd-rfsoc env "PYTHONPATH=$PYTHONPATH" python3 "$PY" "$@"
