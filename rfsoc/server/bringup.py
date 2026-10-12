#!/usr/bin/env python3
"""Step-by-step 100G link bring-up of zcu216_v49_1ch_qsfp, printing everything.

Run ON THE BOARD as root in the PYNQ venv. Modes:

  --status        read and decode only (no writes): CMAC ctl/status, clock
                  meters, streamer/player registers, 8A34001 status. Refuses
                  unless PYNQ says zcu216_v49_1ch_qsfp is the loaded bitstream
                  (reading an unmapped AXI address can hang the PS).
  --link-only     bitstream already loaded: skip overlay + RFDC, do steps b-f.
  (default)       a) load overlay + RFDC bring-up (hw_backend, the RfdcTask
                     pattern), b) program the 8A34001 to 156.25 MHz, c) check
                     the measured GT refclk / user clock, d) pulse GT reset and
                     wait for rx aligned, printing the decoded status every 0.5 s,
                     e) program streamer/player MAC/IP, f) optionally stream the
                     counter pattern to a host for N seconds (host side:
                     `ethtool -S <iface>` rx_vport_unicast_packets counts it;
                     byte-level checks go through the daemon and
                     rfsoc_lib/uhd/benchmark/dpdk_rx_test.sh).

    sudo bash -c 'source /etc/profile.d/pynq_venv.sh && python3 bringup.py --status'
    sudo bash -c 'source /etc/profile.d/pynq_venv.sh && python3 bringup.py \\
        --stream-host-ip <host-data-ip> --stream-host-mac <cx5 mac> --seconds 10'
    ... --loopback            near-end PMA loopback (no NIC needed for alignment)
    ... --rsfec 0 --rxpol 0x5 --dfe --no-refclk
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from typing import Callable, Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import eth100g as E  # noqa: E402
import vrt  # noqa: E402


def _gt_refclk():
    """rfsoc_lib.gt_refclk (the 8A34001 GT refclk driver lives in rfsoc_lib,
    with its register file in rfsoc_lib/xrfclk/ZCU216/)"""
    from backend import find_lib_root
    root = find_lib_root(HERE)
    if root and root not in sys.path:
        sys.path.insert(0, root)
    from rfsoc_lib import gt_refclk
    return gt_refclk

BITSTREAM_NAME = "zcu216_v49_1ch_qsfp"
Printer = Callable[[str], None]


# --------------------------------------------------------------------------
# steps shared with HwBackend
# --------------------------------------------------------------------------

def add_link_args(ap: argparse.ArgumentParser) -> None:
    g = ap.add_argument_group("100G link")
    g.add_argument("--no-refclk", action="store_true",
                   help="do not program the 8A34001 (GT refclk)")
    g.add_argument("--rsfec", type=int, choices=(0, 1), default=1,
                   help="RS-FEC, must match the NIC [%(default)s]")
    g.add_argument("--rxpol", type=lambda s: int(s, 0), default=0,
                   help="RX polarity invert mask, lane0 = bit0 [0]")
    g.add_argument("--txpol", type=lambda s: int(s, 0), default=0,
                   help="TX polarity invert mask [0]")
    g.add_argument("--dfe", action="store_true", help="DFE instead of LPM (all lanes)")
    g.add_argument("--loopback", action="store_true",
                   help="near-end PMA loopback (test without the NIC)")
    g.add_argument("--cmac-timeout", type=float, default=5.0,
                   help="wait for rx aligned [%(default)s s]")


def link_opts(args) -> Dict[str, object]:
    return {"refclk": not args.no_refclk, "rsfec": bool(args.rsfec),
            "rxpol": args.rxpol, "txpol": args.txpol, "dfe": args.dfe,
            "loopback": args.loopback, "timeout": args.cmac_timeout}


def check_clocks(eth: "E.Eth100G", pr: Printer = print) -> Dict[str, object]:
    ref, usr = eth.refclk_khz(), eth.usrclk_khz()
    ref_ok = abs(ref - E.REFCLK_KHZ) <= E.REFCLK_TOL_KHZ
    usr_ok = abs(usr - E.USRCLK_KHZ) <= E.USRCLK_TOL_KHZ
    pr(f"[c] GT refclk {ref} kHz (want {E.REFCLK_KHZ} +/- {E.REFCLK_TOL_KHZ}): "
       f"{'OK' if ref_ok else 'OFF'}")
    if not ref_ok:
        if ref:
            ratio = ref / E.REFCLK_KHZ
            pr(f"    ratio measured/156.25 MHz = {ratio:.6f} -- if the 8A34001 was "
               f"programmed, its crystal is {ratio:.6f} x the assumed 54 MHz "
               f"(= {54.0 * ratio:.4f} MHz)")
        else:
            pr("    no refclk at all (8A34001 not programmed, output high-Z, or "
               "APLL unlocked)")
    pr(f"    CMAC user clock {usr} kHz (want {E.USRCLK_KHZ}; runs only once the GT "
       f"TX PLL is up): {'OK' if usr_ok else 'OFF'}")
    return {"refclk_khz": ref, "usrclk_khz": usr, "refclk_ok": ref_ok,
            "usrclk_ok": usr_ok}


def program_refclk(pr: Printer = print) -> bool:
    pr("[b] 8A34001 -> 156.25 MHz on Q7/Q11")
    try:
        gt_refclk = _gt_refclk()
        gt_refclk.program_gt_refclk(156.25, printer=lambda s: pr("    " + s))
        pr("    programmed")
        return True
    except Exception as e:  # report and continue so the rest can be debugged
        pr(f"    FAILED: {type(e).__name__}: {e} -- continuing")
        return False


def refclk_configured(st: Dict[str, object], mhz: float = 156.25) -> bool:
    """Does a gt_refclk.read_status(allow_page_select=True) result say the
    8A34001 already drives `mhz` on Q7 and Q11 with its system APLL locked?"""
    status = st.get("status")
    if not isinstance(status, dict) or not status.get("sys_apll_locked"):
        return False
    for q in ("Q7", "Q11"):
        out = st.get(q)
        f = out.get("freq_mhz") if isinstance(out, dict) else None
        if f is None or abs(float(f) - mhz) > 1e-6:
            return False
    return True


def ensure_refclk(eth: "E.Eth100G", pr: Printer = print,
                  read_status=None) -> Optional[bool]:
    """Program the 8A34001 only if its status says it is not configured for
    156.25 MHz (the chip is off-FPGA: a bitstream reload leaves it running,
    and re-programming would glitch the GT refclk for nothing).

    Returns None if it was left alone, else program_refclk()'s result. If the
    status cannot be read, the FPGA's refclk meter decides."""
    pr("[b] 8A34001: checking status (programmed only if unconfigured)")
    try:
        if read_status is None:
            read_status = _gt_refclk().read_status
        st = read_status(allow_page_select=True)
        ok = refclk_configured(st)
        q = {k: st[k].get("freq_mhz") if isinstance(st.get(k), dict) else st.get(k)
             for k in ("Q7", "Q11")}
        status = st.get("status") if isinstance(st.get("status"), dict) else {}
        pr(f"    APLL locked {status.get('sys_apll_locked')}, Q7 {q['Q7']} MHz, "
           f"Q11 {q['Q11']} MHz -> "
           f"{'configured; not touched' if ok else 'UNCONFIGURED'}")
    except Exception as e:  # noqa: BLE001 - fall back to the clock meter
        ref = eth.refclk_khz()
        ok = abs(ref - E.REFCLK_KHZ) <= E.REFCLK_TOL_KHZ
        pr(f"    status unreadable ({type(e).__name__}: {e}); FPGA meter says "
           f"refclk {ref} kHz -> {'present; not touched' if ok else 'absent'}")
    if ok:
        return None
    return program_refclk(pr)


