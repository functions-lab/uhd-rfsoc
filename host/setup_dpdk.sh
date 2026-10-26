#!/usr/bin/env bash
# Prepare the PC for the DPDK data plane of libuhd_rfsoc.so (its only sample
# transport). Idempotent; run as root.
#
#   sudo ./setup_dpdk.sh <iface> [nr_2M_hugepages]
#   <iface>: the ConnectX 100G netdev (its name follows the PCIe slot, e.g.
#   enp1s0f1np1); nr_2M_hugepages default 4096 (8 GB)
#   --install   also apt-get install the missing packages
#   --clean     also delete stale hugepage files in /dev/hugepages that no
#               process has open (left by a DPDK app run without --in-memory)
#
# What DPDK needs here, and why:
#   dpdk, libdpdk-dev        the EAL/ethdev libraries and pkg-config libdpdk
#                            (CMake refuses to build the module without it)
#   rdma-core,               the mlx5 PMD is *bifurcated*: it talks to the
#   ibverbs-providers        ConnectX through libibverbs/libmlx5 while the
#                            kernel mlx5_core driver keeps the netdev. No vfio
#                            binding: the netdev, its IP, ARP and ping keep working.
#   hugepages                mbuf pools (~200 MB at nports=4 with 4096 RX
#                            descriptors, 10 KB each). 2 MB pages via
#                            /etc/sysctl.d/61-dpdk-hugepages.conf, hugetlbfs
#                            mounted at /dev/hugepages.
#   root                     the module checks CAP_NET_ADMIN, CAP_NET_RAW and
#                            CAP_IPC_LOCK; run UHD apps through the wrapper
#                            uhd-rfsoc <app> [args] (installed by cmake --install)
#   the NIC itself           setup_cx5.sh (link, FEC, MTU 9000).
set -euo pipefail

INSTALL=0 CLEAN=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --install) INSTALL=1 ;;
        --clean) CLEAN=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done
[[ ${#ARGS[@]} -ge 1 ]] || { echo "usage: $0 <iface> [nr_2M_hugepages] [--install] [--clean]" >&2; exit 2; }
IFACE=${ARGS[0]}
NR=${ARGS[1]:-4096}
FAIL=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

echo "== packages"
MISSING=()
for p in dpdk libdpdk-dev rdma-core ibverbs-providers pkg-config; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
        ok "$p $(dpkg-query -W -f='${Version}' "$p")"
    else
        MISSING+=("$p")
    fi
done
if ((${#MISSING[@]})); then
    if ((INSTALL)); then
        apt-get install -y "${MISSING[@]}"
        ok "installed ${MISSING[*]}"
    else
        bad "missing: ${MISSING[*]}  (rerun with --install, or apt-get install them)"
    fi
fi
if V=$(pkg-config --modversion libdpdk 2>/dev/null); then ok "pkg-config libdpdk $V"; else bad "pkg-config libdpdk not found"; fi

echo "== hugepages (2 MB x $NR)"
SYSCTL=/etc/sysctl.d/61-dpdk-hugepages.conf
WANT="vm.nr_hugepages = $NR"
if ! grep -qx "$WANT" "$SYSCTL" 2>/dev/null; then
    printf '# DPDK (uhd_rfsoc): %s MB of 2 MB hugepages for the mlx5 PMD\n%s\n' "$((NR * 2))" "$WANT" > "$SYSCTL"
    ok "wrote $SYSCTL"
fi
CUR=$(cat /proc/sys/vm/nr_hugepages)
if ((CUR < NR)); then
    sysctl -q -w vm.nr_hugepages="$NR"
    CUR=$(cat /proc/sys/vm/nr_hugepages)
fi
((CUR >= NR)) && ok "nr_hugepages $CUR" || bad "nr_hugepages $CUR < $NR (memory fragmented? reboot applies $SYSCTL)"
if mountpoint -q /dev/hugepages; then
    ok "hugetlbfs on /dev/hugepages"
else
    mkdir -p /dev/hugepages && mount -t hugetlbfs nodev /dev/hugepages && ok "mounted hugetlbfs on /dev/hugepages"
fi
STALE=()
for f in /dev/hugepages/*; do
    [[ -e $f ]] || continue
    command -v fuser >/dev/null && fuser -s "$f" 2>/dev/null && continue
    STALE+=("$f")
done
if ((${#STALE[@]})); then
    if ((CLEAN)); then rm -f "${STALE[@]}"; ok "removed ${#STALE[@]} stale hugepage file(s)"
    else echo "  note  ${#STALE[@]} stale hugepage file(s) in /dev/hugepages hold pages (--clean removes them)"; fi
fi
grep -E "HugePages_(Total|Free)" /proc/meminfo | sed 's/^/        /'

echo "== NIC $IFACE"
if [[ -e /sys/class/net/$IFACE ]]; then
    PCI=$(basename "$(readlink -f "/sys/class/net/$IFACE/device")")
    DRV=$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver")")
    [[ $DRV == mlx5_core ]] && ok "$PCI driver $DRV (bifurcated mlx5 PMD: no vfio binding)" \
                            || bad "$PCI driver $DRV (the DPDK transport expects mlx5_core)"
    if ls "/sys/class/net/$IFACE/device/infiniband" >/dev/null 2>&1; then
        ok "RDMA device $(ls "/sys/class/net/$IFACE/device/infiniband" | tr '\n' ' ')"
    else
        bad "no RDMA device under $IFACE (load mlx5_ib: modprobe mlx5_ib)"
    fi
    MTU=$(cat "/sys/class/net/$IFACE/mtu")
    ((MTU >= 9000)) && ok "MTU $MTU" || bad "MTU $MTU (run setup_cx5.sh)"
    ip -br addr show dev "$IFACE" | sed 's/^/        /'
    echo "  use   device arg dpdk_port=$PCI (the default is the PCI device of the data interface)"
else
    bad "no such interface: $IFACE"
fi

echo "== result: $FAIL problem(s)"
exit $FAIL
