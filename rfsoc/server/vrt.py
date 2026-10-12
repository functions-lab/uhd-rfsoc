"""VITA-49-style packets of the uhd_zcu216 data plane (PROTOCOL.md §4-7).

Pure Python (numpy optional). Used by the daemon and by the host-side
checkers (host/tools/check_pattern_file.py, tests/client_check.py), so they
agree on one definition of the wire format.

Word 0 (little-endian):
    [28] SID present, [25] SOB, [24] EOB, [21:20]=1 TSF present,
    [19:16] packet count mod 16, [15:0] length in 32-bit words (= 4 + spp)
Word 1: stream ID 0x5A160000 | ch
Word 2/3: TSF high / low 32 bits (timestamp of the first slot, in ticks;
          slot k is at TSF + k * tps, tps = ticks per slot)
Word 4..: spp slots, int16 I (LE) then int16 Q (LE)

Multi-channel builds (§9): a packet is a sequence of SLOTS interleaved
sample-major -- slot i is channel i % N, sample i // N. With N = 1 a slot is a
sample. `spp`, burst lengths and the §5 pattern all count slots; the pattern
of slot i is keyed to tick TSF + i * tps, so it checks timing, channel order
and loss together.

OTW formats (§10): a slot is 4 bytes (sc16), 2 (sc8), 3 (sc12, packed 4 slots
in 3 words) or 8 (fc32); the FPGA converts from/to the converters' int16.
`sc16_to_wire` (RX) and `wire_to_sc16` (TX) are THE reference conversions:
the capture checker (host/tools/check_pattern_file.py) uses these.
"""
from __future__ import annotations

import math
import struct

try:  # numpy is present on the board venv and most hosts; optional
    import numpy as _np
except Exception:  # pragma: no cover
    _np = None

SID_BASE = 0x5A160000          # RX (FPGA -> host) stream IDs
TX_SID_BASE = 0x5A170000       # TX (host -> FPGA) stream IDs
ASYNC_MAGIC = 0x5A17A5C0
TX_PORT = 49900                # FPGA UDP port receiving TX samples
TX_SRC_PORT = 49801            # FPGA source port of async/FC packets
WORD_SAMPS = 16                # one 64-byte TX buffer word = 16 sc16 samples

# async event codes = uhd::async_metadata_t::event_code_t
EVENT_FC_UPDATE = 0x0
EVENT_BURST_ACK = 0x1
EVENT_UNDERFLOW = 0x2
EVENT_SEQ_ERROR = 0x4
EVENT_TIME_ERROR = 0x8
EVENT_UNDERFLOW_IN_PACKET = 0x10
EVENT_SEQ_ERROR_IN_BURST = 0x20
HDR_WORDS = 4
HDR_BYTES = 4 * HDR_WORDS
FPGA_SRC_PORT = 49800
GRANULE = 16           # FPGA works in 16-slot units (one 512-bit CMAC word)
BEAT = 4               # slots per 128-bit ADC beat (a wider fabric beat has more)
MAX_SPP = 2048
DEFAULT_SPP = 2048

_W0_SID = 1 << 28
_W0_SOB = 1 << 25
_W0_EOB = 1 << 24
_W0_TSF_COUNT = 1 << 20

_HDR = struct.Struct("<IIII")


def sid_for(ch: int) -> int:
    return (SID_BASE | (ch & 0xFFFF)) & 0xFFFFFFFF


def tx_sid_for(ch: int) -> int:
    return (TX_SID_BASE | (ch & 0xFFFF)) & 0xFFFFFFFF


def slot_granule(nch: int = 1) -> int:
    """Slot granularity of an N-channel stream: a multiple of 16 (the FPGA's
    unit) that is also a multiple of N (whole samples of every channel)."""
    nch = max(1, int(nch))
    return GRANULE * nch // math.gcd(GRANULE, nch)


def round_spp(spp: int, granule: int = GRANULE, max_spp: int = MAX_SPP) -> int:
    """Floor to a multiple of `granule`, clamp to [granule, max_spp]."""
    spp = int(spp)
    spp -= spp % granule
    top = max_spp - max_spp % granule
    return max(granule, min(top, spp))


