#!/usr/bin/env python3
"""Check frames.hex from tb_udp_streamer against rfsoc_lib/uhd/PROTOCOL.md.

Every frame is parsed the way the host stack sees it: Ethernet II, IPv4 with a
valid header checksum, UDP, then the VRT header decoded little-endian. The
payload is recomputed from the packet TSF (ADC model or test pattern), so one
wrong byte anywhere fails the run.

  check_frames.py [--tick-step N] [--width W] [--fmt F] [frames.hex]

Slot i of a packet has timestamp TSF + i*N (N = TICK_STEP ticks per slot,
default 1); a W-bit ADC beat (W = S_WIDTH, default 128) is W/32 slots and
spans (W/32)*N ticks.

--fmt (0 sc16, 1 sc8, 2 sc12, 3 fc32; PROTOCOL.md 10): the payload is
compared byte for byte with the sc16 model passed through otw_ref's reference
converter; sc12 payloads are also decoded with the port of UHD's unpack and
compared value for value. fc32 at S_WIDTH 512, and every format but sc8 at
S_WIDTH 1024, are unsupported by design: every packet must be dropped (no
frame at all) and counted as an overflow.
"""
import argparse
import struct
import sys

from otw_ref import BYTES_PER_SLOT, FMT_NAMES, GRAN, rx_payload, rx_sc12, sc12_decode

SRC_MAC = bytes.fromhex("aabbddeeff01")
DST_MAC = bytes.fromhex("1a2b5c6d7e8f")
SRC_IP, DST_IP = bytes([192, 168, 5, 2]), bytes([192, 168, 5, 1])
SPORT, DPORT0, NPORTS, SPP, SID = 49800, 49810, 3, 64, 0x5A160000


def ip_csum(hdr):
    s = sum(struct.unpack("!10H", hdr))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s


CORNER_I = [32767, -32768, 32640, 32639, 128, -128, 384, -384, 8, -8, 24, -24,
            32760, 32759, 0, -1]
CORNER_Q = [-32768, 32767, -32640, 32631, 136, -136, 383, -385, 7, -9, 40, -40,
            -32760, 32752, 1, 255]


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def adc_sample(t, ts=1, fmt=0):
    n = t // ts
    if fmt != 0 and n % 64 < 16:
        return (CORNER_I[n % 16], CORNER_Q[n % 16])
    return (s16(t * 3), s16((t & 0xFFFF) ^ 0x5A5A))


def pat_sample(t, ts=1, fmt=0):
    i = t & 0xFFFF
    return (s16(i), s16(~i))


