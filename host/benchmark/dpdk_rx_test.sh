#!/usr/bin/env bash
# dpdk_rx_test.sh -- the real-link test of the ZCU216 UHD module: stock UHD 4.6
# apps over the DPDK data plane at 1250 MS/s (1 channel, the max-rate build). Run on wei-duke-wsp5 once the
# board daemon is up and the 100G link is aligned. Uses sudo (asks once).
#
#   benchmark/dpdk_rx_test.sh
#   ZCU216_MODULE=$PWD/build/libuhd_zcu216.so benchmark/dpdk_rx_test.sh   # a build-tree copy
#
# Apps run through zcu216-uhd (root, UHD_MODULE_PATH, off the lcore CPUs): the
# installed one if it is on PATH, else tools/zcu216-uhd with ../build.
#
# Environment (no address is built in):
#   ADDR      board LAN address [discovery: `uhd_find_devices --args type=zcu216`
#             broadcast, which must find exactly one board]
#   DATA_IP   FPGA 100G data IP [the board's data_ip= from discovery]
#   IFACE     the PC's 100G netdev [the interface the kernel routes DATA_IP to]
#   NPORTS (4)  DUR (10 s)  NSAMPS (100000000)  OUT (/dev/shm/zcu216_dpdk_rx.dat)
#   FRAMES (32768: num_recv_frames per port for the capture, 4 x 32768 x 8 KB =
#          1 GB of ring = 210 ms at 1.25 GS/s, so the file writer's stalls are absorbed)
#   DEV_ARGS (extra device args, e.g. "dpdk_rx_cores=2-5,dpdk_rxd=8192")
#
# Steps (PASS/FAIL unless marked INFO):
#   1 uhd_usrp_probe: tree over DPDK, sensor cmac_aligned = true
#   2 benchmark_rate RX 1.25 GS/s sc16: 0 dropped, 0 overruns;  fc32: INFO
#   3 rx_samples_to_file pattern=1, NSAMPS at 1.25 GS/s: its dd disk pre-test forks
#     (this used to die with "Error: stod"), it must print "Done!", and
#     check_pattern_file.py must say BIT-EXACT
#   4 tx_timed_samples: burst ACK, no 'U';  benchmark_rate TX 1.25 GS/s sc16 with
#     ZCU216_TX_STATS=1: INFO (the gaps are printed)
#   5 the kernel side of the same port still resolves the FPGA by ARP (isolated mode)
#   NIC drop counters (rx_out_of_buffer = a DPDK queue was full) before/after.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
if command -v zcu216-uhd >/dev/null; then RUN=$(command -v zcu216-uhd); else RUN=$HERE/../tools/zcu216-uhd; fi
# the board: from discovery unless given (unicast to ADDR if set)
DISC=$(uhd_find_devices --args "type=zcu216${ADDR:+,addr=$ADDR}" 2>/dev/null)
NDEV=$(echo "$DISC" | grep -cE '^ +addr: ')
if [ "$NDEV" -ne 1 ]; then
    echo "discovery found $NDEV ZCU216 board(s)${ADDR:+ at $ADDR}; set ADDR=<board-ip>" >&2
    exit 1
