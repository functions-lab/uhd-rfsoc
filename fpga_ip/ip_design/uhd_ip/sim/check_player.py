#!/usr/bin/env python3
"""Check player.log from tb_udp_player against Protocol §6/7.

  D <tick> <hex>     non-zero DAC beats: every burst must come out bit-exact,
                     back-to-back, a timed one on the beat containing its TSF.
  C <hex>            frames from udp_player: ARP replies (byte-exact) and
                     status packets (Ethernet/IPv4 with checksum/UDP, the six
                     little-endian words of section 7).
  S <hex>            (--integ) udp_streamer frames that went through
                     axis_pkt_arb: every one intact, none lost or duplicated.

Status events are tied to the DAC trace: BURST_ACK carries the tick of the
burst's last beat, TIME_ERROR the tick it actually started, UNDERFLOW the tick
of the first zero beat. Flow control: consumed is monotonic, never advances by
more than FC_INTERVAL (+ slack) between status packets, and the last status
before each quiesce point reports every word the host sent.

  check_player.py [--integ] [--tick-step N] [--width W] [--fmt F] player.log

--fmt F (0 sc16, 1 sc8, 2 sc12, 3 fc32; Protocol §10): the testbench sent
wire-format packets. Every "W <burst> <slot> <hex>" payload it logged must
equal the reference packer's bytes for the wire model (otw_ref: UHD's sc12
pack, numpy float32), and the DAC must play otw_ref's conversion of them
(sc8 x256, sc12 by UHD's unpack, fc32 round-half-even x32768 saturated, NaN 0).
An fc32 burst ending on half a 16-slot group plays 8 zero slots more; its
BURST_ACK is stamped at the end of that padded group.

Ticks: slot k of a beat at tick T has timestamp T + k*N (N = TICK_STEP,
default 1); a W-bit DAC beat (W = M_WIDTH, default 128) is W/32 slots, so
consecutive beats are (W/32)*N ticks apart.
"""
import argparse
import struct
import sys

import numpy as np

from otw_ref import (BYTES_PER_SLOT, FMT_NAMES, rx_payload, s16, sc12_bytes,
                     tx_payload_to_sc16)

MY_MAC = bytes.fromhex("021122334455")
HOST_MAC = bytes.fromhex("1a2b3c4d5e6f")
MY_IP, HOST_IP = bytes([192, 168, 5, 2]), bytes([192, 168, 5, 1])
SRC_PORT, ASYNC_PORT, SID = 49801, 49826, 0x5A170003
MAGIC = 0x5A17A5C0
FC_SLACK = 32

errors = []


def err(msg):
    errors.append(msg)
    print("ERROR", msg)


def ip_ok(hdr):
    s = sum(struct.unpack("!10H", hdr))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s == 0xFFFF


FMT = 0
FCORN = [0x7FC00000, 0xFFC00001, 0x7F800000, 0xFF800000,
         0x3F800000, 0xBF800000, 0x40000000, 0xC0600000,
         0x7149F2CA, 0x8C0A0B0C, 0x3F7FFFFF, 0xBF800001,
         0x38000000, 0x37800000, 0x37C00000, 0x38400000,
         0x38200000, 0x38A00000, 0xB7800000, 0xB8400000,
         0x80000000, 0x00000001, 0x3F7FFF00, 0xBF7FFF00]
FR = [0, 2, -2, 1, 3, -1, 6, -6]


def fbits(m):
    """float32 bits of m / 2^17 (exact), as the testbench builds them."""
    return int(np.array([np.float32(m / 2.0 ** 17)]).view(np.uint32)[0])


def w_i(b, n):
    if FMT == 1:
        return ((n * 7 + b * 16) | 1) & 0xFF
    if FMT == 2:
        return ((n * 7 + b * 64) | 1) & 0xFFF
    if n % 64 < 24:
        return FCORN[n % 64]
    return fbits(4 * s16((n * 7 + b * 4096) | 1) + FR[n % 8])


def w_q(b, n):
    if FMT == 1:
        return (n ^ (b << 3) ^ 0xA5) & 0xFF
    if FMT == 2:
        return (n ^ (b << 5) ^ 0xA5A) & 0xFFF
    return fbits(4 * s16((n ^ (b << 8) ^ 0xA5A5) | 1))


