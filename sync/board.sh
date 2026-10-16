#!/usr/bin/env bash
# sync/board.sh -- keep each board's checkout (a git remote per board, README
# "Board") on the same branch and commit as this one.
#
#   sync/board.sh [-b <remote>] status   every board and this checkout: branch, commit, uncommitted files
#   sync/board.sh [-b <remote>] push     PC -> boards: push the current branch, check it
#                                        out on each board; its working tree follows
#   sync/board.sh -b <remote> pull       board -> PC: fast-forward the current branch to
#                                        the board's (after committing on the board)
#   sync/board.sh hooks on|off           run `push` after every commit, branch checkout,
#                                        merge, amend and rebase here (.git/hooks)
#
# The boards: the remotes in `git config board.remotes` (space-separated;
# default "zcu216"), or the one given with -b (or $BOARD_REMOTE). push and
# status go to every board; an unreachable board is reported and skipped, and
# the others are still updated. pull needs -b when there is more than one.
#
# push refuses when the board has uncommitted edits to tracked files (commit
# them there and `pull`, or discard them), and when its branch holds commits
# this checkout never had (`pull` first). A history rewritten here (amend,
# rebase) is force-pushed: the board's old commit is in this branch's reflog.
# Untracked and ignored files on the board (bitstreams, zcu216_uhd.conf) are
# never touched. The submodules stay empty on the board.
set -euo pipefail
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
g() { git -C "$ROOT" "$@"; }
HOOKS=(post-commit post-checkout post-merge post-rewrite)

ONE=${BOARD_REMOTE:-}
if [ "${1:-}" = -b ]; then ONE=${2:?"-b needs a remote"}; shift 2; fi
if [ -n "$ONE" ]; then REMOTES=("$ONE")
else read -r -a REMOTES <<< "$(g config --get board.remotes || echo zcu216)"; fi

# select board $1: REMOTE, HOST, DIR
use() {
    local url
    REMOTE=$1
    url=$(g remote get-url "$REMOTE") || { echo "no git remote $REMOTE (README \"Board\")" >&2; return 1; }
    HOST=${url%%:*}; DIR=${url#*:}
}
rsh() { ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "cd '$DIR' && $*"; }

branch() { g symbolic-ref -q --short HEAD || { echo "detached HEAD here: check out a branch" >&2; return 1; }; }

status_one() {
    rsh 'echo "'"$REMOTE"' $(git symbolic-ref -q --short HEAD || echo DETACHED) $(git rev-parse --short HEAD)"; git status --short --untracked-files=no | sed "s/^/      /"'
}

push_one() {
    local b rb lease=() cur dirty
    b=$(branch)
    dirty=$(rsh 'git status --porcelain --untracked-files=no')
    [ -z "$dirty" ] || { echo "$REMOTE has uncommitted changes to tracked files; commit them there and run sync/board.sh -b $REMOTE pull, or discard them:" >&2; echo "$dirty" >&2; return 1; }
    g fetch -q "$REMOTE"
    if rb=$(g rev-parse -q --verify "refs/remotes/$REMOTE/$b"); then
        if ! g merge-base --is-ancestor "$rb" HEAD; then
            g rev-list -g "$b" 2>/dev/null | grep -qx "$rb" || {
                echo "$REMOTE's $b has commits this checkout never had ($(g rev-parse --short "$rb")): run sync/board.sh -b $REMOTE pull first" >&2; return 1; }
            lease=("--force-with-lease=$b:$rb")
        fi
    fi
    g push -q "${lease[@]}" "$REMOTE" "$b"
    cur=$(rsh 'git symbolic-ref -q --short HEAD || true')
    [ "$cur" = "$b" ] || rsh "git checkout -q '$b'"
    [ "$(rsh 'git rev-parse HEAD')" = "$(g rev-parse HEAD)" ] || { echo "$REMOTE is not at $(g rev-parse --short HEAD) after the push" >&2; return 1; }
    echo "$REMOTE: $b at $(g rev-parse --short HEAD)"
}

pull_one() {
    local b rb
    b=$(branch)
    [ -z "$(rsh 'git status --porcelain --untracked-files=no')" ] || echo "note: $REMOTE has uncommitted changes; only its commits come over" >&2
    g fetch -q "$REMOTE"
    rb=$(g rev-parse -q --verify "refs/remotes/$REMOTE/$b") || { echo "$REMOTE has no branch $b" >&2; return 1; }
    if g merge-base --is-ancestor "$rb" HEAD; then echo "up to date: $REMOTE's $b holds nothing new"; return 0; fi
    g merge --ff-only "$rb"
}

# run $1_one on every board; a failing board does not stop the others
each() {
    local rc=0 r
    for r in "${REMOTES[@]}"; do
        if use "$r"; then "$1_one" || { rc=1; echo "$r: $1 failed" >&2; }; else rc=1; fi
    done
    return $rc
}

hooks() {
    local d
    d=$(g rev-parse --git-path hooks)
    case ${1:-} in
    on)
        for h in "${HOOKS[@]}"; do
            [ ! -e "$d/$h" ] || grep -q 'sync/board.sh' "$d/$h" || { echo "$d/$h exists and is not ours; left alone" >&2; continue; }
            cat > "$d/$h" <<'EOF'
#!/bin/sh
# installed by sync/board.sh hooks on: keep the boards' checkouts in step
# (post-checkout: only a branch checkout, $3 = 1). Never fails the git command.
[ "$(basename "$0")" = post-checkout ] && [ "$3" != 1 ] && exit 0
"$(git rev-parse --show-toplevel)/sync/board.sh" push 2>&1 | sed 's/^/[board sync] /'
exit 0
EOF
            chmod +x "$d/$h"
        done
        echo "hooks on: ${HOOKS[*]} run sync/board.sh push (boards: ${REMOTES[*]})" ;;
    off)
        for h in "${HOOKS[@]}"; do
            [ -e "$d/$h" ] && grep -q 'sync/board.sh' "$d/$h" && rm -f "$d/$h"
        done
        echo "hooks off" ;;
    *) echo "usage: $0 hooks on|off" >&2; return 2 ;;
    esac
}

case ${1:-} in
status)
    echo "PC    $(g symbolic-ref -q --short HEAD || echo DETACHED) $(g rev-parse --short HEAD)"
    g status --short --untracked-files=no | sed 's/^/      /'
    each status ;;
push) each push ;;
pull)
    [ "${#REMOTES[@]}" = 1 ] || { echo "several boards (${REMOTES[*]}): sync/board.sh -b <remote> pull" >&2; exit 2; }
    use "${REMOTES[0]}"; pull_one ;;
hooks) hooks "${2:-}" ;;
*) sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
