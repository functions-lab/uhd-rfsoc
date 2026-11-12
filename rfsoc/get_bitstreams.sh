#!/usr/bin/env bash
# rfsoc/get_bitstreams.sh -- fetch ONE prebuilt bitstream set, not all of them.
#
#   rfsoc/get_bitstreams.sh <board> <pynq-version>    e.g.  zcu216 2.7
#   rfsoc/get_bitstreams.sh <user@board>              e.g.  xilinx@<board-ip>
#
# Run on the PC, in a checkout of this repository. The prebuilt bitstreams
# are the bitstreams/ submodule: one set per PYNQ version and board,
# bitstreams/pynq<version>/<board>/, six sets and ~2 GB in all. A board uses
# one. This fetches only that set (ZCU216 ~500 MB of files, RFSoC 4x2 ~200 MB;
# less over the network) at the commit this repository pins, and checks it
# against its SHA256SUMS. Needs an SSH key registered with GitHub, like the
# submodule itself, and git >= 2.25.
#
#   <board> <pynq-version>   board: zcu216, rfsoc4x2; version: 2.7, 3.0, 3.1.
#                            Fetch that set; install it with
#                            rfsoc/push_bitstreams.sh.
#   <user@board>             ask the board over ssh which board and PYNQ
#                            version it is, fetch that set and copy it to the
#                            board (rfsoc/push_bitstreams.sh).
#
# Run it again for another set: sets already fetched are kept. A full
# checkout (git submodule update --init bitstreams) has every set and is
# left as it is.
set -euo pipefail
usage() { sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; }
case ${1:-} in -h|--help) usage; exit 0 ;; esac
if [[ $# -lt 1 || $# -gt 2 ]]; then usage >&2; exit 2; fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
TARGET=

if [[ $# -eq 1 ]]; then
    TARGET=$1
    [[ $TARGET == *@* ]] || { echo "one argument must be <user@board>; or give <board> <pynq-version>" >&2; exit 2; }
    # the board's name as PYNQ has it, and the version of its pynq package
    info=$($SSH "$TARGET" 'tr -d "\0" < /proc/device-tree/chosen/pynq_board; echo;
        PY=/usr/local/share/pynq-venv/bin/python3; [ -x $PY ] || PY=python3;
        $PY -c "import importlib.metadata as m; print(m.version(\"pynq\"))" 2>/dev/null ||
        $PY -c "import pkg_resources as p; print(p.get_distribution(\"pynq\").version)"') ||
        { echo "could not ask $TARGET for its board and PYNQ version (ssh, or no PYNQ image?); give <board> <pynq-version> instead" >&2; exit 1; }
    BOARD=$(sed -n 1p <<<"$info" | tr 'A-Z' 'a-z')
    VER=$(sed -n 2p <<<"$info" | cut -d. -f1,2)
    echo "$TARGET is a $BOARD with PYNQ $VER"
else
    BOARD=$(tr 'A-Z' 'a-z' <<<"$1")
    VER=${2#pynq}
fi
[[ $BOARD =~ ^[a-z0-9]+$ && $VER =~ ^[0-9]+\.[0-9]+$ ]] || { echo "not a board and a PYNQ version: '$BOARD' '$VER' (e.g. zcu216 2.7)" >&2; exit 2; }
SET=pynq$VER/$BOARD
SUB=$ROOT/bitstreams

cd "$ROOT"
URL=$(git config -f .gitmodules submodule.bitstreams.url)
PIN=$(git rev-parse HEAD:bitstreams)
git submodule --quiet init bitstreams

if [[ -e $SUB/.git && $(git -C "$SUB" config --type=bool core.sparseCheckout || echo false) != true ]]; then
    echo "bitstreams/ is a full checkout: every set is there"
else
    if [[ ! -e $SUB/.git ]]; then
        git init --quiet "$SUB"
        git -C "$SUB" remote add origin "$URL"
        git -C "$SUB" config remote.origin.promisor true
        git -C "$SUB" config remote.origin.partialclonefilter blob:none
        git -C "$SUB" sparse-checkout set --cone "$SET"
    else
        git -C "$SUB" sparse-checkout add "$SET"
    fi
    # the pinned commit without its files, then only this set's
    git -C "$SUB" fetch --quiet --depth 1 --filter=blob:none origin "$PIN"
    echo "fetching bitstreams/$SET ..."
    git -C "$SUB" -c advice.detachedHead=false checkout --quiet "$PIN"
fi

[[ -d $SUB/$SET ]] || {
    echo "no set $SET in the bitstream repository at $PIN; it has:" >&2
    git -C "$SUB" ls-tree -d --name-only "$PIN" $(git -C "$SUB" ls-tree -d --name-only "$PIN" | sed 's|$|/|') | grep '^pynq.*/' >&2
    exit 1
}
if command -v sha256sum > /dev/null; then SUM="sha256sum"; else SUM="shasum -a 256"; fi
(cd "$SUB/$SET" && $SUM -c --quiet SHA256SUMS) || { echo "bitstreams/$SET does not match its SHA256SUMS" >&2; exit 1; }
n=$(ls "$SUB/$SET"/*.bit | wc -l | tr -d ' ')
echo "bitstreams/$SET: $n bitstreams, $(du -sh "$SUB/$SET" | cut -f1), sha256 verified"

if [[ -n $TARGET ]]; then
    "$ROOT/rfsoc/push_bitstreams.sh" "$SUB/$SET" "$TARGET"
else
    echo "install it: rfsoc/push_bitstreams.sh bitstreams/$SET <user>@<board-ip>"
fi
