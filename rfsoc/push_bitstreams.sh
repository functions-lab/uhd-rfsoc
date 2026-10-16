#!/usr/bin/env bash
# rfsoc/push_bitstreams.sh -- copy built bitstreams to the board's checkout.
#
#   rfsoc/push_bitstreams.sh [bit_dir] [user@host] [remote_checkout]
#   defaults: fpga_board/zcu216/build/v49_qsfp/bitstreams  xilinx@zcu216-0
#   (the RFSoC 4x2: fpga_board/rfsoc4x2/build/v49_qsfp/bitstreams xilinx@rfsoc4x2-0)
#             /home/xilinx/jupyter_notebooks/rfsoc-uhd
#
# The code reaches the board by git (README "Board"); the bitstreams do not
# (tens of MB each, gitignored). Every <board>_v49_*ch_qsfp*.bit and its .hwh
# in bit_dir goes to <remote_checkout>/rfsoc/server/, the daemon's default
# --bitstream-dir, and is checked by md5 on both sides. Copies files only:
# never loads a bitstream, never starts the daemon.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIT_DIR=${1:-$ROOT/fpga_board/zcu216/build/v49_qsfp/bitstreams}
TARGET=${2:-xilinx@zcu216-0}
RDIR=${3:-/home/xilinx/jupyter_notebooks/rfsoc-uhd}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
shopt -s nullglob
files=()
for bit in "$BIT_DIR"/*_v49_*ch_qsfp*.bit; do
    hwh=${bit%.bit}.hwh
    [[ -f $hwh ]] || { echo "missing $hwh (next to $bit)" >&2; exit 1; }
    files+=("$bit" "$hwh")
done
[[ ${#files[@]} -gt 0 ]] || { echo "no *_v49_*ch_qsfp*.bit in $BIT_DIR" >&2; exit 1; }
$SSH "$TARGET" "test -d '$RDIR/rfsoc/server'" || { echo "$TARGET:$RDIR is not a checkout of this repository (git push first)" >&2; exit 1; }
rsync -a -e "$SSH" "${files[@]}" "$TARGET:$RDIR/rfsoc/server/"
names=$(for f in "${files[@]}"; do basename "$f"; done)
local_md5=$(cd "$BIT_DIR" && md5sum $names | sort -k2)
remote_md5=$($SSH "$TARGET" "cd '$RDIR/rfsoc/server' && md5sum $(echo $names)" | sort -k2)
if [[ "$local_md5" != "$remote_md5" ]]; then
    diff <(echo "$local_md5") <(echo "$remote_md5") >&2; echo "md5 mismatch after the copy" >&2; exit 1
fi
echo "$((${#files[@]} / 2)) bitstream(s) copied to $TARGET:$RDIR/rfsoc/server, md5 verified"
