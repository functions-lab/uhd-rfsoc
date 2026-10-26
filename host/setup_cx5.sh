#!/usr/bin/env bash
# Configure an NVIDIA/Mellanox ConnectX (-5, -6, -7; mlx5) port as the 100GbE
# sample link to the board's CMAC (uhd_rfsoc). Idempotent; run as root.
#
#   sudo ./setup_cx5.sh <iface> <host-data-ip>/<prefix>
#   e.g. sudo ./setup_cx5.sh enp1s0f1np1 <host-data-ip>/24   (the name follows the PCIe slot)
# Both arguments are required: the address is the PC's end of the 100G link
# and must share a subnet with the FPGA's data_ip (the board's uhd_rfsoc.conf).
#
# Why each setting:
#   autoneg off, 100000 full  the Xilinx CMAC is built without the (licensed)
#                             AN/LT block, so it never answers clause-73 autoneg.
#                             A NIC left on autoneg waits forever: "No partner".
#   fec rs                    100GBASE-CR4 over a passive 25G-lane DAC needs
#                             RS-FEC (CL91); the CMAC is built with RS-FEC on.
#                             Both ends must agree or PCS never aligns.
#   mtu 9000                  one 8 KiB sample payload per datagram (the DPDK
#                             port takes its MTU from this netdev).
#   pause off                 CMAC is built without 802.3x pause; keep the NIC
#                             from emitting pause frames the FPGA would ignore.
# Samples are received by DPDK (setup_dpdk.sh), not by the kernel, so kernel
# socket buffers and NIC ring sizes do not matter.
#
# Persistence: add to the iface stanza in /etc/network/interfaces
#     mtu 9000
#     post-up <repo>/host/setup_cx5.sh $IFACE <host-data-ip>/<prefix>
# and keep NetworkManager off the port (nmcli device set $IFACE managed no).
set -euo pipefail

[[ $# -eq 2 ]] || { sed -n '5,9p' "$0" >&2; echo "usage: $0 <iface> <host-data-ip>/<prefix>" >&2; exit 2; }
IFACE=$1
ADDR=$2
[[ $ADDR == */* ]] || { echo "address needs a prefix length: $ADDR/<prefix>" >&2; exit 2; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -e /sys/class/net/$IFACE ]] || { echo "no such interface: $IFACE" >&2; exit 1; }

ip link set dev "$IFACE" mtu 9000
ip link set dev "$IFACE" up
ip -4 addr show dev "$IFACE" | grep -q "inet ${ADDR%/*}/" || ip addr add "$ADDR" dev "$IFACE"

# lanes 4: a 200G / 400G port (ConnectX-7) otherwise may pick 2 x 50G PAM4
# lanes; the board is 100G CAUI-4 (4 x 25G NRZ). An ethtool without "lanes"
# falls back to the plain request.
ethtool -s "$IFACE" autoneg off speed 100000 duplex full lanes 4 2>/dev/null \
    || ethtool -s "$IFACE" autoneg off speed 100000 duplex full
ethtool --set-fec "$IFACE" encoding rs
ethtool -A "$IFACE" autoneg off rx off tx off 2>/dev/null || true

echo "== $IFACE"
ethtool "$IFACE" | grep -E "Speed|Duplex|Auto-negotiation|Link detected"
ethtool --show-fec "$IFACE" | grep -E "Configured|Active"
ip -br addr show dev "$IFACE"
