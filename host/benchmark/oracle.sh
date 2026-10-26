#!/usr/bin/env bash
# oracle.sh -- the project's test oracle: measurements on the REAL board, the
# results printed as measured. Three suites:
#
#   robustness   per build and per wire format the build carries: RUNS strict
#                full-rate simultaneous TX+RX runs (benchmark_rate rxtx, every
#                error threshold 0, DUR s, through the DACs and ADCs), counted
#                as runs with TX underruns / with RX loss; then the over-the-air
#                TX format check (otw_tx_ota.py: every TX wire format against
#                sc16 through the RF link, tone amplitude and phase)
#   compliance   every applicable stock UHD example (uhd_examples_hw.sh)
#   beamforming  4T4R over the air (channels 0-3): phase calibration
#                (phase_cal.py calibrate, null search) and its verification
#                (residual offsets, coherent gain), the TX beamformer
#                (bf_air_test.py) and the RX beamformer (rx_bf_air_test.py)
#
#   sudo -E env PATH=$PATH BOARD=xilinx@<board> ADDR=<board-ip> benchmark/oracle.sh <suite|all> [filter]
#     filter: a substring of "<family> <N>ch <bitstream>" (e.g. 245m76, " 4ch ", _f3_)
#
# Builds: oracle_builds.txt (their bitstreams copied into the board's checkout
# with rfsoc/push_bitstreams.sh); BUILDS=<file> takes another list (an RFSoC
# 4x2: BUILDS=oracle_builds_rfsoc4x2.txt). Run as root on the PC (UHD over
# DPDK); the board is driven over ssh as the invoking user ($SUDO_USER),
# passwordless (BatchMode), through the board's run_daemon.sh (which needs
# passwordless sudo there). The run restarts the board's daemon for every
# build: nothing else may use the board meanwhile.
# Environment (no address or host name is built in):
#   BOARD      ssh target of the board, e.g. xilinx@<board> (required)
#   ADDR       board LAN address [discovery: exactly one board]
#   BOARD_DIR  the board's git checkout of this repository
#              [/home/xilinx/jupyter_notebooks/uhd-rfsoc]
#   RUNS (10)  DUR (30)  FREQ (950e6: RF centre of the over-the-air tests)
#   LAYOUT     device args of the full-rate runs; APP_CPUS (UHD_RFSOC_APP_CPUS);
#              HK_CPUS (the CPUs left to the rest of the system). The defaults
#              are the full-rate duplex layout of host/AGENTS.md for a 6-core /
#              12-thread host (APP_CPUS 0,1,6,7, HK_CPUS 9): adapt all three.
#   ISOLATE (1) tools/isolate_cpus.sh apply HK_CPUS for the run, restore after
#   OUT        [/tmp/uhd_rfsoc_oracle/<date-time>]
# Exit code: the number of failed items (a run, a check, a test).
set -u
[ "$(id -u)" = 0 ] || { echo "run as root (sudo -E ...): UHD over DPDK" >&2; exit 2; }
SUITE=${1:-}
FILTER=${2:-}
case $SUITE in robustness|compliance|beamforming|all) ;; *)
    echo "usage: $0 robustness|compliance|beamforming|all [filter]" >&2; exit 2 ;; esac
HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS=$HERE/../tools
if command -v uhd-rfsoc >/dev/null; then RUN=$(command -v uhd-rfsoc); else RUN=$TOOLS/uhd-rfsoc; fi
[ -n "${BOARD:-}" ] || { echo "set BOARD=<user>@<board>: the ssh target of the board (e.g. xilinx@<board-ip>)" >&2; exit 2; }
BUILDS=${BUILDS:-$HERE/oracle_builds.txt}
case $BUILDS in /*) ;; *) [ -f "$BUILDS" ] || BUILDS=$HERE/$BUILDS ;; esac
BOARD_DIR=${BOARD_DIR:-/home/xilinx/jupyter_notebooks/uhd-rfsoc}
RUNS=${RUNS:-10}
DUR=${DUR:-30}
FREQ=${FREQ:-950e6}
LAYOUT=${LAYOUT:-rx_workers=2,worker_cpus=2:3,tx_workers=3,tx_worker_cpus=4:5:11,dpdk_rx_cores=8,dpdk_tx_core=10,dpdk_rxd=128,tx_max_pkts=256,num_recv_frames=1024}
export UHD_RFSOC_APP_CPUS=${APP_CPUS:-0,1,6,7}
HK_CPUS=${HK_CPUS:-9}
OUT=${OUT:-/tmp/uhd_rfsoc_oracle/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
if [ -z "${ADDR:-}" ]; then
    ADDR=$(uhd_find_devices --args type=rfsoc 2>/dev/null | awk '/^ +addr: /{print $2}')
    [ "$(echo "$ADDR" | wc -w)" = 1 ] || { echo "discovery found '$ADDR'; set ADDR=<board-ip>" >&2; exit 2; }
fi
bssh() { # -n: never read stdin (the build list's while-read loop reads it)
    if [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" ssh -n -o BatchMode=yes "$BOARD" "$@"
    else ssh -n -o BatchMode=yes "$BOARD" "$@"; fi
}
log() { echo "$*" | tee -a "$OUT/oracle.log"; }
FAILS=0

load_build() { # <bitstream basename>: the daemon serving that build (run_daemon.sh
    # stops the running daemon, starts the new one and returns once it serves;
    # its log is /tmp/uhd_daemon.log on the board)
    bssh "cd $BOARD_DIR && ./run_daemon.sh restart --bitstream $BOARD_DIR/rfsoc/server/$1.bit"
}

if [ "${ISOLATE:-1}" = 1 ]; then
    "$TOOLS/isolate_cpus.sh" apply "$HK_CPUS" >/dev/null && trap '"$TOOLS/isolate_cpus.sh" restore >/dev/null' EXIT
fi
log "oracle $SUITE${FILTER:+ ($FILTER)}: board $ADDR via $BOARD, $RUNS x ${DUR}s runs, RF $FREQ, isolation ${ISOLATE:-1}; logs in $OUT"
log "source $(git -C "$HERE" log -1 --format='%h %s' 2>/dev/null || echo 'not a git checkout')"

cpu_of() { case $1 in sc8) echo sc8 ;; fc32) echo fc32 ;; *) echo sc16 ;; esac; }

# the build list on fd 3: nothing in the loop (ssh, the UHD examples, the
# Python tools) can read it away from stdin
while read -r FAM N RATE BIT FMTS BF <&3; do
    case $FAM in ''|\#*) continue ;; esac
    case "$FAM ${N}ch $BIT" in *"$FILTER"*) ;; *) continue ;; esac
    # beamforming alone has nothing to do on a build without the 4T4R flag
    [ "$SUITE" = beamforming ] && [ "$BF" != yes ] && continue
    # the Python tools get the same layout as the full-rate runs: UHD_RFSOC_APP_CPUS
    # (exported above) assumes the DPDK lcores sit on LAYOUT's cores. With the
    # module's default layout instead, an lcore shares a core with the
    # application and over-the-air captures near the link rate lose packets.
    BL=$LAYOUT
    A="type=rfsoc,addr=$ADDR,channels=$N,$BL"
    # the over-the-air check's wire format: sc16 where the build carries it,
    # else sc8 (a template's sc8 / sc12 top rates)
    case ",$FMTS," in *,sc16,*) WIRE=sc16 ;; *) WIRE=sc8 ;; esac
    log ""
    log "######## $FAM ${N}ch $BIT ($N x $RATE, wire $FMTS)"
    if ! load_build "$BIT"; then
        log "LOAD FAILED: the daemon did not serve $BIT"; FAILS=$((FAILS + 1)); continue
    fi
    if [ "$SUITE" = robustness ] || [ "$SUITE" = all ]; then
        for F in ${FMTS//,/ }; do
            for r in $(seq "$RUNS"); do
                line=$(ADDR=$ADDR DUR=$DUR DEV_ARGS="channels=$N,$BL,otw=$F" LOG=$OUT/bench/${BIT}_r$r \
                    "$HERE/bench_strict.sh" rxtx "$RATE" "$N" "$(cpu_of "$F")" "$F" 2>&1 | tail -1)
                line=$(echo "$line" | sed -E 's/ \[[^]]*\]//')
                log "ROBUST $FAM ${N}ch $F run $r: $line"
                case $line in PASS*) ;; *) FAILS=$((FAILS + 1)) ;; esac
            done
        done
        if [ "$WIRE" = sc16 ]; then
            "$RUN" python3 "$HERE/otw_tx_ota.py" --args "$A" --rate "$RATE" --freq "$FREQ" \
                >"$OUT/ota_$BIT.log" 2>&1
            rc=$?
            log "OTA $FAM ${N}ch: $(grep -E '^RESULT' "$OUT/ota_$BIT.log" | tail -1) (rc $rc; $OUT/ota_$BIT.log)"
            [ $rc -eq 0 ] || FAILS=$((FAILS + 1))
            grep -E "^  FAIL" "$OUT/ota_$BIT.log" | sed "s/^/OTA $FAM ${N}ch /" | tee -a "$OUT/oracle.log"
        else
            # sc8-only build: TX sc8 (cpu fc32 and sc16) against itself, captured in sc8
            "$RUN" python3 "$HERE/otw_tx_ota.py" --args "$A,otw=sc8" --rate "$RATE" --freq "$FREQ" \
                --formats sc8 --rx-otw sc8 >"$OUT/ota_$BIT.log" 2>&1
            rc=$?
            log "OTA $FAM ${N}ch (sc8 both ways): $(grep -E '^RESULT' "$OUT/ota_$BIT.log" | tail -1) (rc $rc; $OUT/ota_$BIT.log)"
            [ $rc -eq 0 ] || FAILS=$((FAILS + 1))
            grep -E "^  FAIL" "$OUT/ota_$BIT.log" | sed "s/^/OTA $FAM ${N}ch /" | tee -a "$OUT/oracle.log"
        fi
    fi
    if [ "$SUITE" = compliance ] || [ "$SUITE" = all ]; then
        ADDR=$ADDR N=$N RATE=$RATE WIRE=$WIRE BENCH_ARGS=$BL LOGDIR=$OUT/compliance_$BIT \
            "$HERE/uhd_examples_hw.sh" >"$OUT/compliance_$BIT.log" 2>&1
        rc=$?
        log "COMPLIANCE $FAM ${N}ch: $(tail -1 "$OUT/compliance_$BIT.log")"
        grep -E "^(FAIL|N/A) " "$OUT/compliance_$BIT.log" | sed "s/^/COMPLIANCE $FAM ${N}ch   /" | tee -a "$OUT/oracle.log"
        FAILS=$((FAILS + rc))
    fi
    if { [ "$SUITE" = beamforming ] || [ "$SUITE" = all ]; } && [ "$BF" = yes ]; then
        CAL=$OUT/phase_cal_$BIT.json
        for step in calibrate verify txbf rxbf; do
            case $step in
                calibrate) cmd=("$HERE/phase_cal.py" calibrate --args "$A" --freq "$FREQ" --out "$CAL") ;;
                verify)    cmd=("$HERE/phase_cal.py" verify --args "$A" --freq "$FREQ" --cal "$CAL") ;;
                txbf)      cmd=("$HERE/bf_air_test.py" --args "$A" --freq "$FREQ") ;;
                rxbf)      cmd=("$HERE/rx_bf_air_test.py" --args "$A" --freq "$FREQ") ;;
            esac
            "$RUN" python3 "${cmd[@]}" >"$OUT/bf_${step}_$BIT.log" 2>&1
            rc=$?
            res=$(grep -E '^RESULT|^  saved|^  (TX|RX) offsets' "$OUT/bf_${step}_$BIT.log" | tr '\n' ' ')
            log "BEAMFORMING $FAM ${N}ch $step: rc $rc ${res:-$(tail -1 "$OUT/bf_${step}_$BIT.log")}"
            [ $rc -eq 0 ] || FAILS=$((FAILS + 1))
            [ "$step" = calibrate ] && [ $rc -ne 0 ] && break
        done
    fi
done 3< "$BUILDS"

bssh "cd $BOARD_DIR && ./run_daemon.sh stop" || true
# per (build, format): runs, clean, runs with TX underruns, runs with RX loss
python3 - "$OUT/oracle.log" <<'EOF' | tee -a "$OUT/oracle.log"
import re, sys, collections
c = collections.OrderedDict()
for l in open(sys.argv[1]):
    m = re.match(r"ROBUST (\S+) (\d+ch) (\S+) run \d+: (.*)", l)
    if not m:
        continue
    k = m.group(1, 2, 3); s = c.setdefault(k, dict(runs=0, clean=0, undr=0, loss=0, nores=0))
    t = m.group(4); s["runs"] += 1
    if "no result" in t:
        s["nores"] += 1; continue
    g = lambda f: int((re.search(f + r"=(\d+)", t) or [0, 0])[1])
    s["clean"] += t.startswith("PASS"); s["undr"] += g("undr") > 0
    s["loss"] += g("drop") > 0 or g("ovr") > 0
if c:
    print("\nrobustness: full-rate simultaneous TX+RX runs per (build, wire format)")
    print("%-9s %-5s %-5s %5s %6s %16s %16s %10s" % ("family", "N", "otw", "runs", "clean", "TX underruns", "RX loss", "no result"))
    for (f, n, o), s in c.items():
        print("%-9s %-5s %-5s %5d %6d %11d / %-3d %11d / %-3d %10d" % (f, n, o, s["runs"], s["clean"],
              s["undr"], s["runs"], s["loss"], s["runs"], s["nores"]))
EOF
log "oracle $SUITE: $FAILS failed item(s); logs in $OUT"
exit $FAILS