def wire_bytes(b, n0, ns):
    """Payload bytes of slots n0 .. n0+ns-1 of burst b in format FMT."""
    if FMT == 1:
        return bytes(v for n in range(n0, n0 + ns) for v in (w_i(b, n), w_q(b, n)))
    if FMT == 2:
        return sc12_bytes([(w_i(b, n), w_q(b, n)) for n in range(n0, n0 + ns)])
    return b"".join(struct.pack("<II", w_i(b, n), w_q(b, n)) for n in range(n0, n0 + ns))


_samp_cache = {}


def samp(b, n):
    if FMT == 0:
        i = ((n * 7 + b * 4096) | 1) & 0xFFFF
        q = (n ^ (b << 8) ^ 0xA5A5) & 0xFFFF
        return (q << 16) | i
    blk = n - n % 4
    if (b, blk) not in _samp_cache:
        _samp_cache[(b, blk)] = tx_payload_to_sc16(wire_bytes(b, blk, 4), FMT)
    i, q = _samp_cache[(b, blk)][n % 4]
    return ((q & 0xFFFF) << 16) | (i & 0xFFFF)


def arp_reply(tha, tpa):
    f = tha + MY_MAC + b"\x08\x06" + b"\x00\x01\x08\x00\x06\x04\x00\x02"
    f += MY_MAC + MY_IP + tha + tpa
    return f + bytes(60 - len(f))


class Status:
    last_id = None

    def __init__(self, f, where):
        self.ok = False
        if len(f) != 66:
            return err(f"{where}: status length {len(f)}")
        if f[0:6] != HOST_MAC or f[6:12] != MY_MAC or f[12:14] != b"\x08\x00":
            return err(f"{where}: Ethernet header {f[:14].hex()}")
        ip = f[14:34]
        if not ip_ok(ip):
            return err(f"{where}: IPv4 checksum")
        ver, tos, tlen, ident, frag, ttl, proto = struct.unpack("!BBHHHBB", ip[:10])
        if (ver, tos, tlen, frag, ttl, proto) != (0x45, 0, 52, 0x4000, 64, 17):
            return err(f"{where}: IPv4 fields {ip.hex()}")
        if ip[12:16] != MY_IP or ip[16:20] != HOST_IP:
            return err(f"{where}: IPv4 addresses")
        if Status.last_id is not None and ident != (Status.last_id + 1) & 0xFFFF:
            err(f"{where}: IP id {ident} after {Status.last_id}")
        Status.last_id = ident
        sport, dport, ulen, ucs = struct.unpack("!4H", f[34:42])
        if (sport, dport, ulen, ucs) != (SRC_PORT, ASYNC_PORT, 32, 0):
            return err(f"{where}: UDP {sport} {dport} {ulen} {ucs}")
        magic, sid, thi, tlo, code, cons = struct.unpack("<6I", f[42:66])
        if magic != MAGIC or sid != SID:
            return err(f"{where}: magic/SID {magic:#x} {sid:#x}")
        if code not in (0, 1, 2, 4, 8):
            return err(f"{where}: event code {code:#x}")
        self.tsf, self.code, self.cons = (thi << 32) | tlo, code, cons
        self.ok = True


