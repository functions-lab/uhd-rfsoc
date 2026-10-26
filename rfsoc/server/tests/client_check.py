#!/usr/bin/env python3
"""End-to-end client check of a running uhd-rfsoc daemon (run on the HOST).

Discovery (unicast + broadcast), claim, info, set/get, RX stream_setup with
pattern=1, stream_cmd num_done N now, bit-exact verification of every received
packet (§4-5: header, SID, TSF continuity, counter pattern, SOB/EOB), and
optionally a TX burst (§6-7: FC updates + burst ACK).

`--rate R` streams at the variant nearest R (the daemon may reload the FPGA:
seconds on hardware); TSF continuity and the pattern are then checked with
tps = tick_rate / rate ticks per sample (§4, §8).

`--channels N` first sends `set_channels N` (another build: a reload) and then
checks the §9 stream: slots interleaved sample-major, tick = one slot time,
slot i of a packet carrying I = TSF + i*tps (channel order, timing and loss in
one check), `num_done` asked in slots (num x N), per-channel commands on every
channel.

    python3 client_check.py --addr <board-ip> [--host-ip <this host's LAN ip>] [--rate 6e8]

`--otw FMT` (§10) streams RX and TX in that over-the-wire format (declared
on set_rx_rate, so a rate that needs otw=sc8 can be reached) and checks every
payload against the pattern passed through vrt.sc16_to_wire. `--bf` exercises
the §11 TX and RX beamformer commands (N >= 2 builds; RX where info rbf=1)
against rfsoc_lib's Beamformer.
The tick rate is re-read from the set_rx_rate reply: it belongs to the build.

--host-ip defaults to the local address the kernel routes towards --addr.
"""
from __future__ import annotations

import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import vrt  # noqa: E402

FAILS = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        FAILS.append(what)
    return cond


