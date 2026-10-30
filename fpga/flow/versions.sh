#!/usr/bin/env bash
# versions.sh -- query flow/versions.txt (the PYNQ -> Vivado mapping of the
# bitstream builds) for the Makefile.
#
#   versions.sh default                 the default PYNQ version
#   versions.sh pynqs                   every PYNQ version, space-separated
#   versions.sh vivado <pynq>           the Vivado release that builds for <pynq>
#   versions.sh builddir <pynq> <board> the build directory, relative to fpga/:
#                                       build/<board> (default PYNQ) or
#                                       build/pynq<pynq>/<board>
#   versions.sh settings <vivado> [root ...]
#                                       the settings64.sh of that Vivado release
#                                       under the first install root that has it
#                                       (<root>/<v>, <root>/Vivado/<v> or
#                                       <root>/<v>/Vivado); default roots
#                                       /tools/Xilinx /opt/Xilinx
#   versions.sh check                   validate versions.txt and the boards
set -euo pipefail
FLOW=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILE=${V49_VERSIONS_FILE:-$FLOW/versions.txt}
BOARDS_DIR=$FLOW/../boards
die() { echo "versions.sh: $*" >&2; exit 2; }
[ -f "$FILE" ] || die "no $FILE"

# records of one kind, comments and blank lines dropped
records() { sed -e 's/#.*//' "$FILE" | awk -v k="$1" '$1 == k'; }
pynqs() { records pynq | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $2 } END { print "" }'; }
default_pynq() { records pynq | awk '$4 == "default" { print $2 }'; }
vivado_of() {
    local v; v=$(records pynq | awk -v p="$1" '$2 == p { print $3 }')
    [ -n "$v" ] || die "unknown PYNQ version '$1' (one of: $(pynqs))"
    echo "$v"
}
all_boards() {
    local d out=()
    for d in "$BOARDS_DIR"/*/board.tcl; do out+=("$(basename "$(dirname "$d")")"); done
    echo "${out[*]}"
}

cmd=${1:-}; shift || true
case $cmd in
default) default_pynq ;;
pynqs) pynqs ;;
vivado) [ $# -eq 1 ] || die "usage: vivado <pynq>"; vivado_of "$1" ;;
builddir)
    [ $# -eq 2 ] || die "usage: builddir <pynq> <board>"
    vivado_of "$1" > /dev/null
    if [ "$1" = "$(default_pynq)" ]; then echo "build/$2"; else echo "build/pynq$1/$2"; fi ;;
settings)
    [ $# -ge 1 ] || die "usage: settings <vivado> [root ...]"
    v=$1; shift
    roots=("$@"); [ ${#roots[@]} -gt 0 ] || roots=(/tools/Xilinx /opt/Xilinx)
    for r in "${roots[@]}"; do
        [ -n "$r" ] || continue
        for s in "$r/$v/settings64.sh" "$r/Vivado/$v/settings64.sh" "$r/$v/Vivado/settings64.sh"; do
            [ -f "$s" ] && { echo "$s"; exit 0; }
        done
    done
    die "no Vivado $v under ${roots[*]} (looked for <root>/$v/settings64.sh, <root>/Vivado/$v/settings64.sh, <root>/$v/Vivado/settings64.sh)" ;;
check)
    rc=0
    bad=$(sed -e 's/#.*//' "$FILE" | awk 'NF && !(($1 == "pynq" && (NF == 3 || (NF == 4 && $4 == "default"))) || ($1 == "ip" && NF == 4)) { print NR": "$0 }')
    [ -z "$bad" ] || { echo "malformed lines in $FILE:"; echo "$bad"; rc=1; }
    vre='^[0-9]{4}\.[0-9]+$'
    while read -r _ pq viv _; do
        [[ $pq =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "pynq $pq: not a version"; rc=1; }
        [[ $viv =~ $vre ]] || { echo "pynq $pq: Vivado '$viv' is not a release (YYYY.N)"; rc=1; }
    done < <(records pynq)
    while read -r _ viv ip ver; do
        [[ $viv =~ $vre ]] || { echo "ip $ip: Vivado '$viv' is not a release (YYYY.N)"; rc=1; }
        [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] || { echo "ip $ip: '$ver' is not an IP version"; rc=1; }
        records pynq | awk -v v="$viv" '$3 == v { f = 1 } END { exit !f }' \
            || { echo "ip $viv $ip: no pynq line builds with Vivado $viv"; rc=1; }
    done < <(records ip)
    dup=$(records pynq | awk '{ print $2 }' | sort | uniq -d)
    [ -z "$dup" ] || { echo "PYNQ versions listed twice: $dup"; rc=1; }
    dup=$(records ip | awk '{ print $2, $3 }' | sort | uniq -d)
    [ -z "$dup" ] || { echo "ip lines listed twice: $dup"; rc=1; }
    nd=$(records pynq | awk '$4 == "default"' | wc -l)
    [ "$nd" -eq 1 ] || { echo "$nd default pynq lines (want exactly one)"; rc=1; }
    [ -n "$(all_boards)" ] || { echo "no boards in $BOARDS_DIR"; rc=1; }
    [ $rc -eq 0 ] && echo "versions.txt: PYNQ $(pynqs) (default $(default_pynq)); boards $(all_boards)"
    exit $rc ;;
*) sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; [ -z "$cmd" ] || exit 2 ;;
esac
