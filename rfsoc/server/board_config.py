"""Board-local configuration of the ZCU216 UHD daemon (PROTOCOL.md §1).

No IP address is written into the code. What the daemon needs to know:

* the board's management address (control, discovery): NOT configured. Every
  reply carries the address the request arrived on (discovery: IP_PKTINFO of
  the datagram, else the route back to the asker; control: the TCP socket's
  local address), so a DHCP change of the LAN address needs nothing.
  `--mgmt-ip` overrides it (e.g. behind NAT).
* the FPGA's 100G data IP and MAC: the FPGA has no DHCP, and the PC's 100G
  port (host/setup_cx5.sh <iface> <addr/prefix>) must sit on the same subnet,
  so these are configuration, read from a small file on the board:

      data_ip  = <fpga data ip>     required in hardware mode
      data_mac = <fpga data mac>    optional: derived from the board's eth0 MAC
      name     = <device name>      optional: discovery name (default zcu216-0)

  `key = value` lines, `#` comments. Searched in this order:
  $ZCU216_UHD_CONF, <this directory>/zcu216_uhd.conf, /etc/zcu216_uhd.conf.
  zcu216_uhd.conf is git-ignored; zcu216_uhd.conf.example documents it.
  Command-line `--data-ip` / `--data-mac` / `--name` override the file.

The host learns all of it from discovery / `info` (data_ip=, data_mac=).
"""
from __future__ import annotations

import ipaddress
import os
import re
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
CONF_NAME = "zcu216_uhd.conf"
KEYS = ("data_ip", "data_mac", "name")
_MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")


class ConfigError(ValueError):
    pass


def config_paths() -> List[str]:
    out = []
    if os.environ.get("ZCU216_UHD_CONF"):
        out.append(os.environ["ZCU216_UHD_CONF"])
    out += [os.path.join(HERE, CONF_NAME), os.path.join("/etc", CONF_NAME)]
    return out


def parse(text: str, where: str = "<config>") -> Dict[str, str]:
    cfg: Dict[str, str] = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise ConfigError(f"{where}:{n}: expected 'key = value', got {raw.strip()!r}")
        k, v = (x.strip() for x in line.split("=", 1))
        if k not in KEYS:
            raise ConfigError(f"{where}:{n}: unknown key {k!r} (known: {', '.join(KEYS)})")
        cfg[k] = v
    if "data_ip" in cfg:
        cfg["data_ip"] = check_ip(cfg["data_ip"], f"{where}: data_ip")
    if "data_mac" in cfg:
        cfg["data_mac"] = check_mac(cfg["data_mac"], f"{where}: data_mac")
    return cfg


def load(path: Optional[str] = None) -> Tuple[Dict[str, str], Optional[str]]:
    """-> (settings, the file they came from or None). An explicit `path`
    must exist; the search list may come up empty."""
    paths = [path] if path else config_paths()
    for p in paths:
        if os.path.isfile(p):
            with open(p) as f:
                return parse(f.read(), p), p
        if path:
            raise ConfigError(f"{p}: no such file")
    return {}, None


def check_ip(s: str, what: str = "IP") -> str:
    try:
        return str(ipaddress.IPv4Address(s.strip()))
    except (ipaddress.AddressValueError, ValueError):
        raise ConfigError(f"{what}: bad IPv4 address {s!r}")


def check_mac(s: str, what: str = "MAC") -> str:
    m = s.strip().lower().replace("-", ":")
    if not _MAC_RE.match(m):
        raise ConfigError(f"{what}: bad MAC {s!r}")
    return m


def derived_mac(ifaces=("eth0", "end0", "enp0s0")) -> Optional[str]:
    """A locally administered unicast MAC made from the board's own LAN MAC
    (first octet: bit 1 set, bit 0 clear): unique per board, stable, and
    never equal to the LAN MAC itself, which is universally administered."""
    for iface in ifaces:
        try:
            with open(f"/sys/class/net/{iface}/address") as f:
                b = bytes.fromhex(f.read().strip().replace(":", ""))
        except (OSError, ValueError):
            continue
        if len(b) != 6 or not any(b):
            continue
        b = bytes([(b[0] | 0x02) & 0xFE]) + b[1:]
        return ":".join("%02x" % x for x in b)
    return None


def resolve(data_ip: Optional[str], data_mac: Optional[str], name: Optional[str],
            config: Optional[str] = None, need_data_ip: bool = True
            ) -> Tuple[Optional[str], Optional[str], str, str]:
    """Command line over config file over derivation.
    -> (data_ip, data_mac, name, how: a one-line description for the log).
    ConfigError when hardware needs a data IP and none is configured."""
    cfg, where = load(config)
    src = []
    ip = data_ip or cfg.get("data_ip")
    if data_ip:
        ip = check_ip(data_ip, "--data-ip")
        src.append("data_ip from --data-ip")
    elif ip:
        src.append(f"data_ip from {where}")
    elif need_data_ip:
        raise ConfigError(
            "no FPGA data IP configured: put 'data_ip = <fpga data ip>' (an "
            "address on the subnet of the PC's 100G port) into "
            f"{' or '.join(config_paths()[-2:])} (see {CONF_NAME}.example), "
            "or pass --data-ip")
    mac = None
    if data_mac:
        mac = check_mac(data_mac, "--data-mac")
        src.append("data_mac from --data-mac")
    elif cfg.get("data_mac"):
        mac = cfg["data_mac"]
        src.append(f"data_mac from {where}")
    else:
        mac = derived_mac()
        if mac:
            src.append("data_mac derived from the eth0 MAC")
        elif need_data_ip:
            raise ConfigError("no FPGA data MAC: set 'data_mac' in the config file or "
                              "pass --data-mac (no eth0 MAC to derive one from)")
    nm = name or cfg.get("name") or "zcu216-0"
    return ip, mac, nm, "; ".join(src) or "no data-plane address (sim)"
