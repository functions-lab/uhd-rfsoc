#!/usr/bin/env bash
# sync/board.sh -- keep the board's checkout (git remote `zcu216`, README
# "Board") on the same branch and commit as this one.
#
#   sync/board.sh status        both sides: branch, commit, uncommitted files
#   sync/board.sh push          PC -> board: push the current branch, check it
#                               out on the board; its working tree follows
#   sync/board.sh pull          board -> PC: fast-forward the current branch to
#                               the board's (after committing on the board)
#   sync/board.sh hooks on|off  run `push` after every commit, branch checkout,
#                               merge, amend and rebase here (.git/hooks)
#
# push refuses when the board has uncommitted edits to tracked files (commit
# them there and `pull`, or discard them), and when its branch holds commits
# this checkout never had (`pull` first). A history rewritten here (amend,
# rebase) is force-pushed: the board's old commit is in this branch's reflog.
# Untracked and ignored files on the board (bitstreams, zcu216_uhd.conf) are
# never touched. The submodules stay empty on the board. Remote: $BOARD_REMOTE
# (default zcu216).
set -euo pipefail
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
REMOTE=${BOARD_REMOTE:-zcu216}
URL=$(git -C "$ROOT" remote get-url "$REMOTE") || { echo "no git remote $REMOTE (README \"Board\")" >&2; exit 1; }
HOST=${URL%%:*}; DIR=${URL#*:}
g() { git -C "$ROOT" "$@"; }
rsh() { ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "cd '$DIR' && $*"; }
HOOKS=(post-commit post-checkout post-merge post-rewrite)

branch() { g symbolic-ref -q --short HEAD || { echo "detached HEAD here: check out a branch" >&2; exit 1; }; }

status() {
    echo "PC    $(g symbolic-ref -q --short HEAD || echo DETACHED) $(g rev-parse --short HEAD)"
    g status --short --untracked-files=no | sed 's/^/      /'
    rsh 'echo "board $(git symbolic-ref -q --short HEAD || echo DETACHED) $(git rev-parse --short HEAD)"; git status --short --untracked-files=no | sed "s/^/      /"'
}

push() {
    local b rb lease=() cur
    b=$(branch)
    local dirty
    dirty=$(rsh 'git status --porcelain --untracked-files=no')
    [ -z "$dirty" ] || { echo "board has uncommitted changes to tracked files; commit them there and run sync/board.sh pull, or discard them:" >&2; echo "$dirty" >&2; return 1; }
    g fetch -q "$REMOTE"
    if rb=$(g rev-parse -q --verify "refs/remotes/$REMOTE/$b"); then
        if ! g merge-base --is-ancestor "$rb" HEAD; then
            g rev-list -g "$b" 2>/dev/null | grep -qx "$rb" || {
                echo "board's $b has commits this checkout never had ($(g rev-parse --short "$rb")): run sync/board.sh pull first" >&2; return 1; }
            lease=("--force-with-lease=$b:$rb")
        fi
    fi
    g push -q "${lease[@]}" "$REMOTE" "$b"
    cur=$(rsh 'git symbolic-ref -q --short HEAD || true')
    [ "$cur" = "$b" ] || rsh "git checkout -q '$b'"
    [ "$(rsh 'git rev-parse HEAD')" = "$(g rev-parse HEAD)" ] || { echo "board is not at $(g rev-parse --short HEAD) after the push" >&2; return 1; }
    echo "board: $b at $(g rev-parse --short HEAD)"
}

pull() {
    local b rb
    b=$(branch)
    [ -z "$(rsh 'git status --porcelain --untracked-files=no')" ] || echo "note: the board has uncommitted changes; only its commits come over" >&2
    g fetch -q "$REMOTE"
    rb=$(g rev-parse -q --verify "refs/remotes/$REMOTE/$b") || { echo "the board has no branch $b" >&2; return 1; }
    if g merge-base --is-ancestor "$rb" HEAD; then echo "up to date: the board's $b holds nothing new"; return 0; fi
    g merge --ff-only "$rb"
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
# installed by sync/board.sh hooks on: keep the board's checkout in step
# (post-checkout: only a branch checkout, $3 = 1). Never fails the git command.
[ "$(basename "$0")" = post-checkout ] && [ "$3" != 1 ] && exit 0
"$(git rev-parse --show-toplevel)/sync/board.sh" push 2>&1 | sed 's/^/[board sync] /'
exit 0
EOF
            chmod +x "$d/$h"
        done
        echo "hooks on: ${HOOKS[*]} run sync/board.sh push" ;;
    off)
        for h in "${HOOKS[@]}"; do
            [ -e "$d/$h" ] && grep -q 'sync/board.sh' "$d/$h" && rm -f "$d/$h"
        done
        echo "hooks off" ;;
    *) echo "usage: $0 hooks on|off" >&2; return 2 ;;
    esac
}

case ${1:-} in
status|push|pull) "$1" ;;
hooks) hooks "${2:-}" ;;
*) sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
