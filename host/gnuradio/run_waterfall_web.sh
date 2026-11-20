#!/usr/bin/env bash
# run_waterfall_web.sh <N> [server options] -- the GPU waterfall in a web page:
# a small HTTP server (as root through uhd-rfsoc, DPDK) streams the spectrum
# lines of every channel to the browser, which draws the waterfalls. Same
# pipeline as run_waterfall.sh (UHD -> GPU: window, cuFFT, average or peak-hold),
# standard library only on the Python side.
#
#   run_waterfall_web.sh 4 --addr <board-ip>            # then open http://127.0.0.1:8080
#   run_waterfall_web.sh 16 --addr <board-ip> --port 9000
#   run_waterfall_web.sh 2 -r 625e6 -f 1.1e9 --nfft 8192
#   run_waterfall_web.sh 1 --sim 1                      # synthetic source, no board
#   N: 1, 2, 4, 8, 16 (the board must have an N-channel build). Options: see
#   `python3 rfsoc_spectrogram/rfsoc_waterfall_web.py --help` (-r, -f, --gain,
#   --nfft, --overlap, --bins, --rows, --otw, --extra, --sim, --host, --port).
#
# Listens on 127.0.0.1 only: the page retunes the radio. --host 0.0.0.0 opens
# it to the network (then anyone who can reach the port can retune the board).
# Needs the same as run_waterfall.sh (CUDA GPU, nvcc, cmake, libuhd-dev); the
# library rfsoc_spectrogram/build/librfsoc_waterfall.so is built on first use.
# Only one process can own the board: stop the GNU Radio flowgraph first.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
LIB=$D/rfsoc_spectrogram
[ $# -ge 1 ] || { sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2; }
N=$1; shift

if [ ! -e "$LIB/build/librfsoc_waterfall.so" ]; then
    echo "building $LIB/build/librfsoc_waterfall.so" >&2
    cmake -S "$LIB" -B "$LIB/build" -DCMAKE_BUILD_TYPE=Release > /dev/null
    cmake --build "$LIB/build" -j "$(nproc)" > /dev/null
fi
# sudo drops PYTHONPATH, so it is handed over through env
exec uhd-rfsoc env "PYTHONPATH=$LIB${PYTHONPATH:+:$PYTHONPATH}" python3 "$LIB/rfsoc_waterfall_web.py" --nch "$N" "$@"
