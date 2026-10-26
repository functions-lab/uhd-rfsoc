#!/usr/bin/env bash
# uhd_examples_hw.sh -- every stock UHD example that applies to the boards, run
# unmodified against the real board, one PASS / FAIL / N/A line each.
#
#   sudo env PATH=$PATH ADDR=<board-ip> benchmark/uhd_examples_hw.sh
#   sudo env PATH=$PATH ADDR=<board-ip> N=4 RATE=625e6 benchmark/uhd_examples_hw.sh
#
# The examples run on the hardware, at the build's own rate. RX captures of the
# section-5 pattern (device arg pattern=1) are checked bit-exactly by
# check_pattern_file.py; TX cannot be read back digitally (no TX -> RX loopback
# in the FPGA), so TX examples must finish with no underflow / with their burst
# ACKs (benchmark/otw_tx_ota.py compares the TX formats through the RF link).
#
# Run as root (DPDK) with the board's daemon up and the 100G link aligned.
# Environment (no address is built in):
#   ADDR      board LAN address [discovery, which must find exactly one board]
#   N (1)     channels of the loaded build;  RATE (1.25e9) per-channel rate
#   TPS       ticks per sample [1 at N = 1, else N: section 9]
#   WIRE      the build's wire format for every example (sc16; sc8 on the
#             sc8-only builds 4ch F=2 / 8ch F=4 / 16ch F=8: adds otw=sc8)
#   OTWS      extra RX wire formats to check bit-exactly
#             [WIRE sc16: N = 1 "sc12 sc8 fc32", else "sc12 sc8"; else ""]
#   DUR (10)  benchmark_rate seconds;  DEV_ARGS extra device args
#   BENCH_ARGS extra device args for the full-rate benchmark_rate(.py) runs only
#             (e.g. host/AGENTS.md's duplex layout)
#   LOGDIR (/tmp/uhd_rfsoc_uhd_hw), DATA (/dev/shm/uhd_rfsoc_uhd_hw)
#   UHD_EXAMPLES [/usr/libexec/uhd/examples]
#
# Not run, and why (printed at the end too):
#   rfnoc_* (5), network_relay  the boards are not RFNoC devices
#   twinrx_freq_hopping, test_dboard_coercion, spi, sync_to_gps
#                               Ettus daughterboard / SPI / GPSDO hardware
#   test_clock_synch            needs an OctoClock (--clock-args)
#   rx_ascii_art_dft, python curses_fft / usrp_power_meter / remote_rx /
#   replay_capture / x440_L_band_capture
#                               interactive (curses), or another device's feature
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS=$HERE/../tools
if command -v uhd-rfsoc >/dev/null; then RUN=$(command -v uhd-rfsoc); else RUN=$TOOLS/uhd-rfsoc; fi
E=${UHD_EXAMPLES:-/usr/libexec/uhd/examples}
PYE=$E/python

DISC=$(uhd_find_devices --args "type=rfsoc${ADDR:+,addr=$ADDR}" 2>/dev/null)
NDEV=$(echo "$DISC" | grep -cE '^ +addr: ')
if [ "$NDEV" -ne 1 ]; then
    echo "discovery found $NDEV board(s)${ADDR:+ at $ADDR}; set ADDR=<board-ip>" >&2
    exit 1