fi
ADDR=${ADDR:-$(echo "$DISC" | awk '/^ +addr: /{print $2; exit}')}
DATA_IP=${DATA_IP:-$(echo "$DISC" | awk '/^ +data_ip: /{print $2; exit}')}
[ -n "$DATA_IP" ] || { echo "the daemon reports no data_ip; set DATA_IP=<fpga-data-ip>" >&2; exit 1; }
IFACE=${IFACE:-$(ip -o route get "$DATA_IP" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')}
[ -n "$IFACE" ] || { echo "no route to $DATA_IP; set IFACE=<100G netdev>" >&2; exit 1; }
NPORTS=${NPORTS:-4}
DUR=${DUR:-10}
NSAMPS=${NSAMPS:-100000000}
OUT=${OUT:-/dev/shm/zcu216_dpdk_rx.dat}
DIP=$DATA_IP
FRAMES=${FRAMES:-32768}
A="type=zcu216,addr=$ADDR,nports=$NPORTS${DEV_ARGS:+,$DEV_ARGS}"
L=${LOGDIR:-/tmp/zcu216_dpdk_test}
FAILS=0
res() { if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
nic() { ethtool -S "$IFACE" 2>/dev/null | grep -E " (rx_out_of_buffer|rx_discards_phy|rx_packets_phy|rx_crc_errors_phy):" | tr -s ' ' | tr '\n' ' '; echo; }
num() { grep -E "$1" "$2" | grep -oE '[0-9]+$' | tail -1; }

sudo -v || exit 1
mkdir -p "$L"
echo "wrapper $RUN (module: ${ZCU216_MODULE:-installed/default})"
echo "board   $ADDR, FPGA data $DIP via $IFACE"
echo "args    $A"
echo "logs    $L"
echo "NIC before: $(nic)"

# 1. probe
"$RUN" uhd_usrp_probe --args "$A" >"$L/probe.log" 2>&1 &&
    "$RUN" uhd_usrp_probe --args "$A" --sensor /mboards/0/sensors/cmac_aligned >"$L/cmac.log" 2>&1 &&
    grep -qi "true" "$L/cmac.log"
S=$?
grep -E "DPDK: port|rte_eal_init|Error" "$L/probe.log" | head -4
res "uhd_usrp_probe over DPDK, cmac_aligned true" $S

# 2. RX throughput
for cpu in sc16 fc32; do
    F=$L/bench_rx_$cpu.log
    "$RUN" benchmark_rate --args "$A" --rx_rate 1.25e9 --duration "$DUR" --rx_cpu "$cpu" >"$F" 2>&1
    grep -E "DPDK RX closed|Num received|Num dropped|Num overruns|Error" "$F"
    rcv=$(num "Num received samples:" "$F"); drp=$(num "Num dropped samples:" "$F")
    if [ "$cpu" = sc16 ]; then
        [ -n "$rcv" ] && [ "$drp" = 0 ] && grep -Eq "Num overruns detected: +0$" "$F"
        res "benchmark_rate RX 1.25 GS/s sc16, nports=$NPORTS: 0 dropped, 0 overruns" $?
    else
        echo "INFO  benchmark_rate RX 1.25 GS/s fc32: received ${rcv:-?}, dropped ${drp:-?}"
    fi
done

# 3. rx_samples_to_file, bit-exact
F=$L/rx_pattern.log
sudo rm -f "$OUT"
"$RUN" rx_samples_to_file --args "$A,pattern=1,num_recv_frames=$FRAMES" --rate 1.25e9 --freq 1e9 \
    --nsamps "$NSAMPS" --file "$OUT" >"$F" 2>&1
S=$?
grep -E "DPDK RX|Disk|stod|Error|Done" "$F" | head -12
[ $S -eq 0 ] && grep -q "Done!" "$F" && ! grep -q "stod" "$F" &&
    python3 "$HERE/../tools/check_pattern_file.py" "$OUT" --nsamps "$NSAMPS" | tee -a "$F" | tail -3 &&
    grep -q "BIT-EXACT" "$F"
res "rx_samples_to_file pattern=1, $NSAMPS samples at 1.25 GS/s: Done!, bit-exact (log $F)" $?
sudo rm -f "$OUT"

# 4. TX
F=$L/tx_timed.log
# 400000 samples (1.6 MB) fit the 2 MiB FPGA buffer, so the burst is fully
# queued before its start time; a larger one also tests how fast the app
# refills it, and tx_timed_samples prints a line per 1.7 us packet. UHD's
# async 'U' characters land mid-line, so strip them before matching.
timeout 60 "$RUN" tx_timed_samples --args "$A" --rate 1.25e9 --nsamps 400000 --secs 1.5 >"$F" 2>&1
tr -d U <"$F" | grep -E "DPDK TX|ACK|Error" | head -4
# a 'U' run not inside an upper-case word (UHD, CPU, NUMA, ZCU216) or "Using"
NU=$(python3 -c 'import re,sys; t=re.sub(r"\bUsing\b", "", open(sys.argv[1]).read()); print(sum(map(len, re.findall(r"(?<![A-Za-z])U+(?![A-Z])", t))))' "$F")
echo "  underflow 'U' printed: $NU"
tr -d U <"$F" | grep -q "ACK... success" && [ "$NU" -eq 0 ]
res "tx_timed_samples 400000 samples at 1.25 GS/s: burst ACK, no underflow" $?
F=$L/bench_tx.log
ZCU216_TX_STATS=1 "$RUN" benchmark_rate --args "$A" --tx_rate 1.25e9 --duration 5 --tx_cpu sc16 >"$F" 2>&1
grep -E "TX stats|DPDK TX closed" "$F"
echo "INFO  benchmark_rate TX 1.25 GS/s sc16: transmitted $(num 'Num transmitted samples:' "$F"), underruns $(num 'Num underruns detected:' "$F")"

echo "NIC after:  $(nic)"
# 5. The kernel keeps ARP/async (isolated mode): forget the FPGA, poke UDP 9 as
# the TX ARP probe does, and it must resolve again. (The FPGA answers ARP, not ping.)
sudo ip neigh del "$DIP" dev "$IFACE" 2>/dev/null
python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'x', ('$DIP', 9))"
sleep 0.3
ip neigh show "$DIP" dev "$IFACE" | tee /dev/stderr | grep -q lladdr
res "kernel netdev still resolves $DIP (ARP)" $?
echo "$FAILS failure(s); logs in $L"
exit $FAILS
