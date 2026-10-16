#!/usr/bin/env python3
"""otw_ctl_refusal.py -- does the daemon itself refuse an OTW format a build cannot
carry (Protocol §10)? Talks the control protocol directly (no UHD, no
data plane): claim, set_channels N, set the rate with otw=sc16, then ask for
fc32 on the RX and TX stream setups and on a rate request, and print each reply.

    python3 benchmark/otw_ctl_refusal.py --addr <board-ip> --channels 2 --rate 1.2e9
"""
import argparse
import socket

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--addr", required=True)
ap.add_argument("--port", type=int, default=49710)
ap.add_argument("--channels", type=int, required=True)
ap.add_argument("--rate", type=float, required=True)
ap.add_argument("--fmt", default="fc32")
ap.add_argument("--host-ip", default=None,
                help="this PC's 100G address (default: the local address routed to the FPGA's data_ip)")
a = ap.parse_args()

s = socket.create_connection((a.addr, a.port), timeout=90)
f = s.makefile("rw", newline="\n")


def call(line):
    f.write(line + "\n")
    f.flush()
    r = f.readline().strip()
    print(f"> {line}\n< {r[:300]}")
    return r


call("claim")
call(f"set_channels {a.channels}")
call(f"set_rx_rate 0 {a.rate:.0f} otw=sc16")
info = call("info")
for kv in info.split(";"):
    if kv.split("=")[0] in ("rx_otw_formats", "tx_otw_formats", "otw_formats", "rate_otw", "num_rx"):
        print("   ", kv)
# the address the kernel routes to the FPGA's data_ip (no address built in)
data_ip = dict(kv.split("=", 1) for kv in info[3:].split(";") if "=" in kv).get("data_ip")
host_ip = a.host_ip
if host_ip is None:
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.connect((data_ip, 9))
    host_ip = u.getsockname()[0]
    u.close()
print(f"    host data IP {host_ip} (route to data_ip {data_ip})")
mac = "02:00:00:00:00:01"
call(f"stream_setup 0 {host_ip} {mac} 49810 1 1024 otw={a.fmt}")
call(f"stream_setup_tx 0 {host_ip} {mac} 49820 otw={a.fmt}")
call(f"set_rx_rate 0 {a.rate:.0f} otw={a.fmt}")
call("get_rx_rate 0")
call("unclaim")
