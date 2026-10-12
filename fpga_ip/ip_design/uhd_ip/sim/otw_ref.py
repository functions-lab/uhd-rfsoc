"""Reference over-the-wire (OTW) sample converters, rfsoc_lib/uhd/PROTOCOL.md 10.

Used by check_frames.py (RX, udp_streamer) and check_player.py (TX,
udp_player). Samples are (I, Q) pairs of Python ints (int16 range).

  RX (ADC -> wire):  sc8  = round-half-up(x / 256) saturated to int8
                     sc12 = round-half-up(x / 16) saturated to int12
                     fc32 = numpy.float32(x / 32768) (exact)
  TX (wire -> DAC):  sc8 * 256, sc12 * 16 (UHD's integer unpack),
                     fc32: round-half-even(v * 32768) saturated, NaN -> 0

The sc12 byte layout is UHD's sc12_item32_le: pack_sc12 / unpack_sc12 are
line-for-line ports of pack() in host/lib/convert/convert_pack_sc12.hpp and of
the integral convert_sc12_item32_3_to_star_4() in convert_unpack_sc12.hpp
(UHD v4.6.0.0), with towire/tohost = little-endian 32-bit words.
"""
import struct

import numpy as np

FMT_NAMES = {0: "sc16", 1: "sc8", 2: "sc12", 3: "fc32"}
BYTES_PER_SLOT = {0: 4, 1: 2, 2: 3, 3: 8}
GRAN = {0: 16, 1: 32, 2: 64, 3: 8}          # SPP granularity, slots
SPP_MAX = {0: 2048, 1: 4096, 2: 2688, 3: 1024}


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


# ---------------------------------------------------------------- RX rounding
def rx_sc8(x):
    return min((x + 128) >> 8, 127)          # >> floors: round half up


def rx_sc12(x):
    return min((x + 8) >> 4, 2047)


def rx_fc32(x):
    return np.float32(x / 32768.0)


# ---------------------------------------------------------------- UHD sc12
def _u32(v):
    return v & 0xFFFFFFFF


def pack_sc12(iq8):
    """UHD pack(): 8 int32 values (already & 0xfff) -> 3 lines."""
    line0 = _u32(iq8[0] << 20 | iq8[1] << 8 | iq8[2] >> 4)
    line1 = _u32(iq8[2] << 28 | iq8[3] << 16 | iq8[4] << 4 | iq8[5] >> 8)
    line2 = _u32(iq8[5] << 24 | iq8[6] << 12 | iq8[7] << 0)
    return line0, line1, line2


def unpack_sc12(line0, line1, line2):
    """UHD convert_sc12_item32_3_to_star_4<short>: 3 lines -> 4 (I, Q) sc16."""
    line01 = ((line0 << 32) | line1) & 0xFFFFFFFFFFFFFFFF
    line12 = ((line1 << 32) | line2) & 0xFFFFFFFFFFFFFFFF
    # std::complex<short>(int, int) truncates to 16 bits
    out0 = (s16(line0 >> 16 & 0xfff0), s16(line0 >> 4 & 0xfff0))
    out1 = (s16(line01 >> 24 & 0xfff0), s16(line1 >> 12 & 0xfff0))
    out2 = (s16(line1 >> 0 & 0xfff0), s16(line12 >> 20 & 0xfff0))
    out3 = (s16(line2 >> 8 & 0xfff0), s16(line2 << 4 & 0xfff0))
    return [out0, out1, out2, out3]


def sc12_bytes(vals12):
    """(I12, Q12) pairs (multiple of 4) -> payload bytes, sc12_item32_le."""
    out = bytearray()
    for b in range(0, len(vals12), 4):
        iq = []
        for i, q in vals12[b:b + 4]:
            iq += [i & 0xfff, q & 0xfff]
        out += struct.pack("<3I", *pack_sc12(iq))
    return bytes(out)


def sc12_decode(payload):
    """payload bytes -> (I, Q) sc16 via UHD's unpack (int16 = v << 4)."""
    out = []
    for o in range(0, len(payload), 12):
        out += unpack_sc12(*struct.unpack_from("<3I", payload, o))
    return out


# ---------------------------------------------------------------- RX payload
def rx_payload(samples, fmt):
    """sc16 (I, Q) slots -> the payload bytes udp_streamer must emit."""
    if fmt == 0:
        return b"".join(struct.pack("<hh", i, q) for i, q in samples)
    if fmt == 1:
        return bytes(b & 0xFF for i, q in samples for b in (rx_sc8(i), rx_sc8(q)))
    if fmt == 2:
        return sc12_bytes([(rx_sc12(i), rx_sc12(q)) for i, q in samples])
    a = np.array([v for s in samples for v in s], dtype=np.float64) / 32768.0
    return a.astype("<f4").tobytes()


# ---------------------------------------------------------------- TX
def tx_fc32(bits):
    """float32 bit pattern -> int16 as the FPGA plays it."""
    v = np.array([bits], dtype=np.uint32).view(np.float32)[0]
    if np.isnan(v):
        return 0
    if np.isinf(v):
        return 32767 if v > 0 else -32768
    r = np.rint(np.float64(v) * 32768.0)            # exact product, half to even
    return int(min(max(r, -32768), 32767))


def tx_payload_to_sc16(payload, fmt):
    """payload bytes -> (I, Q) sc16 slots."""
    if fmt == 0:
        return [struct.unpack_from("<hh", payload, o) for o in range(0, len(payload), 4)]
    if fmt == 1:
        b = struct.unpack(f"<{len(payload)}b", payload)
        return [(b[k] * 256, b[k + 1] * 256) for k in range(0, len(b), 2)]
    if fmt == 2:
        return sc12_decode(payload)
    w = struct.unpack(f"<{len(payload) // 4}I", payload)
    return [(tx_fc32(w[k]), tx_fc32(w[k + 1])) for k in range(0, len(w), 2)]


def _selftest():
    # sc12 pack/unpack round trip over the full 12-bit range
    vals = [(i, (-i - 1) & 0xFFF) for i in range(-2048, 2048)]
    vals = [(s16(i << 4) >> 4, s16(q << 4) >> 4) for i, q in vals]
    got = sc12_decode(sc12_bytes(vals))
    assert got == [(i * 16, q * 16) for i, q in vals], "sc12 round trip"
    # fc32 RX is exact and TX inverts it
    for x in (-32768, -1, 0, 1, 32767, 12345):
        f = rx_fc32(x)
        assert float(f) * 32768 == x
        assert tx_fc32(int(np.array([f], np.float32).view(np.uint32)[0])) == x
    assert rx_sc8(32640) == 127 and rx_sc8(-32768) == -128 and rx_sc8(128) == 1 and rx_sc8(-128) == 0
    assert rx_sc12(32760) == 2047 and rx_sc12(-32768) == -2048 and rx_sc12(8) == 1 and rx_sc12(-8) == 0


_selftest()
