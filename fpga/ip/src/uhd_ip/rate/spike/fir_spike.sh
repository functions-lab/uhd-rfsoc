#!/bin/bash
# fir_spike.sh -- Gate 0: every stage configuration, one release at a time.
#   fir_spike.sh <release> <out_dir> [cfg ...]   cfg = dir:p:paths (default: the list below)
# One Vivado at a time (the machine's rule); prints the SPIKE_RESULT lines.
set -u
rel=$1; out=$2; shift 2
here=$(cd "$(dirname "$0")" && pwd)
source "$(bash "$here/../../../../../flow/versions.sh" settings "$rel")"
cfgs=("$@")
if [ ${#cfgs[@]} -eq 0 ]; then
  for d in rx tx; do for p in 8 4 2 1 0.5 0.25 0.125 0.0625 0.03125; do cfgs+=("$d:$p:2"); done; done
  for d in rx tx; do for p in 4 2 1; do cfgs+=("$d:$p:16"); done; done
fi
mkdir -p "$out"
for c in "${cfgs[@]}"; do
  IFS=: read -r d p n <<< "$c"
  vivado -mode batch -nojournal -nolog -source "$here/fir_spike.tcl" -tclargs "$d" "$p" "$n" "$out" \
    > "$out/${rel}_${d}_p${p}_n${n}.log" 2>&1
  grep -h "^SPIKE_RESULT" "$out/${rel}_${d}_p${p}_n${n}.log" || echo "SPIKE_FAIL rel=$rel cfg=$c (see $out/${rel}_${d}_p${p}_n${n}.log)"
done
