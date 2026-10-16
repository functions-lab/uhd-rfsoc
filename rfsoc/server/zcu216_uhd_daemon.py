#!/usr/bin/env python3
"""ZCU216 UHD daemon: makes the ZCU216 look like a USRP to UHD (type=zcu216).

Contract: Protocol (../../AGENTS.md) -- UDP discovery (49700), line-based TCP control
(49710), VRT-style UDP samples over the 100GbE CMAC link.

    # real hardware (root, PYNQ venv); every zcu216_v49_<N>ch_qsfp*.bit with a
    # .hwh in --bitstream-dir is a selectable build (N channels, one factor):
    sudo -E python3 zcu216_uhd_daemon.py [--bitstream-dir DIR] [--bitstream X.bit]

The same daemon serves an RFSoC 4x2 (rfsoc4x2_v49_<N>ch_qsfp*.bit, N = 1, 2):
--board RFSoC4x2, or $UHD_BOARD, or nothing when the bitstream directory holds
only RFSoC 4x2 builds (boards.py). UHD still sees type=zcu216 (the protocol);
discovery reports product=rfsoc4x2.

Addresses (Protocol §1, board_config.py): the management address in every
reply is the one the request arrived on (nothing configured); the FPGA's 100G
data IP/MAC come from zcu216_uhd.conf (or --data-ip / --data-mac).
"""
from __future__ import annotations

import argparse
import logging
import os
import signal
import socket
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import vrt  # noqa: E402
from protocol import (ControlCore, DISC_REQUEST, MAX_LINE, Session)  # noqa: E402

log = logging.getLogger("zcu216.daemon")

# the default build of each board: boards.BOARDS[...].default_bitstream
# (ZCU216: zcu216_v49_1ch_qsfp_f2_fs2500.bit, 1 channel at 1250 MS/s)
# Linux <netinet/in.h>; Python's socket module does not always export it
IP_PKTINFO = getattr(socket, "IP_PKTINFO", 8)


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def default_serial(board: str = "ZCU216") -> str:
    for iface in ("eth0", "end0", "enp0s0"):
        try:
            with open(f"/sys/class/net/{iface}/address") as f:
                mac = f.read().strip().replace(":", "")
            return f"{board}-" + mac[-6:].upper()
        except OSError:
            continue
    return f"{board}-0"


def local_ip_towards(addr: str) -> str:
    """The local address the kernel would use to reach `addr` (no packet
    sent); "" if there is no route."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((addr, 9))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def pktinfo_local_ip(ancdata) -> str:
    """The local address a datagram arrived on, from its IP_PKTINFO control
    message (struct in_pktinfo: ifindex, spec_dst, addr): spec_dst is the
    receiving interface's address even for a broadcast; "" if absent."""
    for level, typ, data in ancdata:
        if level == socket.IPPROTO_IP and typ == IP_PKTINFO and len(data) >= 12:
            _ifindex, spec_dst, _dst = struct.unpack("=i4s4s", data[:12])
            ip = socket.inet_ntoa(spec_dst)
            if ip != "0.0.0.0":
                return ip
    return ""


# --------------------------------------------------------------------------
# servers
# --------------------------------------------------------------------------