def cmac_bringup(eth: "E.Eth100G", rsfec: bool = True, rxpol: int = 0,
                 txpol: int = 0, dfe: bool = False, loopback: bool = False,
                 timeout: float = 5.0, pr: Printer = print) -> bool:
    ctl = E.build_ctl(rsfec=rsfec, rxpol=rxpol, txpol=txpol,
                      lpm_mask=0 if dfe else 0xF, loopback=loopback)
    pr(f"[d] CMAC ctl was 0x{eth.cmac_ctl():08x}; pulsing GT sys_reset with "
       f"ctl 0x{ctl:08x} {dict(E.decode_ctl(ctl))}")
    eth.cmac_reset_pulse(ctl)
    ok = eth.cmac_wait_aligned(
        timeout_s=timeout, poll_s=0.5,
        report=lambda t, st: pr(f"    t={t:4.1f}s {E.format_cmac_status(st)}"))
    st = eth.cmac_status()
    pr(f"    rx aligned: {'YES' if ok else 'NO'} after <= {timeout:.1f}s; "
       f"final {E.format_cmac_status(st)}")
    if not ok:
        d = E.decode_cmac_status(st)
        hints = []
        if d["gt_powergood"] != "1111":
            hints.append("GT power-good missing")
        if d["rx_reset_done"] != "1111" or d["tx_reset_done"] != "1111":
            hints.append("GT reset not done (refclk? QPLL lock?)")
        if rsfec and d["rsfec_am_lock"] != "1111":
            hints.append("RS-FEC AM lock missing (NIC FEC off? polarity? cable?)")
        if d["rx_local_fault"]:
            hints.append("rx local fault (no signal / no block lock)")
        if d["rx_remote_fault"]:
            hints.append("remote fault (the NIC does not see us: our TX / its FEC)")
        pr("    hints: " + ("; ".join(hints) or "none"))
    return ok