fi
ADDR=${ADDR:-$(echo "$DISC" | awk '/^ +addr: /{print $2; exit}')}
N=${N:-1}
RATE=${RATE:-1.25e9}
WIRE=${WIRE:-sc16}
if [ "$WIRE" != sc16 ]; then OTWS=${OTWS-}; fi
if [ "$N" = 1 ]; then TPS=${TPS:-1}; OTWS=${OTWS-sc12 sc8 fc32}; else TPS=${TPS:-$N}; OTWS=${OTWS-sc12 sc8}; fi
DUR=${DUR:-10}
A="type=rfsoc,addr=$ADDR,channels=$N${DEV_ARGS:+,$DEV_ARGS}"
[ "$WIRE" != sc16 ] && A="$A,otw=$WIRE"
# the pattern as the wire format rounds it
POTW=(); [ "$WIRE" != sc16 ] && POTW=(--otw "$WIRE")
# captures: a 32768-frame ring per port (as dpdk_rx_test.sh), so the file
# writer's stalls are absorbed instead of overflowing at 1.25 GS/s
AC="$A,pattern=1,num_recv_frames=32768"
ALL=$(seq -s, 0 $((N - 1)))
L=${LOGDIR:-/tmp/uhd_rfsoc_uhd_hw}
D=${DATA:-/dev/shm/uhd_rfsoc_uhd_hw}
rm -rf "$D"; mkdir -p "$L" "$D"
FAILS=0
NRUN=0
NNA=0
result() { # name, exit status
    NRUN=$((NRUN + 1))
    if [ "$2" -eq 0 ]; then echo "PASS  $1"; else echo "FAIL  $1  (logs in $L)"; FAILS=$((FAILS + 1)); fi
}
na() { # name, reason: an example that cannot run on this build, neither PASS nor FAIL
    NNA=$((NNA + 1)); echo "N/A   $1 -- $2"
}
# no error words; the module's own [INFO] lines (DPDK counters) do not count
clean_log() { ! grep -v '^\[INFO\]' "$1" | grep -qiE "timeout|error|unexpected"; }
# UHD's async underflow marks: a 'U' that is not part of a word
underflows() { grep -v '^\[' "$1" | grep -oE '(^|[^A-Za-z])U([^A-Za-z]|$)' | wc -l; }
# rx_samples_to_file / rx_multi: one channel writes <file>, several ch<c>_<file>
capfiles() { # <channel list> <file>
    if [ "$(echo "$1" | tr ',' '\n' | wc -l)" = 1 ]; then echo "$D/$2"; return; fi
    local c; for c in ${1//,/ }; do printf '%s ' "$D/ch${c}_$2"; done
}
pattern() { # <channel list> <file> <nsamps> [check_pattern_file args]
    local ch=$1 f=$2 ns=$3; shift 3
    if [ "$(echo "$ch" | tr ',' '\n' | wc -l)" = 1 ]; then
        python3 "$TOOLS/check_pattern_file.py" $(capfiles "$ch" "$f") --tps "$TPS" --nsamps "$ns" "$@"
    else
        python3 "$TOOLS/check_pattern_file.py" $(capfiles "$ch" "$f") --tps "$TPS" --chans "$ch" --nsamps "$ns" "$@"
    fi
}

echo "wrapper  $RUN"
echo "examples $E"
echo "board    $ADDR: N=$N at $RATE per channel (TPS $TPS), wire $WIRE${OTWS:+, also RX $OTWS}"
echo "logs     $L"

# --- discovery and the property tree
uhd_find_devices --args "type=rfsoc,addr=$ADDR" >"$L/find.log" 2>&1 && grep -q "type: rfsoc" "$L/find.log"
result "uhd_find_devices" $?
timeout 60 "$RUN" uhd_usrp_probe --args "$A" >"$L/probe.log" 2>&1 &&
    grep -q "RX Frontend: $((N - 1))" "$L/probe.log" && grep -q "TX Frontend: $((N - 1))" "$L/probe.log"
result "uhd_usrp_probe: $N RX / $N TX frontends" $?
timeout 60 "$RUN" "$E/usrp_list_sensors" --args "$A" >"$L/sensors.log" 2>&1 &&
    [ "$(grep -c 'LO: locked' "$L/sensors.log")" -ge "$N" ] && ! grep -q "LO: unlocked" "$L/sensors.log"
result "usrp_list_sensors: every channel's lo_locked reads locked" $?

# --- RX: captures of the section-5 pattern, bit-exact
NS=$((10000000 / N + 3))
(cd "$D" && timeout 120 "$RUN" "$E/rx_samples_to_file" --args "$AC" --wirefmt "$WIRE" --channels "$ALL" --rate "$RATE" \
    --freq 1e9 --nsamps $NS --file rx16.dat) >"$L/rx16.log" 2>&1 &&
    grep -q "Done!" "$L/rx16.log" && ! grep -q "stod" "$L/rx16.log" && pattern "$ALL" rx16.dat $NS "${POTW[@]}" >>"$L/rx16.log"
result "rx_samples_to_file wire $WIRE -> cpu sc16, $NS samples x $N ch: bit-exact, aligned, dd pre-test ran" $?
(cd "$D" && timeout 120 "$RUN" "$E/rx_samples_to_file" --args "$AC" --wirefmt "$WIRE" --channels "$ALL" --rate "$RATE" \
    --nsamps $NS --type float --file rxf.dat) >"$L/rxf.log" 2>&1 &&
    pattern "$ALL" rxf.dat $NS --type float "${POTW[@]}" >>"$L/rxf.log"
result "rx_samples_to_file cpu fc32, odd count: bit-exact" $?
for W in $OTWS; do
    (cd "$D" && timeout 120 "$RUN" "$E/rx_samples_to_file" --args "$AC" --wirefmt "$W" --channels "$ALL" \
        --rate "$RATE" --nsamps $NS --type float --file rx_$W.dat) >"$L/rx_$W.log" 2>&1 &&
        pattern "$ALL" rx_$W.dat $NS --type float --otw "$W" >>"$L/rx_$W.log"
    result "rx_samples_to_file wire $W -> cpu fc32: bit-exact against the $W-rounded pattern" $?
    rm -f "$D"/*rx_$W.dat
done
rm -f "$D"/*.dat
if [ "$N" -gt 1 ]; then
    SUB=$((N - 1)),$((N > 2 ? 1 : 0))
    (cd "$D" && timeout 120 "$RUN" "$E/rx_samples_to_file" --args "$AC" --wirefmt "$WIRE" --channels "$SUB" --rate "$RATE" \
        --nsamps $NS --type float --file rxsub.dat) >"$L/rxsub.log" 2>&1 &&
        pattern "$SUB" rxsub.dat $NS --type float "${POTW[@]}" >>"$L/rxsub.log"
    result "rx_samples_to_file --channels $SUB (reverse order, others dropped): bit-exact" $?
    rm -f "$D"/*.dat
fi
# (a status is kept in S before result(): a $(...) in result's first
# argument would reset $? before its second argument reads it)
if [ "$WIRE" = sc16 ]; then
    timeout 60 "$RUN" "$E/rx_samples_c" -a "$A,pattern=1" -r "$RATE" -f 1e9 -n 1000000 -o "$D/rxc.dat" >"$L/rxc.log" 2>&1 &&
        { [ "$N" != 1 ] || python3 "$TOOLS/check_pattern_file.py" "$D/rxc.dat" --type float --tps "$TPS" >>"$L/rxc.log" 2>&1; }
    S=$?
    result "rx_samples_c (C API): exit 0$([ "$N" = 1 ] && echo ', fc32 capture bit-exact')" $S
else
    na "rx_samples_c (C API)" "the example hard-codes otw sc16; this build carries $WIRE only"
fi
rm -f "$D"/*.dat
timeout 60 "$RUN" "$E/rx_timed_samples" --args "$A" --rate "$RATE" --nsamps 10001 --secs 1.5 >"$L/rxt.log" 2>&1 &&
    clean_log "$L/rxt.log"
result "rx_timed_samples: timed num_done, 10001 samples" $?
timeout 60 "$RUN" "$E/rx_multi_samples" --args "$A" --channels "$ALL" --rate "$RATE" --nsamps 10001 --secs 1.0 \
    >"$L/rxm.log" 2>&1 && grep -q "Done!" "$L/rxm.log" && clean_log "$L/rxm.log"
result "rx_multi_samples --channels $ALL: timed num_done" $?
timeout 60 "$RUN" "$E/rx_multi_samples" --args "$A" --channels "$ALL" --rate "$RATE" --sync pps --secs 1.5 \
    --nsamps 20000 >"$L/rxm_pps.log" 2>&1 && grep -q "Done!" "$L/rxm_pps.log" && clean_log "$L/rxm_pps.log"
result "rx_multi_samples --sync pps (set_time_unknown_pps)" $?
python3 - "$D/udp.cnt" >"$L/udp_listen.log" 2>&1 <<'EOF' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 7124)); s.settimeout(20)
n = 0
try:
    while True:
        n += len(s.recv(65536)); s.settimeout(2)
except socket.timeout:
    pass
open(sys.argv[1], "w").write(str(n))
EOF
LP=$!
sleep 0.5
# it sends each get_max_num_samps() buffer as ONE datagram (<= 65507 bytes):
# spb_pkts sized to fit, against the default 32 that line-rate apps want
# (host/AGENTS.md, spb_pkts). A packet holds 8192 payload bytes, i.e.
# 8192 / (wire bytes per slot) slots (sc8: 4096, not sc16's 2048), each
# sample written as 8 bytes (fc32)
case $WIRE in sc8) WB=2 ;; sc12) WB=3 ;; fc32) WB=8 ;; *) WB=4 ;; esac
UPK=$((65000 / (8192 / WB / N * 8))); [ $UPK -gt 32 ] && UPK=32; [ $UPK -lt 1 ] && UPK=1
timeout 60 "$RUN" "$E/rx_samples_to_udp" --args "$A,spb_pkts=$UPK" --rate "$RATE" --nsamps 1000000 --addr 127.0.0.1 \
    --port 7124 >"$L/rxudp.log" 2>&1
S=$?
wait $LP
UB=$(cat "$D/udp.cnt" 2>/dev/null || echo 0)
[ $S -eq 0 ] && [ "$UB" -gt 0 ] && ! grep -q "^Error" "$L/rxudp.log"
result "rx_samples_to_udp (spb_pkts=$UPK): exit 0, $UB bytes reached the UDP listener" $?

# --- TX (no digital read-back on the hardware: no underflow / burst ACKs)
python3 - "$D/tone.dat" <<'EOF'
import sys, numpy as np                       # 4 M samples of a -20 dBFS tone
k = np.arange(4_000_000); z = 0.1 * 32767 * np.exp(2j * np.pi * k / 400)
a = np.empty(2 * k.size, '<i2'); a[0::2] = np.round(z.real); a[1::2] = np.round(z.imag); a.tofile(sys.argv[1])
EOF
timeout 60 "$RUN" "$E/tx_samples_from_file" --args "$A" --wirefmt "$WIRE" --rate "$RATE" --freq 1e9 --type short --file "$D/tone.dat" \
    >"$L/txf.log" 2>&1 && clean_log "$L/txf.log"
S=$?; U=$(underflows "$L/txf.log")
[ $S -eq 0 ] && [ "$U" = 0 ]
result "tx_samples_from_file 4M samples: exit 0, $U underflow(s)" $?
timeout 60 "$RUN" "$E/tx_waveforms" --args "$A" --otw "$WIRE" --channels "$ALL" --rate "$RATE" --freq 1e9 --ampl 0.1 \
    --wave-freq "$(python3 -c "print($RATE / 40)")" --nsamps "$(python3 -c "print(int(2 * $RATE))")" >"$L/txw.log" 2>&1
S=$?; U=$(underflows "$L/txw.log")
[ $S -eq 0 ] && [ "$U" = 0 ]
result "tx_waveforms --channels $ALL, 2 s: exit 0, $U underflow(s)" $?
if [ "$WIRE" = sc16 ]; then
    timeout 60 "$RUN" "$E/tx_samples_c" -a "$A" -r "$RATE" -f 1e9 -n 1000000 >"$L/txc.log" 2>&1
    result "tx_samples_c (C API): exit 0" $?
else
    na "tx_samples_c (C API)" "the example hard-codes otw sc16; this build carries $WIRE only"
fi
timeout 60 "$RUN" "$E/tx_timed_samples" --args "$A" --rate "$RATE" --nsamps 10001 --secs 1.5 >"$L/txt.log" 2>&1 &&
    grep -q "ACK... success" "$L/txt.log"
result "tx_timed_samples: burst ACK" $?
timeout 60 "$RUN" "$E/tx_bursts" --args "$A" --channels "$ALL" --rate "$RATE" --nsamps 20000 --secs 1.0 --repeat \
    --rep-delay 0.25 >"$L/txb.log" 2>&1 &
BP=$!
sleep 6; kill -INT $BP 2>/dev/null; wait $BP 2>/dev/null
NACK=$(grep -c 'ACK... success' "$L/txb.log")
[ "$NACK" -ge 3 ]
result "tx_bursts --repeat: $NACK burst ACKs" $?

# --- RX + TX together
for dir in rx tx rxtx; do
    case $dir in
        rx)   R="--rx_rate $RATE";;
        tx)   R="--tx_rate $RATE";;
        rxtx) R="--rx_rate $RATE --tx_rate $RATE";;
    esac
    timeout $((DUR + 60)) "$RUN" "$E/benchmark_rate" --args "$A${BENCH_ARGS:+,$BENCH_ARGS}" --channels "$ALL" $R \
        --rx_otw "$WIRE" --tx_otw "$WIRE" \
        --duration "$DUR" --overrun-threshold 0 --underrun-threshold 0 --drop-threshold 0 --seq-threshold 0 \
        >"$L/bench_$dir.log" 2>&1
    S=$?
    rcv=$(grep -E "Num received samples:" "$L/bench_$dir.log" | grep -oE '[0-9]+$')
    snt=$(grep -E "Num transmitted samples:" "$L/bench_$dir.log" | grep -oE '[0-9]+$')
    result "benchmark_rate $dir $N x $RATE, $DUR s, every threshold 0 (rx ${rcv:-?} tx ${snt:-?})" $S
done
(cd "$D" && timeout 90 "$RUN" "$E/txrx_loopback_to_file" --tx-args "$A" --rx-args "$A" --tx-channels "$ALL" \
    --rx-channels "$ALL" --tx-rate "$RATE" --rx-rate "$RATE" --tx-freq 1e9 --rx-freq 1e9 --ampl 0.1 --otw "$WIRE" \
    --nsamps 1000000 --file lb.dat) >"$L/txrx.log" 2>&1 &&
    grep -q "Done!" "$L/txrx.log" && grep -q "Checking RX: LO: locked" "$L/txrx.log"
result "txrx_loopback_to_file: lo_locked checks, timed RX while TX runs, Done!" $?
rm -f "$D"/*.dat
timeout 90 "$RUN" "$E/latency_test" --args "$A" --rate "$RATE" --nruns 20 --nsamps 1000 --rtt 0.01 >"$L/latency.log" 2>&1 &&
    grep -qE "ACKs received: +20/20" "$L/latency.log"
result "latency_test: timed RX then TX at its time + rtt, 20/20 burst ACKs" $?

# --- USRP semantics
timeout 300 "$RUN" "$E/test_messages" --args "$A" --ntests 40 --test-chain >"$L/msgs.log" 2>&1 &&
    grep -q "Test Late Command" "$L/msgs.log" && grep -q "Test Broken Chain" "$L/msgs.log"
result "test_messages --test-chain: late command, broken chain, burst ACK, underflow, time error" $?
timeout 60 "$RUN" "$E/test_timed_commands" --args "$A" >"$L/ttc.log" 2>&1 && grep -q "Done!" "$L/ttc.log"
result "test_timed_commands: set_command_time accepted, timed num_done on time" $?
timeout 60 "$RUN" "$E/test_pps_input" --args "$A" >"$L/pps.log" 2>&1 && grep -qi "success" "$L/pps.log"
result "test_pps_input (emulated PPS): success" $?
timeout 60 "$RUN" "$E/test_pps_input" --args "$A,pps_emulation=0" >"$L/pps_strict.log" 2>&1
[ $? -ne 0 ] && grep -q "no PPS input" "$L/pps_strict.log"
result "test_pps_input pps_emulation=0: refuses (no PPS input on the board)" $?
timeout 30 "$RUN" "$E/gpio" --args "$A" >"$L/gpio.log" 2>&1
[ $? -ne 0 ] && grep -q "no GPIO" "$L/gpio.log"
result "gpio: fails cleanly (no GPIO)" $?

# --- the Python examples (the python bindings over the same module)
# a 50 ms RX ring (32768 frames at 1.25 GS/s): the example starts its RX thread,
# then creates the TX streamer on the main thread, and UHD's binding holds the
# GIL through get_tx_stream() (~30 ms here), so recv() is not called for that
# long; a smaller ring overflows once at the start (21-28 M samples dropped)
timeout $((DUR + 60)) "$RUN" python3 "$PYE/benchmark_rate.py" --args "$A${BENCH_ARGS:+,$BENCH_ARGS},num_recv_frames=32768" --channels $(seq 0 $((N - 1))) \
    --rx_rate "$RATE" --tx_rate "$RATE" --rx_otw "$WIRE" --tx_otw "$WIRE" --duration "$DUR" >"$L/py_bench.log" 2>&1
S=$?
grep -qE "Dropped samples: +0$|Num dropped samples: +0$" "$L/py_bench.log" &&
    grep -qE "underruns detected: +0$" "$L/py_bench.log"
DROPS=$?
result "python benchmark_rate.py rx+tx $N x $RATE: exit 0, 0 dropped, 0 underruns" $((S | DROPS))
if [ "$WIRE" = sc16 ]; then
    timeout 60 "$RUN" python3 "$PYE/rx_to_file.py" --args "$A,pattern=1" -r "$RATE" -f 1e9 -d 0.01 \
        -c $(seq 0 $((N - 1))) -o "$D/py_rx.dat" >"$L/py_rx.log" 2>&1 && [ -s "$D/py_rx.dat" ]
    S=$?
    result "python rx_to_file.py: exit 0, file written ($(stat -c %s "$D/py_rx.dat" 2>/dev/null || echo 0) bytes)" $S
    rm -f "$D"/*.dat
    timeout 60 "$RUN" python3 "$PYE/tx_waveforms.py" --args "$A" -r "$RATE" -f 1e9 -d 2 --wave-ampl 0.1 \
        -c $(seq 0 $((N - 1))) >"$L/py_txw.log" 2>&1
    result "python tx_waveforms.py 2 s: exit 0" $?

    # --- this project's harnesses through the same Python API
    timeout 120 "$RUN" python3 "$TOOLS/uhd_smoke.py" --args "$A,pattern=1" --rate "$RATE" >"$L/smoke.log" 2>&1
    result "uhd_smoke.py: recv_num_samps / timed off-grid num_done trim / send_waveform, bit-exact" $?
    timeout 300 "$RUN" python3 "$TOOLS/uhd_semantics.py" --args "$A,pattern=1" --rate "$RATE" >"$L/sem.log" 2>&1
    S=$?
    # (a check line may carry UHD's async 'L' / 'O' marks in front of PASS / FAIL)
    result "uhd_semantics.py: $(grep -cE '^[A-Z]?PASS ' "$L/sem.log") PASS, $(grep -cE '^[A-Z]?FAIL ' "$L/sem.log") FAIL (late, chains, FIFO, tune, LO, sensors, fragments, timed, PPS)" $S
else
    for ex in "python rx_to_file.py" "python tx_waveforms.py"; do
        na "$ex" "MultiUSRP.recv_num_samps/send_waveform hard-code otw sc16; this build carries $WIRE only"
    done
    na "uhd_smoke.py" "uses recv_num_samps/send_waveform (otw sc16) and checks the sc16 pattern"
    na "uhd_semantics.py" "checks the full-precision sc16 pattern counter"
fi

rm -rf "$D"
echo "not run (not applicable): rfnoc_* x5 and network_relay (not an RFNoC device); twinrx_freq_hopping,"
echo "  test_dboard_coercion, spi, sync_to_gps (Ettus daughterboard/SPI/GPSDO); test_clock_synch (needs an"
echo "  OctoClock); rx_ascii_art_dft and python curses_fft/usrp_power_meter/remote_rx/replay_capture/"
echo "  x440_L_band_capture (interactive, or another device's feature)"
echo "$FAILS failure(s) in $NRUN checks, $NNA not applicable to this build; logs in $L"
exit $FAILS