class DiscoveryServer(threading.Thread):
    def __init__(self, core: ControlCore, bind: str, port: int, mgmt_ip: str = ""):
        super().__init__(name="discovery", daemon=True)
        self.core, self.mgmt_ip = core, mgmt_ip
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            self.sock.setsockopt(socket.IPPROTO_IP, IP_PKTINFO, 1)
            self._pktinfo = True
        except OSError:
            self._pktinfo = False
        self.sock.bind((bind, port))
        self.sock.settimeout(0.5)
        self.running = True

    def run(self):
        while self.running:
            try:
                if self._pktinfo:
                    data, anc, _flags, addr = self.sock.recvmsg(2048, socket.CMSG_SPACE(12))
                else:
                    data, addr = self.sock.recvfrom(2048)
                    anc = []
            except socket.timeout:
                continue
            except OSError:
                if not self.running:
                    return
                continue
            try:
                if data.strip() != DISC_REQUEST.encode():
                    log.debug("discovery: ignoring %r from %s", data[:64], addr)
                    continue
                # the board address the request arrived on (learned per
                # request: a DHCP change needs no restart), unless overridden
                ip = (self.mgmt_ip or pktinfo_local_ip(anc)
                      or local_ip_towards(addr[0]))
                reply = self.core.discovery_reply(ip)
                self.sock.sendto(reply.encode() + b"\n", addr)
                log.info("discovery from %s:%d -> %s", addr[0], addr[1], ip)
            except Exception:
                log.exception("discovery reply to %s failed", addr)

    def stop(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass


class ControlServer(threading.Thread):
    def __init__(self, core: ControlCore, bind: str, port: int, mgmt_ip: str = ""):
        super().__init__(name="control", daemon=True)
        self.core, self.mgmt_ip = core, mgmt_ip
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((bind, port))
        self.sock.listen(8)
        self.sock.settimeout(0.5)
        self.running = True
        self.clients = set()
        self.clients_lock = threading.Lock()

    def run(self):
        while self.running:
            try:
                conn, addr = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                if not self.running:
                    return
                continue
            t = threading.Thread(target=self._client, args=(conn, addr),
                                 name=f"client-{addr[0]}:{addr[1]}", daemon=True)
            t.start()

    def _client(self, conn: socket.socket, addr):
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        for opt, val in (("TCP_KEEPIDLE", 30), ("TCP_KEEPINTVL", 10),
                         ("TCP_KEEPCNT", 3)):
            if hasattr(socket, opt):
                try:
                    conn.setsockopt(socket.IPPROTO_TCP, getattr(socket, opt), val)
                except OSError:
                    pass
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        local = self.mgmt_ip or conn.getsockname()[0]
        sess = Session(peer=f"{addr[0]}:{addr[1]}", local_ip=local)
        with self.clients_lock:
            self.clients.add(conn)
        log.info("%s connected", sess)
        buf = b""
        discarding = False
        try:
            while self.running:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while True:
                    nl = buf.find(b"\n")
                    if nl < 0:
                        if len(buf) > MAX_LINE:
                            # overlong line: answer once, drop until newline
                            if not discarding:
                                conn.sendall(b"ERR line too long\n")
                            discarding, buf = True, b""
                        break
                    line, buf = buf[:nl], buf[nl + 1:]
                    if discarding:
                        discarding = False
                        continue
                    reply = self.core.handle_line(sess, line)
                    log.debug("%s: %r -> %r", sess, line[:200], reply[:200])
                    conn.sendall(reply.encode("utf-8") + b"\n")
        except (ConnectionError, OSError) as e:
            log.info("%s: %s", sess, e)
        finally:
            self.core.disconnect(sess)
            with self.clients_lock:
                self.clients.discard(conn)
            try:
                conn.close()
            except OSError:
                pass
            log.info("%s closed", sess)

    def stop(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass
        with self.clients_lock:
            for c in list(self.clients):
                try:
                    c.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bitstream-dir", default=HERE,
                   help="directory scanned for the builds <board>_v49_<N>ch_qsfp*.bit "
                        "(+ .hwh): N channels, one rate each [%(default)s]")
    p.add_argument("--bitstream", default=None,
                   help="bitstream loaded at start (.hwh next to it) [<dir>/"
                        f"the board's default (ZCU216: zcu216_v49_1ch_qsfp_f2_fs2500.bit), "
                        f"else the highest-rate variant]")
    p.add_argument("--board", default=None, type=str.upper, choices=("ZCU216", "RFSOC4X2"),
                   help="board [$UHD_BOARD, else the board of --bitstream, else the "
                        "one whose v49 builds are in --bitstream-dir, else ZCU216]")
    p.add_argument("--no-load", action="store_true",
                   help="attach to the already-loaded bitstream (no download)")
    p.add_argument("--port", type=int, default=49710, help="control TCP port")
    p.add_argument("--disc-port", type=int, default=49700, help="discovery UDP port")
    p.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    p.add_argument("--mgmt-ip", default="",
                   help="management IP to advertise, overriding the default: the "
                        "address each request arrived on")
    p.add_argument("--config", default=None,
                   help="settings file [$ZCU216_UHD_CONF, <this dir>/zcu216_uhd.conf, "
                        "/etc/zcu216_uhd.conf; see zcu216_uhd.conf.example]")
    p.add_argument("--data-ip", default=None,
                   help="FPGA 100G data IP [config data_ip]")
    p.add_argument("--data-mac", default=None,
                   help="FPGA 100G MAC [config data_mac, else derived from the eth0 MAC]")
    p.add_argument("--serial", default=None, help="device serial [from eth0 MAC]")
    p.add_argument("--name", default=None, help="device name [config name, else the board: zcu216, rfsoc4x2]")
    p.add_argument("--log", default=None, help="log file (default: stderr)")
    p.add_argument("--chain-grace-ms", type=float, default=1.0,
                   help="an open num_more chain streams this long past its end "
                        "before the daemon stops it; a continuation arriving "
                        "within it is seamless (Protocol §4a) [%(default)s]")
    p.add_argument("-v", "--verbose", action="store_true")
    hw = p.add_argument_group("hardware backend")
    hw.add_argument("--lib-root", default=None,
                    help="directory containing rfsoc_lib/ [searched upward]")
    hw.add_argument("--allow-unlocked", action="store_true",
                    help="serve even if a converter tile clock is not good")
    hw.add_argument("--nco-phase-reset", choices=("all", "tuned", "off"), default="all",
                    help="after NCO changes, reset the NCO phase of every streamed "
                         "channel of that direction (all), of the retuned ones "
                         "(tuned), or never (off), with one mixer update event per "
                         "tile: fixed inter-channel phase within a tile after every "
                         "tune (Protocol §3d) [%(default)s]")
    hw.add_argument("--rx-freq", type=float, default=600e6, help="initial RX freq")
    hw.add_argument("--tx-freq", type=float, default=600e6, help="initial TX freq")
    from bringup import add_link_args
    add_link_args(p)
    return p


def resolve_bitstreams(bitstream_dir: str, bitstream, board=None):
    """-> (initial bitstream path, [Variant...] by channel count, highest
    rate first) of `board` (boards.Board, default ZCU216).

    The explicit --bitstream wins the (N, rate) it shares with a scanned file.
    Without --bitstream: the board's default build in <dir> if present, else
    the highest-rate build with the fewest channels, else that default path
    (bring-up then fails with the missing file)."""
    from hw_backend import scan_bitstreams
    from boards import get_board
    board = board or get_board(None)
    extra = (os.path.abspath(bitstream),) if bitstream else ()
    variants = scan_bitstreams(bitstream_dir, extra=extra, board=board)
    if bitstream:
        return os.path.abspath(bitstream), variants
    default = os.path.abspath(os.path.join(bitstream_dir, board.default_bitstream))
    if any(v.bitstream == default for v in variants) or not variants:
        return default, variants
    return variants[0].bitstream, variants


def resolve_board(args):
    """--board, else boards.detect_board ($UHD_BOARD, --bitstream's name,
    the builds in --bitstream-dir, ZCU216)."""
    from boards import detect_board, get_board
    if args.board:
        return get_board(args.board)
    return detect_board(args.bitstream_dir, args.bitstream)


def make_backend(args, board):
    from hw_backend import HwBackend
    from bringup import link_opts
    bitstream, variants = resolve_bitstreams(args.bitstream_dir, args.bitstream, board)
    log.info("%s bitstream variants in %s: %s", board.name, args.bitstream_dir,
             "; ".join(repr(v) for v in variants) or "none readable")
    return HwBackend(bitstream=bitstream, variants=variants, board=board,
                     data_ip=args.data_ip, data_mac=args.data_mac,
                     lib_root=args.lib_root, load=not args.no_load,
                     allow_unlocked=args.allow_unlocked,
                     rx_freq=args.rx_freq, tx_freq=args.tx_freq,
                     nco_phase_reset=args.nco_phase_reset,
                     rx_chain_grace_s=args.chain_grace_ms / 1e3,
                     **link_opts(args))


def main(argv=None) -> int:
    args = build_argparser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        filename=args.log,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # FPGA data IP/MAC: command line, else the config file (board_config.py)
    import board_config
    try:
        args.data_ip, args.data_mac, args.name, how = board_config.resolve(
            args.data_ip, args.data_mac, args.name, config=args.config)
    except board_config.ConfigError as e:
        log.error("%s", e)
        return 2
    log.info("addresses: management = the address each request arrives on%s; %s",
             f" (overridden: {args.mgmt_ip})" if args.mgmt_ip else "", how)
    if os.geteuid() != 0:
        log.warning("hardware mode normally needs root (PYNQ /dev/mem, xrfdc)")

    try:
        board = resolve_board(args)
    except ValueError as e:
        log.error("%s", e)
        return 2
    log.info("board %s", board.name)
    try:
        be = make_backend(args, board)
    except Exception:
        log.exception("backend bring-up failed; not serving")
        return 1

    core = ControlCore(be, serial=args.serial or default_serial(board.name),
                       name=args.name or board.name.lower(), data_ip=args.data_ip,
                       data_mac=args.data_mac, mgmt_ip=args.mgmt_ip)
    try:
        ctl = ControlServer(core, args.bind, args.port, args.mgmt_ip)
        disc = DiscoveryServer(core, args.bind, args.disc_port, args.mgmt_ip)
    except OSError as e:
        log.error("cannot bind control/discovery ports: %s", e)
        be.close()
        return 1

    stop = threading.Event()

    def on_signal(signum, _frame):
        log.info("signal %d: shutting down", signum)
        stop.set()
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    ctl.start()
    disc.start()
    log.info("serving %s (%s) serial=%s: control tcp/%d, discovery udp/%d, "
             "%d channel(s) of {%s}, tick_rate %.17g (%d tick(s)/slot), rate %.17g "
             "of {%s}, TX beamformer %s, RX beamformer %s, data %s %s", core.name, be.fpga_name,
             core.serial, args.port, args.disc_port, be.num_channels,
             ",".join(str(n) for n in be.channel_counts()), be.tick_rate,
             be.ticks_per_slot, be.samp_rate,
             ",".join("%.17g" % r for r in be.available_rates()),
             "yes" if be.has_bf else "no", "yes" if be.has_rbf else "no",
             args.data_ip or "<management ip>", args.data_mac or "-")
    try:
        while not stop.is_set():
            stop.wait(0.5)
    finally:
        disc.stop()
        ctl.stop()
        with core.lock:
            if core.owner is not None:
                core._release()
        be.close()
        ctl.join(2.0)
        disc.join(2.0)
        log.info("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
