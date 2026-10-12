#!/usr/bin/env bash
# Copy the ZCU216 UHD daemon (and the rfsoc_lib it needs in hardware mode) to
# the board. Copies files only: never loads a bitstream, never starts or
# enables the service.
#
#   ./deploy.sh [user@host] [remote_dir]
#   default: xilinx@zcu216-0 /home/xilinx/jupyter_notebooks/SPEAR-qsfpv
#
# Layout on the board (what find_lib_root() and the unit file expect): the
# repository's rfsoc_lib/, minus what only the PC needs (uhd/host, the UHD
# submodule uhd/uhd):
#   <remote_dir>/rfsoc_lib/...                       (RfdcTask, clocks, gt_refclk, xrfclk/ZCU216)
#   <remote_dir>/rfsoc_lib/uhd/PROTOCOL.md
#   <remote_dir>/rfsoc_lib/uhd/server/*.py           (this directory)
#   <remote_dir>/rfsoc_lib/uhd/server/zcu216_v49_*ch_qsfp*.{bit,hwh}  (BIT_DIR=...)
#     one pair per build (PROTOCOL.md §8, §9; the 51 builds of
#     benchmark/oracle_builds.txt); the daemon's
#     default --bitstream-dir is that directory. Each .hwh is read for F, the
#     beat, TICK_STEP (tick rate) and the beamformers. Bitstreams and the
#     board's zcu216_uhd.conf already there are kept.
#   <remote_dir>/rfsoc_lib/uhd/benchmark/loopback_test.py   (board-only GT loopback)
#
# Env:
#   BIT_DIR=<dir>[:<dir>...]   also copy every zcu216_v49_*ch_qsfp*.bit and its
#                   .hwh from these dirs, e.g.
#                   BIT_DIR=hw_design/ZCU216/build/v49_qsfp/bitstreams
#   FORCE=1         with BIT_DIR: deploy exactly the builds of
#                   benchmark/oracle_builds.txt (every one must be in BIT_DIR,
#                   timing-clean), rewrite every file (rsync --ignore-times),
#                   delete every other zcu216_v49_* .bit/.hwh on the board, then
#                   compare the md5 of every copied file and check that the
#                   LMX2594_250.0_<fs>.0.txt each build's fs needs is there
#   BOARD=zcu208    deploy ZCU208 builds instead (zcu208_v49_*, the list
#                   benchmark/oracle_builds_zcu208.txt, xrfclk/ZCU208); pass
#                   the ZCU208's user@host. Default zcu216.
set -euo pipefail

TARGET=${1:-xilinx@zcu216-0}
RDIR=${2:-/home/xilinx/jupyter_notebooks/SPEAR-qsfpv}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

REPO=$(cd "$HERE/../../.." && pwd)
SRV=$RDIR/rfsoc_lib/uhd/server
P=$(echo "${BOARD:-zcu216}" | tr 'A-Z' 'a-z')            # bitstream prefix
case $P in
    zcu216) LIST=oracle_builds.txt ;;
    zcu208) LIST=oracle_builds_zcu208.txt ;;
    *) echo "BOARD=$P: zcu216 or zcu208" >&2; exit 2 ;;
esac
CLKDIR=$(echo "$P" | tr 'a-z' 'A-Z')                        # rfsoc_lib/xrfclk/<CLKDIR>
$SSH "$TARGET" "mkdir -p '$SRV'"
# zcu216_uhd.conf is the board's own settings (FPGA data IP/MAC) and the
# bitstreams are deployed separately: excluded, so --delete keeps them
rsync -a --delete -e "$SSH" \
    --exclude '__pycache__' --exclude '*.pyc' --exclude '*.bit' --exclude '*.hwh' \
    --exclude 'zcu216_uhd.conf' --exclude 'bitstream/' \
    --exclude '/uhd/host/' --exclude '/uhd/uhd/' \
    "$REPO/rfsoc_lib/" "$TARGET:$RDIR/rfsoc_lib/"

