#!/usr/bin/env bash
# rfsoc/get_bitstreams.sh -- fetch ONE prebuilt bitstream set, not all of them.
#
#   rfsoc/get_bitstreams.sh <board> <pynq-version>    e.g.  zcu216 2.7
#   rfsoc/get_bitstreams.sh <user@board>              e.g.  xilinx@<board-ip>
#   rfsoc/get_bitstreams.sh -n|--dry-run ...          only say what it would do
#
# Run on the PC, in a checkout of this repository. The prebuilt bitstreams
# are the bitstreams/ submodule: one set per PYNQ version and board,
# bitstreams/pynq<version>/<board>/, six sets and ~2 GB in all. A board uses
# one. This fetches only that set (ZCU216 ~500 MB of files, RFSoC 4x2 ~200 MB;
# less over the network) at the commit this repository pins, and checks it
# against its SHA256SUMS. Needs git >= 2.25 and no account: the bitstream
# repository is public and fetched over https.
#
#   <board> <pynq-version>   board: zcu216, rfsoc4x2; version: 2.7, 3.0, 3.1.
#                            Fetch that set; install it with
#                            rfsoc/push_bitstreams.sh.
#   <user@board>             ask the board over ssh which board and PYNQ
#                            version it is, fetch that set and copy it to the
#                            board (rfsoc/push_bitstreams.sh).
#
#   -n, --dry-run            name the set (with <user@board>: the board and
#                            PYNQ version it reports) and say whether it
#                            exists. Downloads no bitstream, copies nothing.
#
# Run it again for another set: sets already fetched are kept. A full
# checkout (git submodule update --init bitstreams) has every set and is
# left as it is.
#
# A board or PYNQ version without a prebuilt set is refused before anything
# is downloaded, with the list of the sets that exist; such a set has to be
# built (fpga/README.md). Exit status: 0 done, 1 failed, 2 wrong usage.
set -euo pipefail
usage() { sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; }
DRY=0
case ${1:-} in -h|--help) usage; exit 0 ;; -n|--dry-run) DRY=1; shift ;; esac
if [[ $# -lt 1 || $# -gt 2 ]]; then usage >&2; exit 2; fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
SUB=$ROOT/bitstreams
TARGET=
die() { echo "get_bitstreams: $*" >&2; exit 1; }

# ---- which set -------------------------------------------------------------
if [[ $# -eq 1 ]]; then
    TARGET=$1
    [[ $TARGET == *@* ]] || { echo "get_bitstreams: one argument must be <user@board>; or give <board> <pynq-version> (e.g. zcu216 2.7)" >&2; exit 2; }
    # line 1: the board's name as PYNQ has it; line 2: the version of its pynq package
    rc=0
    info=$($SSH "$TARGET" 'tr -d "\0" 2>/dev/null < /proc/device-tree/chosen/pynq_board; echo;
        PY=/usr/local/share/pynq-venv/bin/python3; [ -x $PY ] || PY=python3;
        $PY -c "import importlib.metadata as m; print(m.version(\"pynq\"))" 2>/dev/null ||
        $PY -c "import pkg_resources as p; print(p.get_distribution(\"pynq\").version)" 2>/dev/null; true') || rc=$?
    [[ $rc -eq 0 ]] || die "cannot reach $TARGET over ssh (exit $rc): check the address and that 'ssh $TARGET' works without a password (ssh-copy-id $TARGET). Or name the set yourself: $0 <board> <pynq-version>"
    BOARD=$(sed -n 1p <<<"$info" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
    VER=$(sed -n 2p <<<"$info" | tr -d '[:space:]')
    [[ -n $BOARD ]] || die "$TARGET does not say which board it is (no /proc/device-tree/chosen/pynq_board): is it running a PYNQ image? Or name the set yourself: $0 <board> <pynq-version>"
    [[ -n $VER ]] || die "$TARGET is a $BOARD, but its PYNQ version could not be read (no Python package 'pynq'). Name the set yourself: $0 $BOARD <pynq-version>"
    echo "$TARGET is a $BOARD with PYNQ $VER"
    VER=$(cut -d. -f1,2 <<<"$VER")
else
    BOARD=$(tr 'A-Z' 'a-z' <<<"$1")
    VER=${2#pynq}; VER=${VER#v}
    [[ $VER =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && VER=$(cut -d. -f1,2 <<<"$VER")
fi
[[ $BOARD =~ ^[a-z0-9_-]+$ && $VER =~ ^[0-9]+\.[0-9]+$ ]] || { echo "get_bitstreams: not a board and a PYNQ version: '$BOARD' '$VER' (e.g. zcu216 2.7)" >&2; exit 2; }
SET=pynq$VER/$BOARD

# ---- the pinned commit of the bitstream repository, without its files --------
command -v git > /dev/null || die "git is not installed"
cd "$ROOT"
git rev-parse --git-dir > /dev/null 2>&1 || die "$ROOT is not a git checkout of uhd-rfsoc (a source archive has no submodule pin): git clone the repository"
URL=$(git config -f .gitmodules submodule.bitstreams.url) || die "no bitstreams submodule in $ROOT/.gitmodules"
PIN=$(git rev-parse -q --verify HEAD:bitstreams) || die "this checkout does not pin a bitstreams/ commit"
git submodule --quiet init bitstreams

FULL=0 NEW=0
if [[ ! -e $SUB/.git ]]; then
    [[ -z $(ls -A "$SUB" 2>/dev/null) ]] || die "$SUB holds files but is not a git checkout: move them away and run this again"
    git sparse-checkout -h > /dev/null 2>&1 || [[ $? -eq 129 ]] || die "this git ($(git --version)) has no sparse-checkout: git 2.25 or newer is needed"
    git init --quiet "$SUB"
    git -C "$SUB" remote add origin "$URL"
    NEW=1
    git -C "$SUB" config remote.origin.promisor true
    git -C "$SUB" config remote.origin.partialclonefilter blob:none
    git -C "$SUB" sparse-checkout init --cone        # ours from the start: only what is asked for
elif [[ $(git -C "$SUB" config --type=bool core.sparseCheckout 2>/dev/null || echo false) != true ]]; then
    FULL=1                                           # git submodule update --init: every set
fi

# The repository is public: fetch over https, which needs no key. If the
# submodule URL is an SSH one, its https form is tried first.
if [[ $FULL -eq 0 ]]; then
    HTTPS=$(sed -E 's|^git@([^:]+):|https://\1/|; s|^ssh://git@|https://|' <<<"$URL")
    if [[ $HTTPS == https://* ]] && GIT_TERMINAL_PROMPT=0 git ls-remote "$HTTPS" HEAD > /dev/null 2>&1; then
        git -C "$SUB" remote set-url origin "$HTTPS"
    else
        git -C "$SUB" remote set-url origin "$URL"
    fi
fi
FROM=$(git -C "$SUB" remote get-url origin 2>/dev/null || echo "$URL")
if ! git -C "$SUB" cat-file -e "$PIN^{commit}" 2>/dev/null; then
    [[ $FULL -eq 0 ]] || die "bitstreams/ is a full checkout but not of the pinned commit $PIN: git submodule update bitstreams"
    GIT_TERMINAL_PROMPT=0 git -C "$SUB" fetch --quiet --depth 1 --filter=blob:none origin "$PIN" || {
        [[ $NEW -eq 0 ]] || rm -rf "$SUB/.git"       # leave no half-made checkout behind
        die "could not fetch the bitstream repository ($FROM): no network connection, or GitHub refused. Check 'git ls-remote $FROM'. Other ways to get a set: README.md, \"Bitstreams\""
    }
fi

# ---- is there such a set? decided before anything is downloaded -------------
SETS=$(git -C "$SUB" ls-tree -r -d --name-only "$PIN" | grep -E '^pynq[0-9.]+/[^/]+$' || true)
if ! git -C "$SUB" cat-file -e "$PIN:$SET" 2>/dev/null; then
    {
        if ! grep -q "/$BOARD\$" <<<"$SETS"; then
            echo "get_bitstreams: no prebuilt bitstreams for the board '$BOARD'."
        elif ! grep -q "^pynq$VER/" <<<"$SETS"; then
            echo "get_bitstreams: no prebuilt bitstreams for PYNQ $VER."
        else
            echo "get_bitstreams: no prebuilt bitstreams for '$BOARD' with PYNQ $VER."
        fi
        echo "The prebuilt sets (board, PYNQ version):"
        sed 's|^pynq\(.*\)/\(.*\)$|    \2 \1|' <<<"$SETS"
        echo "Another board or PYNQ version needs its own build: fpga/README.md (\"Add a board\", \"PYNQ versions\")."
        [[ -z $TARGET ]] || echo "Nothing was copied to $TARGET."
    } >&2
    exit 1
fi

if [[ $DRY -eq 1 ]]; then
    have="not fetched yet"; [[ -f $SUB/$SET/SHA256SUMS ]] && have="already here"
    echo "dry run: the set is bitstreams/$SET ($(git -C "$SUB" ls-tree --name-only "$PIN:$SET" | grep -c '\.bit$') bitstreams, $have)"
    [[ -z $TARGET ]] || echo "dry run: it would be copied to $TARGET with rfsoc/push_bitstreams.sh; nothing was copied"
    exit 0
fi

# ---- fetch the set's files ----------------------------------------------------
if [[ $FULL -eq 1 ]]; then
    echo "bitstreams/ is a full checkout: every set is there"
    [[ -d $SUB/$SET ]] || die "bitstreams/$SET is missing from the checkout: git submodule update bitstreams"
else
    git -C "$SUB" sparse-checkout add "$SET"
    echo "fetching bitstreams/$SET ..."
    GIT_TERMINAL_PROMPT=0 git -C "$SUB" -c advice.detachedHead=false checkout --quiet "$PIN" ||
        die "the download of bitstreams/$SET did not finish (network?): run this again, it continues where it stopped"
fi

if command -v sha256sum > /dev/null; then SUM="sha256sum"; else SUM="shasum -a 256"; fi
[[ -f $SUB/$SET/SHA256SUMS ]] || die "bitstreams/$SET has no SHA256SUMS"
(cd "$SUB/$SET" && $SUM -c SHA256SUMS > /dev/null) ||
    die "bitstreams/$SET does not match its SHA256SUMS (a file changed or is incomplete): 'git -C bitstreams checkout -- $SET' restores it"
n=$(find "$SUB/$SET" -maxdepth 1 -name '*.bit' | wc -l | tr -d ' ')
[[ $n -gt 0 ]] || die "bitstreams/$SET holds no .bit file"
echo "bitstreams/$SET: $n bitstreams, $(du -sh "$SUB/$SET" | cut -f1), sha256 verified"

if [[ -n $TARGET ]]; then
    "$ROOT/rfsoc/push_bitstreams.sh" "$SUB/$SET" "$TARGET" ||
        die "the set is fetched but was not copied to $TARGET: fix the above, then rfsoc/push_bitstreams.sh bitstreams/$SET $TARGET"
else
    echo "install it: rfsoc/push_bitstreams.sh bitstreams/$SET <user>@<board-ip>"
fi