def check_streamer_frame(f, where, state, ts=1, sfmt=0):
    """udp_streamer frame, test pattern on: sample t = (t & 0xFFFF, ~t),
    converted to the streamer's format sfmt."""
    if f[12:14] != b"\x08\x00" or not ip_ok(f[14:34]):
        return err(f"{where}: streamer IPv4")
    ip_len = struct.unpack("!H", f[16:18])[0]
    if ip_len != len(f) - 14:
        return err(f"{where}: streamer ip_len {ip_len} vs {len(f) - 14}")
    sport, dport, ulen, ucs = struct.unpack("!4H", f[34:42])
    if ulen != ip_len - 20 or ucs != 0 or not (49810 <= dport < 49813):
        return err(f"{where}: streamer UDP")
    w0, sid, thi, tlo = struct.unpack("<4I", f[42:58])
    cnt = (w0 >> 16) & 0xF
    if state.get("cnt") is not None and cnt != (state["cnt"] + 1) & 0xF:
        err(f"{where}: streamer packet count {cnt} after {state['cnt']} (lost/duplicated frame)")
    state["cnt"] = cnt
    if state.get("port") is not None and dport != 49810 + (state["port"] - 49810 + 1) % 3:
        err(f"{where}: streamer port order {dport} after {state['port']}")
    state["port"] = dport
    tsf = (thi << 32) | tlo
    pay = f[58:]
    if len(pay) != 4 * ((w0 & 0xFFFF) - 4) or len(pay) % BYTES_PER_SLOT[sfmt]:
        return err(f"{where}: streamer payload length")
    n = len(pay) // BYTES_PER_SLOT[sfmt]
    want = rx_payload([(s16(tsf + k * ts), s16(~(tsf + k * ts))) for k in range(n)], sfmt)
    if pay != want:
        return err(f"{where}: streamer payload ({FMT_NAMES[sfmt]})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--integ", action="store_true")
    ap.add_argument("--tick-step", type=int, default=1)
    ap.add_argument("--width", type=int, default=128, choices=(128, 256, 512, 1024))
    ap.add_argument("--fmt", type=int, default=0, choices=(0, 1, 2, 3))
    a = ap.parse_args()
    integ, path, ts, width = a.integ, a.path, a.tick_step, a.width
    global FMT
    FMT = a.fmt
    sfmt = 0
    nwire = 0
    spb = width // 32            # slots per DAC beat
    kscale = width // 128        # the testbench scales its time offsets by this
    beat = spb * ts
    fci = None
    beats = []                 # (tick, [spb slots])
    status = []                # Status in order
    arp_frames, arp_expect = [], []
    bursts = []                # dicts in log order
    flushed = set()
    quiesce = []               # (index into status, consumed)
    epoch_start = [0]          # status index at which consumed restarts from 0
    st_state = {}
    nstr = 0
    end_errors = None
    integ_line = None

    for ln, line in enumerate(open(path), 1):
        line = line.rstrip("\n")
        where = f"line {ln}"
        if line.startswith("D "):
            _, t, h = line.split()
            v = int(h, 16)
            if len(h) != width // 4:
                err(f"{where}: DAC beat has {len(h)} hex digits, want {width // 4}")
            beats.append((int(t), [(v >> (32 * k)) & 0xFFFFFFFF for k in range(spb)]))
        elif line.startswith("C "):
            f = bytes.fromhex(line[2:])
            if f[12:14] == b"\x08\x06":
                arp_frames.append((where, f))
            else:
                s = Status(f, where)
                if s.ok:
                    s.where, s.nbeats = where, len(beats)
                    status.append(s)
        elif line.startswith("S "):
            nstr += 1
            check_streamer_frame(bytes.fromhex(line[2:]), where, st_state, ts, sfmt)
        elif line.startswith("W "):
            _, b, n0, h = line.split()
            got = bytes.fromhex(h)
            want = wire_bytes(int(b), int(n0), len(got) // BYTES_PER_SLOT[FMT])
            nwire += 1
            if got != want:
                k = next(k for k in range(len(got)) if got[k] != want[k])
                err(f"{where}: testbench wire bytes differ from the reference packer at byte {k}")
        elif line.startswith("# fmt"):
            p = line.split()
            if int(p[2]) != FMT:
                err(f"player.log was simulated with FMT {p[2]}, checking {FMT}")
            sfmt = int(p[4])
        elif line.startswith("# tick_step"):
            if int(line.split()[2]) != ts:
                err(f"player.log was simulated with TICK_STEP {line.split()[2]}, checking {ts}")
        elif line.startswith("# width"):
            if int(line.split()[2]) != width:
                err(f"player.log was simulated with M_WIDTH {line.split()[2]}, checking {width}")
        elif line.startswith("# cfg"):
            fci = int(line.split()[5])
        elif line.startswith("# arp_expect"):
            _, _, mac, ip = line.split()
            arp_expect.append(arp_reply(bytes.fromhex(mac), bytes.fromhex(ip)))
        elif line.startswith("# burst"):
            p = line.split()
            if p[3] == "flushed":
                flushed.add(int(p[2]))
                continue
            kv = dict(zip(p[3::2], p[4::2]))
            bursts.append(dict(b=int(p[2]), n=int(kv["n"]), timed=int(kv["timed"]),
                               tsf=int(kv["tsf"]), late=int(kv["late"]), und=int(kv["und"]),
                               now=int(kv["now"]), nbeat0=len(beats)))
        elif line.startswith("# quiesce"):
            quiesce.append((line.split()[2], len(status), int(line.split()[4])))
        elif line.startswith("# flush"):
            epoch_start.append(len(status))
        elif line.startswith("# end errors"):
            end_errors = int(line.split()[3])
        elif line.startswith("# integ"):
            integ_line = line

    if end_errors is None:
        err("testbench did not finish")
    elif end_errors:
        err(f"testbench reported {end_errors} errors")

    # ---- ARP replies: byte-exact, in order, nothing else
    if not integ:
        if len(arp_frames) != len(arp_expect):
            err(f"{len(arp_frames)} ARP replies, want {len(arp_expect)}")
        for (where, f), want in zip(arp_frames, arp_expect):
            if f != want:
                err(f"{where}: ARP reply\n  got  {f.hex()}\n  want {want.hex()}")
    else:
        want = arp_reply(HOST_MAC, HOST_IP)
        for where, f in arp_frames:
            if f != want:
                err(f"{where}: ARP reply {f.hex()}")
    print(f"ARP replies: {len(arp_frames)} checked")

    # ---- flow control
    # consumed is free-running across flushes; a flush credits the flushed
    # words in one step, so the first report after it is exempt from the bound
    after_flush = set(epoch_start[1:])
    maxstep, prev = 0, 0
    for i, s in enumerate(status):
        if s.cons < prev:
            err(f"{s.where}: consumed went back {prev} -> {s.cons}")
        if i not in after_flush:
            maxstep = max(maxstep, s.cons - prev)
            if fci is not None and s.cons - prev > fci + FC_SLACK:
                err(f"{s.where}: consumed jumped {prev} -> {s.cons} (FC_INTERVAL {fci})")
        prev = s.cons
    for name, idx, cons in quiesce:
        if idx == 0 or status[idx - 1].cons != cons:
            got = status[idx - 1].cons if idx else None
            err(f"quiesce {name}: last status reports consumed {got}, host sent {cons}")
    ncode = {c: sum(1 for s in status if s.code == c) for c in (0, 1, 2, 4, 8)}
    print(f"status packets: {len(status)}  by code {ncode}  largest consumed step {maxstep}"
          f" (FC_INTERVAL {fci})")

    if integ:
        print(f"streamer frames: {nstr} checked through the arbiter")
        print(integ_line)
        if nstr < 100:
            err("too few streamer frames")
        if ncode[1] != 1:
            err("integration burst not acknowledged")
        finish()
        return

    # ---- DAC trace vs bursts
    acks = [s for s in status if s.code == 1]
    lates = [s for s in status if s.code == 8]
    unds = [s for s in status if s.code == 2]
    seqs = [s for s in status if s.code == 4]
    pos = 0
    for i, b in enumerate(bursts):
        name = f"burst {b['b']}"
        want = [samp(b["b"], n) for n in range(b["n"])]
        want += [0] * (-len(want) % 16)          # fc32: a padded half group
        nb_all = len(want) // spb                # beats played, zero ones included
        nb = sum(1 for k in range(nb_all) if any(want[spb * k:spb * k + spb]))   # logged
        if pos + nb > len(beats):
            err(f"{name}: only {len(beats) - pos} beats left, want {nb}")
            break
        seg = beats[pos:pos + nb]
        pos += nb
        for k, (t, s4) in enumerate(seg):
            if s4 != want[spb * k:spb * k + spb]:
                err(f"{name}: beat {k} at tick {t}: got {[hex(x) for x in s4]} "
                    f"want {[hex(x) for x in want[spb * k:spb * k + spb]]}")
                break
        start = seg[0][0]
        end = seg[-1][0] + (nb_all - nb) * beat  # padded zero beats follow the last logged one
        gaps = [(seg[k - 1][0] + beat, seg[k][0] - seg[k - 1][0] - beat)
                for k in range(1, nb) if seg[k][0] != seg[k - 1][0] + beat]
        info = f"{name}: {b['n']} samples, start {start} end {end}"
        if b["timed"] and not b["late"]:
            tbeat = b["tsf"] - b["tsf"] % beat
            if start != tbeat:
                err(f"{name}: started at {start}, TSF {b['tsf']} is in beat {tbeat}")
            info += f" (TSF {b['tsf']}: on its beat)"
        if b["late"]:
            if not (start > b["tsf"] and start - b["now"] < 4000 * ts * kscale):
                err(f"{name}: late burst started at {start} (tsf {b['tsf']}, now {b['now']})")
            ev = [s for s in lates if s.tsf == start]
            if len(ev) != 1:
                err(f"{name}: no TIME_ERROR with tsf {start}: {[s.tsf for s in lates]}")
            info += " TIME_ERROR ok" if ev else ""
        if not b["timed"] and start <= b["now"]:
            err(f"{name}: untimed burst starts before it was sent")
        if b["und"]:
            if len(gaps) != 1:
                err(f"{name}: {len(gaps)} gaps, want exactly 1 underflow gap")
            else:
                g0, glen = gaps[0]
                ev = [s for s in unds if s.tsf == g0]
                if len(ev) != 1:
                    err(f"{name}: no UNDERFLOW with tsf {g0}: {[s.tsf for s in unds]}")
                if g0 != start + 512 * ts:
                    err(f"{name}: underflow at {g0}, want after the first 512 samples")
                info += f", underflow gap at {g0} for {glen} ticks, UNDERFLOW ok"
        elif gaps:
            err(f"{name}: unexpected gaps in playout {gaps[:4]}")
        if i < len(acks):
            if acks[i].tsf != end:
                err(f"{name}: BURST_ACK tsf {acks[i].tsf}, last beat at {end}")
            elif acks[i].nbeats < pos:
                err(f"{name}: BURST_ACK arrived before the burst's last beat")
            else:
                info += ", BURST_ACK ok"
        else:
            err(f"{name}: no BURST_ACK")
        if b["b"] == 5:
            # A sequence error is stamped in tx_clk with the snapshot of
            # adc_time crossed by a handshake, up to ~2 handshake periods
            # (~16 adc_clk cycles) old. At a slow adc_clk (60 MHz, 512-bit
            # beats) that can predate the testbench's "now", taken just
            # before the packets were sent; allow 32 beats.
            if len(seqs) != 1 or not (b["now"] - 32 * beat <= seqs[0].tsf <= end):
                err(f"{name}: SEQ_ERROR {[s.tsf for s in seqs]} not within the burst")
            else:
                info += ", SEQ_ERROR ok"
        print(info)
    if pos != len(beats):
        t, s4 = beats[pos]
        err(f"{len(beats) - pos} DAC beats not belonging to any burst, first at tick {t} "
            f"{[hex(x) for x in s4]} (flushed/bad-FCS data leaked?)")
    if len(acks) != len(bursts):
        err(f"{len(acks)} BURST_ACKs for {len(bursts)} bursts")
    want_late = sum(1 for b in bursts if b["late"])
    want_und = sum(1 for b in bursts if b["und"])
    if len(lates) != want_late or len(unds) != want_und or len(seqs) != 1:
        err(f"event counts: late {len(lates)} (want {want_late}) underflow {len(unds)} "
            f"(want {want_und}) seq {len(seqs)}")
    print(f"DAC: {len(beats)} data beats in {len(bursts)} bursts; flushed bursts {sorted(flushed)}")
    if FMT:
        print(f"FMT {FMT_NAMES[FMT]}: {nwire} packet payloads match the reference packer")
    finish()


def finish():
    if errors:
        sys.exit(f"FAIL: {len(errors)} errors")
    print("PASS")


if __name__ == "__main__":
    main()
