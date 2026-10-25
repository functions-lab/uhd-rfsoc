#!/usr/bin/env bash
# isolate_cpus.sh -- keep the rest of the system off the CPUs the module polls
# and converts on, for full-rate runs. Runtime only: nothing persists across a
# reboot, and `restore` undoes it.
#
#   sudo tools/isolate_cpus.sh apply <housekeeping CPUs>    e.g. apply 9 or apply 9,11
#   sudo tools/isolate_cpus.sh restore
#   tools/isolate_cpus.sh status
#
# Why: the module's lcores busy-poll and its workers convert on fixed CPUs
# (host/AGENTS.md "Full-rate duplex"). Without isolation everything else may
# run there too. Measured on a 6-core / 12-thread x86 host in a 22 s full-rate
# duplex run: system daemons, the desktop, kworkers, rcu_sched and a weekly
# fstrim were switched in on those CPUs thousands of times, and the two DPDK
# lcores were preempted 36 and 28 times. Each preemption is a stall the
# ~175-350 us of FPGA TX buffer / the RX rings must cover; when one does not,
# both directions lose at once (an RX overflow and TX underruns in one run).
#
# apply:   every task's affinity (all threads; per-CPU kernel threads refuse
#          and stay), the unbound workqueue cpumask and every movable IRQ go
#          to the housekeeping CPUs: the CPUs the module's layout leaves free
#          (with the default layout none is free; the full-rate duplex layout
#          of host/AGENTS.md leaves one). Processes started later inherit their
#          parent's affinity; the module pins its own threads with
#          sched_setaffinity (lcores, workers, ZCU216_APP_CPUS), which is not
#          limited by this.
# restore: all of the above back to every online CPU.
set -u
cmd=${1:-status}
ALLCPUS=0-$(($(nproc --all) - 1))

mask_of() { # cpu list -> hex mask
    python3 -c "import sys
m = 0
for p in sys.argv[1].split(','):
    a, _, b = p.partition('-'); b = b or a
    for c in range(int(a), int(b) + 1): m |= 1 << c
print('%x' % m)" "$1"
}

set_all() { # cpu list
    local list=$1 mask moved=0 kept=0 irqs=0
    mask=$(mask_of "$list")
    for p in /proc/[0-9]*; do
        taskset -a -p -c "$list" "${p#/proc/}" >/dev/null 2>&1 && moved=$((moved + 1)) || kept=$((kept + 1))
    done
    echo "$mask" > /sys/devices/virtual/workqueue/cpumask 2>/dev/null
    for i in /proc/irq/[0-9]*; do
        echo "$list" > "$i/smp_affinity_list" 2>/dev/null && irqs=$((irqs + 1))
    done
    echo "$list" > /proc/irq/default_smp_affinity 2>/dev/null || echo "$mask" > /proc/irq/default_smp_affinity
    echo "tasks moved to $list: $moved (refused, per-CPU kernel threads: $kept); IRQs: $irqs; workqueues: $(cat /sys/devices/virtual/workqueue/cpumask)"
}

case $cmd in
    apply)
        [ -n "${2:-}" ] || { echo "usage: $0 apply <housekeeping CPUs>  (e.g. apply 9)" >&2; exit 2; }
        [ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
        set_all "$2"
        ;;
    restore)
        [ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"
        set_all "$ALLCPUS"
        ;;
    status)
        echo "workqueue cpumask $(cat /sys/devices/virtual/workqueue/cpumask), default IRQ affinity $(cat /proc/irq/default_smp_affinity)"
        echo "PID 1 affinity: $(taskset -c -p 1 | sed 's/.*: //')"
        ;;
    *)
        echo "usage: $0 apply <housekeeping CPUs> | restore | status" >&2
        exit 2
        ;;
esac