if [[ -n "${BIT_DIR:-}" && "${FORCE:-0}" = 1 ]]; then
    IFS=: read -r -a bit_dirs <<< "$BIT_DIR"
    want=()
    while read -r fam n rate bit rest; do
        [[ -z "$fam" || "$fam" == \#* ]] && continue
        want+=("$bit")
    done < "$REPO/rfsoc_lib/uhd/benchmark/$LIST"
    files=()
    for b in "${want[@]}"; do
        src=""
        for d in "${bit_dirs[@]}"; do [[ -f "$d/$b.bit" && -f "$d/$b.hwh" ]] && src=$d; done
        [[ -n "$src" ]] || { echo "FORCE: $b.bit/.hwh not in $BIT_DIR (not built, or not timing-clean)" >&2; exit 1; }
        files+=("$src/$b.bit" "$src/$b.hwh")
    done
    rsync -a --ignore-times -e "$SSH" "${files[@]}" "$TARGET:$SRV/"
    # anything else that looks like a build goes: only the listed set stays
    keep=$(printf '%s\n' "${want[@]}")
    gone=$($SSH "$TARGET" "cd '$SRV' && for f in ${P}_v49_*ch_qsfp*.bit ${P}_v49_*ch_qsfp*.hwh; do [ -e \"\$f\" ] || continue; b=\${f%.*}; echo '$keep' | grep -qx \"\$b\" || { rm -f \"\$f\"; echo \"\$f\"; }; done")
    [[ -n "$gone" ]] && echo "removed from the board: $(echo $gone)"
    # verify: md5 of every file, both sides
    local_md5=$(md5sum "${files[@]}" | awk '{n=split($2,a,"/"); print $1, a[n]}' | sort -k2)
    remote_md5=$($SSH "$TARGET" "cd '$SRV' && md5sum $(printf '%s ' "${want[@]/%/.bit}" "${want[@]/%/.hwh}")" | awk '{print $1, $2}' | sort -k2)
    if [[ "$local_md5" != "$remote_md5" ]]; then
        diff <(echo "$local_md5") <(echo "$remote_md5") >&2
        echo "FORCE: md5 mismatch after the copy" >&2; exit 1
    fi
    nb=$($SSH "$TARGET" "ls '$SRV'/${P}_v49_*ch_qsfp*.bit | wc -l")
    echo "FORCE: ${#want[@]} builds copied, md5 verified ($((${#want[@]} * 2)) files); the board has $nb bitstreams"
    for fs in $(printf '%s\n' "${want[@]}" | sed -nE 's/.*_fs([0-9]+)$/\1/p' | sort -u) $([ "$P" = zcu216 ] && echo 2400); do
        $SSH "$TARGET" "test -f '$RDIR/rfsoc_lib/xrfclk/$CLKDIR/LMX2594_250.0_$fs.0.txt'" ||
            { echo "FORCE: LMX2594_250.0_$fs.0.txt missing on the board" >&2; exit 1; }
    done
    echo "FORCE: LMX clock files present for every fs"
elif [[ -n "${BIT_DIR:-}" ]]; then
    n=0
    IFS=: read -r -a bit_dirs <<< "$BIT_DIR"
    for d in "${bit_dirs[@]}"; do
        for bit in "$d"/${P}_v49_*ch_qsfp*.bit; do
            [[ -f "$bit" ]] || continue
            hwh="${bit%.bit}.hwh"
            [[ -f "$hwh" ]] || { echo "missing $hwh (next to $bit)" >&2; exit 1; }
            rsync -a -e "$SSH" "$bit" "$hwh" "$TARGET:$SRV/"
            echo "copied $(basename "$bit") + .hwh"
            n=$((n + 1))
        done
    done
    [[ $n -gt 0 ]] || { echo "no ${P}_v49_*ch_qsfp*.bit in $BIT_DIR" >&2; exit 1; }
fi

echo "deployed to $TARGET:$SRV (not started)."
$SSH "$TARGET" "test -f '$SRV/zcu216_uhd.conf' || test -f /etc/zcu216_uhd.conf" ||
    echo "NOTE: no zcu216_uhd.conf on the board: copy zcu216_uhd.conf.example and set data_ip (hardware mode refuses to start without it)"
echo "service  : sudo cp $SRV/zcu216-uhd.service /etc/systemd/system/ && sudo systemctl daemon-reload"