def discover(target, port, timeout=1.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(timeout)
    s.sendto(b"UHD-RFSOC-DISC?", (target, port))
    out = []
    t_end = time.monotonic() + timeout
    while time.monotonic() < t_end:
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            break
        out.append((addr, data.decode().strip()))
    s.close()
    return out


class Ctl:
    def __init__(self, addr, port):
        # a rate change may reload the FPGA and redo the bring-up (§8)
        self.s = socket.create_connection((addr, port), timeout=120)
        self.f = self.s.makefile("rwb")

    def __call__(self, line):
        self.f.write(line.encode() + b"\n")
        self.f.flush()
        r = self.f.readline().decode().rstrip("\n")
        print(f"  > {line}\n  < {r}")
        return r

    def close(self):
        self.f.close()
        self.s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", required=True, help="the daemon's address (board LAN IP)")
    ap.add_argument("--bcast", default="255.255.255.255",
                    help="broadcast address for the discovery check [limited broadcast]")
    ap.add_argument("--port", type=int, default=49710)
    ap.add_argument("--disc-port", type=int, default=49700)
    ap.add_argument("--host-ip", default=None,
                    help="where the daemon sends samples [the local address routed to --addr]")
    ap.add_argument("--host-mac", default="aa:bb:cc:dd:ee:ff")
    ap.add_argument("--rx-port", type=int, default=49810)
    ap.add_argument("--nports", type=int, default=1)
    ap.add_argument("--spp", type=int, default=2048)
    ap.add_argument("--num", type=int, default=100000)
    ap.add_argument("--tx", action="store_true", help="also test a TX burst")
    ap.add_argument("--async-port", type=int, default=49826)
    ap.add_argument("--rate", type=float, default=None,
                    help="sample rate to test at [the highest]; may reload the FPGA")
    ap.add_argument("--channels", type=int, default=None,
                    help="set_channels N first (may reload the FPGA) [keep loaded]")
    ap.add_argument("--no-bcast", action="store_true",
                    help="skip the broadcast discovery check")
    ap.add_argument("--tx-port", type=int, default=vrt.TX_PORT,
                    help="FPGA UDP port for TX samples")
    ap.add_argument("--src-port", type=int, default=vrt.FPGA_SRC_PORT,
                    help="expected UDP source port of RX packets [%(default)s]")
    ap.add_argument("--otw", default="sc16", choices=vrt.OTW_FORMATS,
                    help="over-the-wire format, Protocol §10 [%(default)s]")
    ap.add_argument("--bf", action="store_true",
                    help="exercise the TX beamformer commands (N >= 2)")
    a = ap.parse_args()
    if a.host_ip is None:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.connect((a.addr, 9))            # picks the route; sends nothing
        a.host_ip = u.getsockname()[0]
        u.close()

    print("[discovery unicast]")
    r = discover(a.addr, a.disc_port)
    check(len(r) == 1 and r[0][1].startswith("UHD-RFSOC-DISC type=rfsoc;"),
          f"unicast reply {r}")
    if r:
        kv = dict(x.split("=", 1) for x in r[0][1].split(" ", 1)[1].split(";"))
        check(kv.get("addr") == a.addr, f"addr={kv.get('addr')}")
        check(kv.get("version") == "1", "version=1")
    if not a.no_bcast:
        print("[discovery broadcast]")
        r = discover(a.bcast, a.disc_port, timeout=1.5)
        check(any(addr[0] == a.addr for addr, _ in r), f"broadcast replies {r}")

    c = Ctl(a.addr, a.port)
    try:
        print("[control]")
        check(c("ping") == "OK pong", "ping")
        info = c("info")
        check(info.startswith("OK ") and "tick_rate=" in info, "info")
        kv = dict(x.split("=", 1) for x in info[3:].split(";"))
        tick = float(kv["tick_rate"])
        check(c("claim") == "OK", "claim")
        c2 = Ctl(a.addr, a.port)
        check(c2("claim") == "ERR claimed", "second claim refused")
        c2.close()
        if a.channels is not None:
            print(f"[channels {a.channels}]")
            t_c = time.monotonic()
            r = c(f"set_channels {a.channels}")
            check(r.startswith(f"OK {a.channels} "),
                  f"set_channels {a.channels} ({time.monotonic() - t_c:.1f} s)")
            info = c("info")
            kv = dict(x.split("=", 1) for x in info[3:].split(";"))
            tick = float(kv["tick_rate"])
            check(r == "OK %d %.17g" % (a.channels, tick), "set_channels reply == info tick_rate")
        nch = int(kv["num_rx"])
        check(kv["num_tx"] == kv["num_rx"], f"num_rx == num_tx == {nch}")
        rates = [float(x) for x in kv["rx_rates"].split(",")]
        ticks = [float(x) for x in kv["tick_rates"].split(",")]
        # tick rate per build: aggregate slot rate x TICK_STEP (1 on every
        # build, Protocol §8): N x the per-channel rate
        want_ticks = [nch * r for r in rates]
        check(rates == sorted(rates, reverse=True) and ticks == want_ticks
              and tick in ticks, f"rates {rates} descending, tick_rates {ticks} == "
              f"{want_ticks}, tick_rate {tick:.17g}")
        check(c("get_rx_rates 0") == "OK " + " ".join("%.17g" % r for r in rates),
              "get_rx_rates == info rx_rates")
        rate_otw = dict(x.split(":") for x in kv["rate_otw"].split(","))
        fits = [r for r in rates if a.otw in rate_otw["%.17g" % r].split("+")]
        if not fits:
            # no build of this N carries the format: it must be refused
            # (set_rx_rate vets only the link capacity of a declared otw; the
            # RX-only limit -- fc32 on a 512-bit beat -- is stream_setup's)
            r = c("set_rx_rate 0 %.17g otw=%s" % (rates[-1], a.otw))
            print(f"  set_rx_rate {rates[-1]:.17g} otw={a.otw}: {r}")
            r = c(f"stream_setup 0 {a.host_ip} {a.host_mac} {a.rx_port} 1 {a.spp} otw={a.otw}")
            check(r.startswith("ERR"), f"stream_setup otw={a.otw} refused")
            check(c("unclaim") == "OK", "unclaim")
            print(f"  otw={a.otw}: no {nch}-channel build can carry it (rate_otw "
                  f"{kv['rate_otw']}); refused as expected")
            print("RESULT:", "PASS" if not FAILS else f"FAIL ({len(FAILS)}): {FAILS}")
            return 0 if not FAILS else 1
        want_rate = (fits or rates)[0] if a.rate is None else min(
            rates, key=lambda r: (abs(r - a.rate), -r))
        req = want_rate if a.rate is None else a.rate
        if a.otw not in rate_otw["%.17g" % want_rate].split("+"):
            # that build cannot carry the format: refused before any reload,
            # then test at the fastest rate that can
            r = c("set_rx_rate 0 %.17g otw=%s" % (req, a.otw))
            check(r.startswith("ERR") and "refused" in r and "needs otw=" in r,
                  f"{want_rate / 1e6:g} MS/s refused for otw={a.otw}")
            want_rate = req = fits[0]
        t_r = time.monotonic()
        r = c("set_rx_rate 0 %.17g otw=%s" % (req, a.otw))
        tick = ticks[rates.index(want_rate)]
        check(r == "OK %.17g %.17g" % (want_rate, tick),
              f"rate coerced to {want_rate:.17g}, tick_rate {tick:.17g} "
              f"({time.monotonic() - t_r:.1f} s): {r}")
        info = c("info")
        kv = dict(x.split("=", 1) for x in info[3:].split(";"))
        check(float(kv["tick_rate"]) == tick, "info tick_rate == set_rx_rate reply")
        check(c("get_tx_rate 0") == "OK %.17g" % want_rate, "TX rate follows RX (one factor)")
        rate = want_rate
        tps = int(round(tick / (nch * rate)))      # ticks per SLOT (§4, §9)
        check(tps == int(kv["tick_step"]), f"tick_step {kv['tick_step']} == {tps}")
        beat = int(kv["beat_slots"])
        print(f"  streaming {nch} channel(s) at {rate / 1e6:g} MS/s each, otw={a.otw}: "
              f"{tps} tick(s) per slot, {beat}-slot beat, otw_formats {kv['otw_formats']}")
        for ch in range(nch):
            f_rx, f_tx = 1e9 + ch * 1e6, 7e8 + ch * 1e6
            r = c("set_rx_freq %d %.17g" % (ch, f_rx))
            check(r.startswith("OK ") and abs(float(r[3:]) - f_rx) < 1, f"set_rx_freq ch{ch}")
            check(c(f"get_rx_freq {ch}") == r, f"get_rx_freq ch{ch}")
            check(c(f"set_rx_gain {ch} -{10 + ch % 8}").startswith("OK "), f"set_rx_gain ch{ch}")
            check(c(f"get_rx_gain_range {ch}").startswith("OK "), f"gain range ch{ch}")
            r = c("set_tx_freq %d %.17g" % (ch, f_tx))
            check(r.startswith("OK "), f"set_tx_freq ch{ch}")
        check(c(f"get_rx_freq {nch}").startswith("ERR"), f"channel {nch} refused")
        check(c("get_sensor cmac_aligned").startswith("OK bool "), "sensor")
        check(c("get_sensor temp").startswith("OK real "), "temp")
        check(c("list_sensors").startswith("OK "), "list_sensors")
        check(c("bogus_cmd").startswith("ERR"), "unknown -> ERR")
        check(c("set_time 0") == "OK", "set_time")
        t = int(c("get_time")[3:])
        check(0 <= t < tick * 60, f"get_time {t}")

        print("[rx stream]")
        socks = []
        for k in range(a.nports):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
            s.bind(("0.0.0.0", a.rx_port + k))
            s.settimeout(0.05)
            socks.append(s)
        gran = vrt.otw_granule(a.otw, nch)
        sb = vrt.OTW_SLOT_BYTES[a.otw]
        r = c(f"stream_setup 0 {a.host_ip} {a.host_mac} {a.rx_port} "
              f"{a.nports} {a.spp} pattern=1 otw={a.otw}")
        spp = int(r.split()[1]) if r.startswith("OK ") else a.spp
        check(r == f"OK {vrt.round_spp(a.spp, gran, vrt.otw_max_spp(a.otw))} {a.nports}",
              f"stream_setup otw={a.otw}: {r}")
        t0 = time.monotonic()
        # num_samps in SLOTS: the host asks for num samples of every channel
        check(c(f"stream_cmd 0 num_done {a.num * nch} 1 0") == "OK", "stream_cmd")
        pkts = []
        eob = False
        t_end = time.monotonic() + 10 + a.num / 1e6
        while not eob and time.monotonic() < t_end:
            for s in socks:
                try:
                    data, src = s.recvfrom(65536)
                except socket.timeout:
                    continue
                h = vrt.unpack_header(data)
                pkts.append((h, data[vrt.HDR_BYTES:], src))
                eob = eob or h["eob"]
        dt = time.monotonic() - t0
        for s in socks:
            s.close()
        pkts.sort(key=lambda p: p[0]["tsf"])
        total = sum(4 * (p[0]["len_words"] - 4) // sb for p in pkts)
        want = vrt.ceil_granule(a.num * nch, gran)
        print(f"  received {len(pkts)} packets, {total} slots in {dt:.2f}s "
              f"({total / dt / 1e6:.2f} Mslot/s)")
        check(total == want, f"slot count {total} == {want} ({a.num} x {nch} ch)")
        check(bool(pkts) and pkts[0][0]["sob"], "SOB on first")
        check(bool(pkts) and pkts[-1][0]["eob"]
              and all(not p[0]["eob"] for p in pkts[:-1]), "EOB only on last")
        bad_tsf = bad_pat = bad_hdr = 0
        prev_ns = 0
        for i, (h, pl, src) in enumerate(pkts):
            nb = 4 * (h["len_words"] - 4)
            ns = nb // sb
            if (h["pkt_type"] != 0 or not h["has_sid"] or h["sid"] != 0x5A160000
                    or h["tsf_type"] != 1 or len(pl) != nb or nb % 64 or ns % gran
                    or (i < len(pkts) - 1 and ns != spp) or src[1] != a.src_port):
                bad_hdr += 1
            if i and h["tsf"] != pkts[i - 1][0]["tsf"] + prev_ns * tps:
                bad_tsf += 1
            if i == 0 and h["tsf"] % (beat * tps):
                bad_tsf += 1                        # starts on a fabric beat
            # the FPGA converts the sc16 pattern (§10): compare on the wire
            exp = vrt.sc16_to_wire(vrt.pattern_payload(h["tsf"], ns, tps), a.otw)
            if pl != exp:
                bad_pat += sum(pl[k:k + 64] != exp[k:k + 64] for k in range(0, nb, 64))
            prev_ns = ns
            if i and h["count"] != (pkts[i - 1][0]["count"] + 1) & 0xF:
                bad_hdr += 1
        check(bad_hdr == 0, f"headers/SID/len/count/src-port ok ({bad_hdr} bad)")
        check(bad_tsf == 0, f"TSF continuity ({bad_tsf} gaps)")
        check(bad_pat == 0, f"pattern bit-exact in {a.otw}, slot i = TSF + i*tps "
                            f"({bad_pat} bad 64-byte words)")
        if pkts:
            print(f"  first TSF {pkts[0][0]['tsf']}, last TSF {pkts[-1][0]['tsf']}")
        c("stats")

        if a.tx:
            print("[tx burst]")
            asock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            asock.bind(("0.0.0.0", a.async_port))
            asock.settimeout(0.2)
            r = c(f"stream_setup_tx 0 {a.host_ip} {a.host_mac} {a.async_port} otw={a.otw}")
            check(r.startswith("OK "), f"stream_setup_tx otw={a.otw}: {r}")
            toks = r.split()
            buf, fc = int(toks[1]), int(toks[2])
            base = int(toks[3]) if len(toks) > 3 else 0     # free-running consumed
            out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            npk, ns = 64, 1024              # 1024 slots: whole words in every format
            pw = ns * sb // 64              # 64-byte words per packet
            words = npk * pw
            consumed, sent_words, k = base, base, 0
            events = []
            t_end = time.monotonic() + 30
            while (k < npk or not any(e["event"] == 1 for e in events)) \
                    and time.monotonic() < t_end:
                while k < npk and sent_words + pw - consumed <= buf:
                    pay = vrt.sc16_to_wire(vrt.pattern_payload(k * ns, ns), a.otw)
                    hdr = vrt.pack_header(0, 0, ns, k, sob=(k == 0),
                                          eob=(k == npk - 1),
                                          sid=vrt.tx_sid_for(0), has_time=False,
                                          payload_words=len(pay) // 4)
                    out.sendto(hdr + pay, (kv["data_ip"], a.tx_port))
                    sent_words += pw
                    k += 1
                try:
                    e = vrt.unpack_async(asock.recv(64))
                    events.append(e)
                    consumed = max(consumed, e["consumed"])
                except socket.timeout:
                    pass
            codes = [e["event"] for e in events]
            got = events[-1]["consumed"] - base if events else None
            check(codes.count(1) == 1 and got == words,
                  f"burst ACK, consumed {got} == {words} (baseline {base})")
            check(codes.count(0) >= words // fc - 1, f"{codes.count(0)} FC updates (fc_interval {fc})")
            check(not any(x in codes for x in (2, 4, 8, 0x10, 0x20)), f"no error events {set(codes)}")
            check(c("stream_stop_tx 0") == "OK", "stream_stop_tx")
            c("stats")
            asock.close()
            out.close()
        if a.bf:
            print("[tx beamformer]")
            if kv.get("bf") != "1":
                check(c("get_bf").startswith("ERR"), f"get_bf refused on N={nch}")
            else:
                from backend import steering_weights
                st = dict(x.split("=", 1) for x in c("get_bf")[3:].split(";"))
                check(st["enable"] == "0" and st["weights"] == ",".join(["32767,0"] * nch),
                      f"bypass + unity at claim: {st}")
                for ang in (-45.0, 0.0, 17.5):
                    w = steering_weights(nch, ang, float(st["carrier_freq"]),
                                         float(st["element_spacing"]))
                    r = c("set_bf_angle %.17g" % ang)
                    check(r == "OK " + ",".join(f"{x},{y}" for x, y in w),
                          f"set_bf_angle {ang} == rfsoc_lib Beamformer")
                check(c("set_bf_enable 1") == "OK 1", "set_bf_enable 1")
                check(c("set_bf_params 28e9 0.0053") == "OK", "set_bf_params")
                w = steering_weights(nch, 17.5, 28e9, 0.0053)
                st = dict(x.split("=", 1) for x in c("get_bf")[3:].split(";"))
                check(st["weights"] == ",".join(f"{x},{y}" for x, y in w)
                      and st["angle_deg"] == "17.5", "params re-steer the beam")
                raw = " ".join(f"{1000 * c_} {-c_}" for c_ in range(nch))
                check(c("set_bf_weights " + raw) == "OK", "set_bf_weights")
                check(c("set_bf_weights 1 2").startswith("ERR"), "short weight list refused")
                check(c("set_bf_enable 0") == "OK 0", "set_bf_enable 0")
            print("[rx beamformer]")
            if kv.get("rbf") != "1":
                check(c("get_rbf").startswith("ERR"), f"get_rbf refused (rbf={kv.get('rbf')})")
            else:
                from backend import steering_weights
                st = dict(x.split("=", 1) for x in c("get_rbf")[3:].split(";"))
                log2n = nch.bit_length() - 1
                check(st["enable"] == "0" and st["weights"] == ",".join(["32767,0"] * nch)
                      and st["shift"] == str(log2n), f"bypass + unity + shift log2(N) at claim: {st}")
                for ang in (-30.0, 0.0, 22.5):
                    w = steering_weights(nch, ang, float(st["carrier_freq"]),
                                         float(st["element_spacing"]))
                    r = c("set_rbf_angle %.17g" % ang)
                    check(r == "OK " + ",".join(f"{x},{y}" for x, y in w),
                          f"set_rbf_angle {ang} == rfsoc_lib Beamformer (the TX rule)")
                check(c("set_rbf_enable 1") == "OK 1", "set_rbf_enable 1")
                check(c("set_rbf_shift 0") == "OK 0", "set_rbf_shift 0")
                check(c("set_rbf_shift 16").startswith("ERR"), "shift 16 refused")
                check(c("set_rbf_params 28e9 0.0053") == "OK", "set_rbf_params")
                w = steering_weights(nch, 22.5, 28e9, 0.0053)
                st = dict(x.split("=", 1) for x in c("get_rbf")[3:].split(";"))
                check(st["weights"] == ",".join(f"{x},{y}" for x, y in w)
                      and st["angle_deg"] == "22.5" and st["shift"] == "0",
                      "params re-steer the RX beam, shift kept")
                tx = dict(x.split("=", 1) for x in c("get_bf")[3:].split(";"))
                check(tx["enable"] == "0" and "shift" not in tx, "the TX beamformer is separate")
                raw = " ".join(f"{-1000 * c_} {c_}" for c_ in range(nch))
                check(c("set_rbf_weights " + raw) == "OK", "set_rbf_weights")
                check(c("set_rbf_enable 0") == "OK 0", "set_rbf_enable 0")
        check(c("unclaim") == "OK", "unclaim")
    finally:
        c.close()
    print("RESULT:", "PASS" if not FAILS else f"FAIL ({len(FAILS)}): {FAILS}")
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