def link_bringup(eth: "E.Eth100G", refclk=True, rsfec: bool = True,
                 rxpol: int = 0, txpol: int = 0, dfe: bool = False,
                 loopback: bool = False, timeout: float = 5.0,
                 pr: Printer = print) -> Dict[str, object]:
    """Steps b-d. Never raises for a link problem: the result says what failed.

    refclk: True = program the 8A34001; "auto" = only if its status says it
    is unconfigured (bitstream reloads); False = leave it alone."""
    res: Dict[str, object] = {}
    if refclk == "auto":
        res["refclk_programmed"] = ensure_refclk(eth, pr)
    elif refclk:
        res["refclk_programmed"] = program_refclk(pr)
    else:
        res["refclk_programmed"] = None
        pr("[b] 8A34001 programming skipped (--no-refclk)")
    res.update(check_clocks(eth, pr))
    res["aligned"] = cmac_bringup(eth, rsfec, rxpol, txpol, dfe, loopback,
                                  timeout, pr)
    if res["aligned"]:
        res.update({k: v for k, v in check_clocks(eth, lambda s: None).items()})
        pr(f"    user clock now {res['usrclk_khz']} kHz")
    return res


def print_status(eth: "E.Eth100G", pr: Printer = print) -> None:
    ctl, st = eth.cmac_ctl(), eth.cmac_status()
    pr(f"cmac ctl    0x{ctl:08x} {dict(E.decode_ctl(ctl))}")
    pr(f"cmac status {E.format_cmac_status(st)}")
    check_clocks(eth, pr)
    pr("udp_streamer " + json.dumps(eth.streamer_stats()))
    pr("udp_player   " + json.dumps(eth.player_stats()))