def check(path, ts=1, width=128, fmt=0):
    beat = (width // 32) * ts
    bps, gran = BYTES_PER_SLOT[fmt], GRAN[fmt]
    cases, case, meta = {}, None, {}
    for line in open(path):
        line = line.strip()
        if line.startswith("# tick_step"):
            tb_ts = int(line.split()[2])
            assert tb_ts == ts, f"frames.hex was simulated with TICK_STEP {tb_ts}, checking {ts}"
        elif line.startswith("# width"):
            tb_w = int(line.split()[2])
            assert tb_w == width, f"frames.hex was simulated with S_WIDTH {tb_w}, checking {width}"
        elif line.startswith("# fast"):
            meta["fast_spp"] = int(line.split()[3])
        elif line.startswith("# fmt"):
            tb_f = int(line.split()[2])
            assert tb_f == fmt, f"frames.hex was simulated with FMT {tb_f}, checking {fmt}"
        elif line.startswith("# case"):
            case = line.split()[2]
            cases[case] = []
        elif line.startswith("# t_req"):
            _, _, t, _, n = line.split()
            meta["t_req"], meta["n_req"] = int(t), int(n)
        elif line.startswith("# overflows16"):
            meta["ovf16"] = int(line.split()[2])
        elif line.startswith("# overflows"):
            meta["ovf"] = int(line.split()[2])
        elif line:
            cases[case].append(bytes.fromhex(line))

    if (fmt == 3 and width == 512) or (fmt != 1 and width == 1024):
        what = f"{FMT_NAMES[fmt]} at S_WIDTH {width}"
        nfr = sum(len(f) for f in cases.values())
        assert nfr == 0, f"{what} must drop everything, {nfr} frames sent"
        assert meta.get("ovf", 0) > 0 and meta.get("ovf16", 0) > 0, f"{what}: drops not counted"
        print(f"{what}: 0 frames, {meta['ovf']} + {meta['ovf16']} packets "
              "dropped and counted (unsupported by design)")
        print(f"PASS (TICK_STEP {ts}, S_WIDTH {width}, FMT {FMT_NAMES[fmt]})")
        return

    errors = 0
    port_k = 0
    pkt_cnt = 0
    for name, frames in cases.items():
        sample = pat_sample if name == "burst" else adc_sample
        prev_end = None
        gaps = 0
        nsamps_total = 0
        for idx, f in enumerate(frames):
            where = f"{name}[{idx}]"
            assert f[0:6] == DST_MAC and f[6:12] == SRC_MAC, where + " MAC"
            assert f[12:14] == b"\x08\x00", where + " ethertype"
            ip = f[14:34]
            assert ip[0] == 0x45 and ip[9] == 17, where + " ip ver/proto"
            assert ip_csum(ip) == 0xFFFF, where + " ip checksum"
            assert ip[12:16] == SRC_IP and ip[16:20] == DST_IP, where + " ip addr"
            ip_len = struct.unpack("!H", ip[2:4])[0]
            assert ip_len == len(f) - 14, f"{where} ip_len {ip_len} vs {len(f) - 14}"
            sport, dport, ulen, ucs = struct.unpack("!4H", f[34:42])
            assert sport == SPORT and ulen == ip_len - 20 and ucs == 0, where + " udp"
            assert dport == DPORT0 + port_k, f"{where} dport {dport} want {DPORT0 + port_k}"
            port_k = (port_k + 1) % NPORTS
            w0, sid, tsf_hi, tsf_lo = struct.unpack("<4I", f[42:58])
            assert (w0 >> 28) == 0x1, where + " pkt type/SID bit"
            assert (w0 >> 20) & 0x3 == 1 and (w0 >> 22) & 0x3 == 0, where + " TSF/TSI"
            assert (w0 >> 16) & 0xF == pkt_cnt, f"{where} pkt count"
            pkt_cnt = (pkt_cnt + 1) & 0xF
            nwords = w0 & 0xFFFF
            assert nwords * 4 == ulen - 8, f"{where} vrt len {nwords}"
            assert sid == SID, where + " sid"
            sob, eob = (w0 >> 25) & 1, (w0 >> 24) & 1
            tsf = (tsf_hi << 32) | tsf_lo
            assert tsf % beat == 0, f"{where} tsf {tsf} not a multiple of {beat}"
            payload = f[58:]
            assert len(payload) == 4 * (nwords - 4), where + " payload length"
            assert len(payload) % bps == 0, f"{where} payload {len(payload)} not whole slots"
            n = len(payload) // bps
            spp = gran if name == "spp16" else meta.get("fast_spp", SPP)
            assert len(payload) % 64 == 0, f"{where} payload not whole 64-byte words"
            assert n % gran == 0 and 0 < n <= spp, f"{where} nsamps {n}"
            samples = [sample(tsf + i * ts, ts, fmt) for i in range(n)]
            want = rx_payload(samples, fmt)
            if payload != want:
                bad = next(k for k in range(len(want)) if payload[k] != want[k])
                i = bad // bps
                print(f"{where} byte {bad} (slot {i}, t={tsf + i * ts}, sc16 {samples[i]}): "
                      f"got {payload[i * bps:(i + 1) * bps].hex()} "
                      f"want {want[i * bps:(i + 1) * bps].hex()}")
                errors += 1
            if fmt == 2:
                # the host's view: UHD's unpack of the received bytes
                dec = sc12_decode(payload)
                exp = [(rx_sc12(i) * 16, rx_sc12(q) * 16) for i, q in samples]
                exp = [(s16(i), s16(q)) for i, q in exp]
                if dec != exp:
                    k = next(k for k in range(n) if dec[k] != exp[k])
                    print(f"{where} sc12 UHD unpack slot {k}: got {dec[k]} want {exp[k]}")
                    errors += 1
            if prev_end is not None and tsf != prev_end:
                gaps += 1
            if idx == 0:
                assert sob == 1, where + " first packet lacks SOB"
            prev_end = tsf + n * ts
            nsamps_total += n
            if name == "burst":
                if idx == 0:
                    assert tsf <= meta["t_req"] < tsf + beat, \
                        f"{where} start tsf {tsf} vs req {meta['t_req']}"
                    burst_t0 = tsf
                assert eob == (idx == len(frames) - 1), where + " EOB placement"
        print(f"{name}: {len(frames)} frames, {nsamps_total} samples, {gaps} gaps")
        if name == "cont":
            if fmt == 0 and "fast_spp" in meta and width == 512:
                # sc16 at one group per cycle exceeds what the framer (and the
                # 100G link) carries: drops are expected, visible as gaps
                print(f"cont: sc16 at full converter rate (beyond the 100G link; drops allowed), {gaps} gaps")
            else:
                assert gaps == 0, "gaps in continuous stream without backpressure"
        if name == "burst":
            want = (meta["n_req"] + gran - 1) // gran * gran
            assert nsamps_total == want, f"burst {nsamps_total} samples, want {want}"
        if name == "overflow":
            assert meta.get("ovf", 0) > 0, "stalled CMAC produced no overflow"
            assert gaps > 0, "overflow left no timestamp gap"
            print(f"overflow: {meta['ovf']} packets dropped, visible as {gaps} gaps")
        if name == "spp16":
            assert all(len(f) == 58 + gran * bps for f in frames), \
                f"spp16: every packet {gran} slots ({gran * bps // 64} words)"
            assert (meta.get("ovf16", 0) > 0) == (gaps > 0), \
                f"spp16: {meta.get('ovf16')} drops but {gaps} gaps"
            print(f"spp16: {meta.get('ovf16', 0)} packets dropped, visible as {gaps} gaps")
    if errors:
        sys.exit(f"FAIL: {errors} payload mismatches")
    print(f"PASS (TICK_STEP {ts}, S_WIDTH {width}, FMT {FMT_NAMES[fmt]})")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default="frames.hex")
    ap.add_argument("--tick-step", type=int, default=1)
    ap.add_argument("--width", type=int, default=128, choices=(128, 256, 512, 1024))
    ap.add_argument("--fmt", type=int, default=0, choices=(0, 1, 2, 3))
    a = ap.parse_args()
    check(a.path, a.tick_step, a.width, a.fmt)