def ceil_granule(n: int, granule: int = GRANULE) -> int:
    n = int(n)
    return ((n + granule - 1) // granule) * granule


def floor_beat(t: int, tps: int = 1, beat: int = BEAT) -> int:
    """Start of the fabric beat containing tick `t` (a beat is beat*tps ticks;
    `beat` slots per beat, 4 for a 128-bit beat)."""
    span = int(beat) * int(tps)
    return int(t) - (int(t) % span)


def pack_header(ch: int, tsf: int, nsamps: int, pkt_count: int,
                sob: bool = False, eob: bool = False, sid: int = None,
                has_time: bool = True, payload_words: int = None) -> bytes:
    """Header of an RX (§4) packet, or of a TX (§6) one with sid=tx_sid_for(ch).
    `nsamps` sc16 slots, or `payload_words` 32-bit words of another format."""
    words = nsamps if payload_words is None else payload_words
    w0 = (_W0_SID | ((pkt_count & 0xF) << 16)
          | ((HDR_WORDS + words) & 0xFFFF))
    if has_time:
        w0 |= _W0_TSF_COUNT
    if sob:
        w0 |= _W0_SOB
    if eob:
        w0 |= _W0_EOB
    return _HDR.pack(w0, sid_for(ch) if sid is None else sid,
                     (tsf >> 32) & 0xFFFFFFFF, tsf & 0xFFFFFFFF)


def unpack_header(buf: bytes) -> dict:
    if len(buf) < HDR_BYTES:
        raise ValueError(f"short packet: {len(buf)} B")
    w0, sid, hi, lo = _HDR.unpack_from(buf, 0)
    return {
        "pkt_type": (w0 >> 29) & 0x7,
        "has_sid": bool(w0 & _W0_SID),
        "has_trailer": bool(w0 & (1 << 26)),
        "sob": bool(w0 & _W0_SOB),
        "eob": bool(w0 & _W0_EOB),
        "tsi": (w0 >> 22) & 0x3,
        "tsf_type": (w0 >> 20) & 0x3,
        "count": (w0 >> 16) & 0xF,
        "len_words": w0 & 0xFFFF,
        "sid": sid,
        "tsf": (hi << 32) | lo,
    }


# --------------------------------------------------------------------------
# Sample payloads
# --------------------------------------------------------------------------

def pattern_word(t: int) -> int:
    """§5 counter pattern: I = t & 0xFFFF, Q = ~I (16-bit), as one LE word."""
    i = t & 0xFFFF
    return i | ((~i & 0xFFFF) << 16)


def _times(tsf: int, n: int, tps: int):
    """numpy array of the n sample timestamps tsf + k*tps (ticks)."""
    return _np.arange(n, dtype=_np.uint64) * _np.uint64(tps) + _np.uint64(tsf)


def pattern_payload(tsf: int, n: int, tps: int = 1) -> bytes:
    """§5 pattern for n samples starting at tick tsf, tps ticks apart."""
    if _np is not None:
        i = (_times(tsf, n, tps) & _np.uint64(0xFFFF)).astype(_np.uint32)
        w = i | ((~i & 0xFFFF) << 16)
        return w.astype("<u4").tobytes()
    return struct.pack("<%dI" % n, *(pattern_word(tsf + k * tps) for k in range(n)))


def tone_payload(tsf: int, n: int, freq_hz: float, tick_rate_hz: float,
                 amp: int = 8192, tps: int = 1) -> bytes:
    """Complex exponential keyed to the timestamp in ticks (phase-continuous);
    sample k is at tick tsf + k*tps."""
    w = 2.0 * math.pi * freq_hz / tick_rate_hz
    if _np is not None:
        t = _times(tsf, n, tps).astype(_np.float64)
        ph = _np.mod(t * w, 2 * math.pi)
        iq = _np.empty(2 * n, dtype="<i2")
        iq[0::2] = _np.round(amp * _np.cos(ph)).astype(_np.int16)
        iq[1::2] = _np.round(amp * _np.sin(ph)).astype(_np.int16)
        return iq.tobytes()
    out = []
    for k in range(n):
        ph = math.fmod((tsf + k * tps) * w, 2 * math.pi)
        out.append(int(round(amp * math.cos(ph))))
        out.append(int(round(amp * math.sin(ph))))
    return struct.pack("<%dh" % (2 * n), *out)


def tone_payload_multi(tsf: int, n: int, nch: int, freq_hz: float,
                       tick_rate_hz: float, amp: int = 8192, tps: int = 1) -> bytes:
    """n slots of an nch-channel stream (§9 interleave): channel c carries a
    tone at (c + 1) * freq_hz, sampled at its sample's time TSF + (i - c)*tps
    (all channels of one sample share its time)."""
    nch = max(1, int(nch))
    if nch == 1:
        return tone_payload(tsf, n, freq_hz, tick_rate_hz, amp=amp, tps=tps)
    if _np is not None:
        i = _np.arange(n, dtype=_np.int64)
        c = i % nch
        t = (tsf + (i - c) * int(tps)).astype(_np.float64)
        ph = _np.mod(t * (2.0 * math.pi * freq_hz / tick_rate_hz) * (c + 1), 2 * math.pi)
        iq = _np.empty(2 * n, dtype="<i2")
        iq[0::2] = _np.round(amp * _np.cos(ph)).astype(_np.int16)
        iq[1::2] = _np.round(amp * _np.sin(ph)).astype(_np.int16)
        return iq.tobytes()
    out = []
    for i in range(n):
        c = i % nch
        ph = math.fmod((tsf + (i - c) * tps) * 2.0 * math.pi * freq_hz
                       / tick_rate_hz * (c + 1), 2 * math.pi)
        out.append(int(round(amp * math.cos(ph))))
        out.append(int(round(amp * math.sin(ph))))
    return struct.pack("<%dh" % (2 * n), *out)


def check_pattern(payload: bytes, tsf: int, tps: int = 1) -> int:
    """Return the number of samples that do NOT match the §5 pattern."""
    n = len(payload) // 4
    if _np is not None:
        got = _np.frombuffer(payload[:4 * n], dtype="<u4")
        i = (_times(tsf, n, tps) & _np.uint64(0xFFFF)).astype(_np.uint32)
        exp = i | ((~i & 0xFFFF) << 16)
        return int(_np.count_nonzero(got != exp))
    got = struct.unpack("<%dI" % n, payload[:4 * n])
    return sum(1 for k, w in enumerate(got) if w != pattern_word(tsf + k * tps))


# --------------------------------------------------------------------------
# Async status packets (§7)
# --------------------------------------------------------------------------
_ASYNC = struct.Struct("<6I")
ASYNC_BYTES = _ASYNC.size


def pack_async(ch: int, tsf: int, event: int, consumed_words: int) -> bytes:
    return _ASYNC.pack(ASYNC_MAGIC, tx_sid_for(ch), (tsf >> 32) & 0xFFFFFFFF,
                       tsf & 0xFFFFFFFF, event & 0xFFFFFFFF,
                       consumed_words & 0xFFFFFFFF)


def unpack_async(buf: bytes) -> dict:
    if len(buf) < ASYNC_BYTES:
        raise ValueError(f"short async packet: {len(buf)} B")
    magic, sid, hi, lo, ev, cons = _ASYNC.unpack_from(buf, 0)
    if magic != ASYNC_MAGIC:
        raise ValueError(f"bad async magic 0x{magic:08x}")
    return {"sid": sid, "tsf": (hi << 32) | lo, "event": ev, "consumed": cons}


# --------------------------------------------------------------------------
# OTW sample formats (§10)
# --------------------------------------------------------------------------
OTW_FORMATS = ("sc16", "sc8", "sc12", "fc32")
OTW_CODE = {"sc16": 0, "sc8": 1, "sc12": 2, "fc32": 3}    # FPGA FMT register
OTW_SLOT_BYTES = {"sc16": 4, "sc8": 2, "sc12": 3, "fc32": 8}
OTW_GRANULE = {"sc16": 16, "sc8": 32, "sc12": 64, "fc32": 8}   # slots / whole 64-B words
MAX_PAYLOAD_BYTES = 8192
TX_WORD_BYTES = 64                 # flow-control credit unit (§6)
# 100GbE: what is left for UDP payload of ~8 KB frames after Ethernet
# preamble/IFG/header/FCS, IPv4, UDP and the 16-byte VRT header
LINK_PAYLOAD_BYTES_PER_S = 12.38e9


def otw_check(fmt: str) -> str:
    if fmt not in OTW_CODE:
        raise ValueError(f"unknown otw format {fmt!r} (want {'|'.join(OTW_FORMATS)})")
    return fmt


def otw_granule(fmt: str = "sc16", nch: int = 1) -> int:
    """spp / burst granularity in slots: whole 64-byte words of the format
    (16 sc16, 32 sc8, 64 sc12, 8 fc32 slots) and a multiple of N."""
    g, nch = OTW_GRANULE[fmt], max(1, int(nch))
    return g * nch // math.gcd(g, nch)


def otw_max_spp(fmt: str = "sc16") -> int:
    """Most slots one packet carries: an 8192-byte payload (sc16 2048, sc8
    4096, sc12 2730 -> 2688 after the granule, fc32 1024)."""
    return MAX_PAYLOAD_BYTES // OTW_SLOT_BYTES[fmt]


def otw_payload_bytes(fmt: str, slots: int) -> int:
    return int(slots) * OTW_SLOT_BYTES[fmt]


def otw_wire_rate(fmt: str, aggregate_slots_per_s: float) -> float:
    """Bytes/s of sample payload on the link (all channels)."""
    return float(aggregate_slots_per_s) * OTW_SLOT_BYTES[fmt]


def pack_sc12(v) -> bytes:
    """Interleaved 12-bit values I0,Q0,I1,Q1,... (a multiple of 8) -> UHD
    sc12_item32_le: per 4 slots w0 = {I0, Q0, I1[11:4]}, w1 = {I1[3:0], Q1,
    I2, Q2[11:8]}, w2 = {Q2[7:0], I3, Q3}, MSB first, words little-endian."""
    u = (_np.asarray(v, dtype=_np.int64) & 0xFFF).astype(_np.uint32).reshape(-1, 8)
    i0, q0, i1, q1, i2, q2, i3, q3 = (u[:, k] for k in range(8))
    w = _np.empty((u.shape[0], 3), dtype="<u4")
    w[:, 0] = (i0 << 20) | (q0 << 8) | (i1 >> 4)
    w[:, 1] = ((i1 & 0xF) << 28) | (q1 << 16) | (i2 << 4) | (q2 >> 8)
    w[:, 2] = ((q2 & 0xFF) << 24) | (i3 << 12) | q3
    return w.tobytes()


def unpack_sc12(data: bytes):
    """Inverse of pack_sc12: -> int32 array I0,Q0,I1,Q1,... (sign-extended)."""
    w = _np.frombuffer(data, dtype="<u4").astype(_np.uint32).reshape(-1, 3)
    w0, w1, w2 = w[:, 0], w[:, 1], w[:, 2]
    u = _np.empty((w.shape[0], 8), dtype=_np.uint32)
    u[:, 0] = w0 >> 20
    u[:, 1] = (w0 >> 8) & 0xFFF
    u[:, 2] = ((w0 & 0xFF) << 4) | (w1 >> 28)
    u[:, 3] = (w1 >> 16) & 0xFFF
    u[:, 4] = (w1 >> 4) & 0xFFF
    u[:, 5] = ((w1 & 0xF) << 8) | (w2 >> 24)
    u[:, 6] = (w2 >> 12) & 0xFFF
    u[:, 7] = w2 & 0xFFF
    v = u.astype(_np.int32)
    return (_np.where(v >= 2048, v - 4096, v)).reshape(-1)


def quantize(x, fmt: str):
    """int16 values -> the integers the wire carries (§10 RX rules):
    sc8 round-half-up(x/256) saturated to [-128, 127], sc12 round-half-up(x/16)
    saturated to [-2048, 2047]; sc16/fc32 unchanged (fc32 is x/32768, exact)."""
    x = _np.asarray(x, dtype=_np.int64)
    if fmt == "sc8":
        return _np.minimum((x + 128) >> 8, 127)
    if fmt == "sc12":
        return _np.minimum((x + 8) >> 4, 2047)
    return x


def sc16_to_wire(data: bytes, fmt: str) -> bytes:
    """RX (ADC -> wire), §10: an sc16 payload in the given OTW format."""
    if fmt == "sc16":
        return bytes(data)
    if _np is None:   # pragma: no cover
        raise RuntimeError("otw formats other than sc16 need numpy")
    x = _np.frombuffer(data, dtype="<i2")
    if fmt == "sc8":
        return quantize(x, fmt).astype(_np.int8).tobytes()
    if fmt == "sc12":
        return pack_sc12(quantize(x, fmt))
    if fmt == "fc32":
        return (x.astype(_np.float32) / _np.float32(32768.0)).astype("<f4").tobytes()
    raise ValueError(f"unknown otw format {fmt!r}")


def wire_to_sc16(data: bytes, fmt: str) -> bytes:
    """TX (wire -> DAC), §10: sc8 -> v * 256, sc12 -> v * 16, fc32 ->
    round(v * 32768) saturated (NaN -> 0)."""
    if fmt == "sc16":
        return bytes(data)
    if _np is None:   # pragma: no cover
        raise RuntimeError("otw formats other than sc16 need numpy")
    if fmt == "sc8":
        v = _np.frombuffer(data, dtype=_np.int8).astype(_np.int32) * 256
    elif fmt == "sc12":
        v = unpack_sc12(data) * 16
    elif fmt == "fc32":
        f = _np.frombuffer(data, dtype="<f4").astype(_np.float64)
        f = _np.where(_np.isnan(f), 0.0, f)
        v = _np.clip(_np.rint(f * 32768.0), -32768, 32767)
    else:
        raise ValueError(f"unknown otw format {fmt!r}")
    return v.astype("<i2").tobytes()