def loaded_bitstream() -> str:
    try:
        from pynq import PL
        return str(PL.bitfile_name or "")
    except Exception as e:  # noqa: BLE001
        return f"<unknown: {e}>"


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--status", action="store_true", help="read & decode only")
    ap.add_argument("--link-only", action="store_true",
                    help="bitstream already loaded: skip overlay + RFDC")
    ap.add_argument("--force", action="store_true",
                    help="skip the loaded-bitstream check (--status/--link-only)")
    ap.add_argument("--bitstream", default=os.path.join(HERE, BITSTREAM_NAME + ".bit"))
    ap.add_argument("--no-load", action="store_true",
                    help="attach to the loaded bitstream (still runs RFDC bring-up)")
    ap.add_argument("--allow-unlocked", action="store_true")
    ap.add_argument("--lib-root", default=None)
    ap.add_argument("--config", default=None,
                    help="settings file with data_ip/data_mac [see board_config.py]")
    ap.add_argument("--data-ip", default=None, help="FPGA 100G data IP [config data_ip]")
    ap.add_argument("--data-mac", default=None,
                    help="FPGA 100G MAC [config data_mac, else derived from the eth0 MAC]")
    add_link_args(ap)
    s = ap.add_argument_group("optional counter-pattern stream (step f)")
    s.add_argument("--stream-host-ip", default=None)
    s.add_argument("--stream-host-mac", default=None)
    s.add_argument("--stream-port", type=int, default=49810)
    s.add_argument("--nports", type=int, default=1)
    s.add_argument("--spp", type=int, default=2048)
    s.add_argument("--seconds", type=float, default=10.0)
    args = ap.parse_args(argv)
    pr = lambda m: print(m, flush=True)  # noqa: E731
    if not args.status:
        import board_config
        try:
            args.data_ip, args.data_mac, _name, how = board_config.resolve(
                args.data_ip, args.data_mac, None, config=args.config)
        except board_config.ConfigError as e:
            pr(f"error: {e}")
            return 2
        pr(f"FPGA data address {args.data_ip} / {args.data_mac} ({how})")

    if args.status or args.link_only:
        bit = loaded_bitstream()
        pr(f"loaded bitstream (PYNQ): {bit or '<none>'}")
        if not re.search(r"zcu216_v49_[0-9]+ch_qsfp", bit or "") and not args.force:
            pr(f"refusing: no zcu216_v49_<N>ch_qsfp build is loaded (--force to override; "
               f"an unmapped AXI read can hang the board)")
            return 2
        eth = E.Eth100G(None)          # fallback addresses; constructor only reads
        if args.status:
            print_status(eth, pr)
            try:
                pr("8A34001      " + json.dumps(_gt_refclk().read_status(), default=str))
            except Exception as e:  # noqa: BLE001
                pr(f"8A34001      unavailable: {e!r}")
            return 0
        res = link_bringup(eth, pr=pr, **link_opts(args))
        pr(f"[e] MAC/IP {args.data_mac} {args.data_ip} -> streamer + player")
        eth.set_addresses(args.data_mac, args.data_ip)
        eth.player_enable()
        be = None
    else:
        from hw_backend import HwBackend
        be = HwBackend(bitstream=os.path.abspath(args.bitstream),
                       data_ip=args.data_ip, data_mac=args.data_mac,
                       lib_root=args.lib_root, load=not args.no_load,
                       allow_unlocked=args.allow_unlocked,
                       printer=pr, **link_opts(args))
        eth, res = be.eth, be.link

    print_status(eth, pr)
    rc = 0 if res.get("aligned") else 1

    if args.stream_host_ip:
        if not args.stream_host_mac:
            pr("--stream-host-mac is required (the FPGA does not ARP for the host)")
            return 2
        spp = eth.configure(args.data_mac, args.data_ip, args.stream_host_mac,
                            args.stream_host_ip, vrt.FPGA_SRC_PORT, args.stream_port,
                            args.nports, vrt.round_spp(args.spp), vrt.sid_for(0),
                            pattern=True)
        pr(f"[f] streaming counter pattern -> {args.stream_host_ip}:{args.stream_port}"
           f" x{args.nports}, spp {spp}, {args.seconds:.0f} s")
        eth.stream_cmd("start_cont", 0, True, 0)
        t_end = time.monotonic() + args.seconds
        last = eth.streamer_stats()["pkts"]
        while time.monotonic() < t_end:
            time.sleep(1.0)
            s_ = eth.streamer_stats()
            pr(f"    pkts {s_['pkts']} (+{s_['pkts'] - last}/s = "
               f"{(s_['pkts'] - last) * spp / 1e6:.1f} MS/s) overflows {s_['overflows']} "
               f"fifo_hwm {s_['fifo_hwm']} streaming {s_['streaming']} "
               f"aligned {int(eth.cmac_aligned())}")
            last = s_["pkts"]
        eth.stream_cmd("stop_cont", 0, True, 0)
        eth.wait_idle(0.2)
        print_status(eth, pr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
