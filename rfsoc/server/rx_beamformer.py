"""eth100g/rx_beamformer of the N >= 2 v49 builds (PROTOCOL.md §11).

Register map and datapath: hw_design/ip_design/uhd_ip/src/rx_beamformer.v
(header; packaged as user.org:uhd:rx_beamformer:1.0). AXI-Lite at 0x8007_0000
in the N >= 2 builds that carry it; the N = 1 builds and the bitstreams from
before it have none. The driver is only ever created from an ip_dict entry
named rx_beamformer (never from a fallback address: an AXI access to an
unmapped address can hang the PS).

  0x00 ID    RO  0x5A523031 'ZR01'
  0x04 CTRL  RW  [0] enable: 0 = bit-exact bypass, 1 = RX channel 0 carries
                 the beam (channels 1..N-1 unchanged)
  0x08 NCH   RO  N
  0x0C LOAD  WO  1: apply W[0..N-1] AND SHIFT to the datapath atomically
  0x10 SHIFT RW  [3:0] extra right shift, reset log2(N), applied on LOAD
  0x40+4c W[c] RW int16 real [15:0], int16 imag [31:16], Q1.15; reset 0x00007FFF

Beam (per sample, exact complex products and sum):
  acc = sum_c x_c * w[c]
  y   = sat16((acc + 2^(14+SHIFT)) >> (15+SHIFT))   per real / imag part
The weights are those of the TX beamformer for the same direction (no
conjugate: by reciprocity the propagation phase of element c is the same).
`beam_payload` is the bit-exact reference the software device and the tests use.
"""
from __future__ import annotations

import logging
import struct
from typing import List, Optional, Sequence, Tuple

from tx_beamformer import pack_weight, unpack_weight, UNITY  # noqa: F401  (re-exported)

try:
    import numpy as _np
except ImportError:  # pragma: no cover - the board image has numpy
    _np = None

log = logging.getLogger("zcu216.rbf")

RBF_NAME = "rx_beamformer"
RBF_ID = 0x00
RBF_ID_VALUE = 0x5A523031
RBF_CTRL = 0x04
RBF_CTRL_ENABLE = 1 << 0
RBF_NCH = 0x08
RBF_LOAD = 0x0C
RBF_SHIFT = 0x10
RBF_W0 = 0x40
RBF_RANGE = 0x10000
SHIFT_MAX = 15                          # SHIFT is a 4-bit field


def default_shift(nch: int) -> int:
    """The RTL's reset SHIFT: log2(N) (unity weights then average the N inputs)."""
    n = int(nch)
    if n < 1 or n & (n - 1):
        raise ValueError(f"N = {n} is not a power of two")
    return n.bit_length() - 1


def _sat16(v: int) -> int:
    return -32768 if v < -32768 else 32767 if v > 32767 else v


def beam_sample(x: Sequence[Tuple[int, int]], w: Sequence[Tuple[int, int]],
                shift: int) -> Tuple[int, int]:
    """One beam sample: x[c] = (I, Q) int16, w[c] = (re, im) Q1.15 -> (I, Q)."""
    acc_re = sum(i * wr - q * wi for (i, q), (wr, wi) in zip(x, w))
    acc_im = sum(i * wi + q * wr for (i, q), (wr, wi) in zip(x, w))
    s = 15 + int(shift)
    rnd = 1 << (s - 1)
    return _sat16((acc_re + rnd) >> s), _sat16((acc_im + rnd) >> s)


def beam_payload(payload: bytes, nch: int, weights: Sequence[Tuple[int, int]],
                 shift: int, first_chan: int = 0) -> bytes:
    """An sc16 slot-interleaved payload (§9: slot i = channel (first_chan + i)
    % N) with channel 0 of every whole sample replaced by the beam of that
    sample's N channels -- what eth100g/rx_beamformer does with CTRL.enable = 1.
    Channels 1..N-1 and slots of an incomplete sample at either end are kept."""
    nch = int(nch)
    if nch < 2 or len(weights) != nch:
        raise ValueError(f"{len(weights)} weights for {nch} channels")
    if not 0 <= int(shift) <= SHIFT_MAX:
        raise ValueError(f"shift {shift} not in 0..{SHIFT_MAX}")
    n = len(payload) // 4
    k0 = (nch - int(first_chan) % nch) % nch          # first slot of channel 0
    m = max(0, (n - k0) // nch)                       # whole samples
    if m == 0:
        return bytes(payload)
    s = 15 + int(shift)
    if _np is not None:
        iq = _np.frombuffer(payload, dtype="<i2").astype(_np.int64).copy()
        blk = iq[2 * k0:2 * (k0 + m * nch)].reshape(m, nch, 2)
        wr = _np.array([r for r, _ in weights], dtype=_np.int64)
        wi = _np.array([i for _, i in weights], dtype=_np.int64)
        i_, q_ = blk[:, :, 0], blk[:, :, 1]
        acc_re = (i_ * wr - q_ * wi).sum(axis=1)
        acc_im = (i_ * wi + q_ * wr).sum(axis=1)
        rnd = _np.int64(1) << _np.int64(s - 1)
        blk[:, 0, 0] = _np.clip((acc_re + rnd) >> _np.int64(s), -32768, 32767)
        blk[:, 0, 1] = _np.clip((acc_im + rnd) >> _np.int64(s), -32768, 32767)
        return iq.astype("<i2").tobytes()
    v = list(struct.unpack("<%dh" % (2 * n), payload[:4 * n]))
    for j in range(m):
        b = 2 * (k0 + j * nch)
        x = [(v[b + 2 * c], v[b + 2 * c + 1]) for c in range(nch)]
        v[b], v[b + 1] = beam_sample(x, weights, shift)
    return struct.pack("<%dh" % (2 * n), *v) + payload[4 * n:]


class RxBeamformer:
    """The rx_beamformer registers of a loaded build."""

    def __init__(self, mmio, nch: int):
        self.m, self.nch = mmio, int(nch)
        got = self.m.read(RBF_ID)
        if got != RBF_ID_VALUE:
            raise RuntimeError(f"rx_beamformer: ID 0x{got:08x}, expected 0x{RBF_ID_VALUE:08x}")
        n = self.m.read(RBF_NCH)
        if n != self.nch:
            raise RuntimeError(f"rx_beamformer: NCH reads {n}, the build streams {self.nch}")

    @classmethod
    def from_ip_dict(cls, ip_dict: dict, nch: int, mmio_factory=None) -> Optional["RxBeamformer"]:
        """The build's RX beamformer, or None if its hwh lists none (N = 1, or
        a bitstream from before it)."""
        keys = [k for k in (ip_dict or {}) if k == RBF_NAME or k.endswith("/" + RBF_NAME)]
        if not keys:
            return None
        if len(keys) > 1:
            raise RuntimeError(f"several IPs named {RBF_NAME}: {keys}")
        d = ip_dict[keys[0]]
        if mmio_factory is None:
            from pynq import MMIO as mmio_factory  # noqa: N813
        bf = cls(mmio_factory(int(d["phys_addr"]), int(d.get("addr_range", RBF_RANGE))), nch)
        log.info("rx_beamformer: %s @0x%08x, %d channels", keys[0], int(d["phys_addr"]), nch)
        return bf

    def apply(self, enable: bool, weights: List[Tuple[int, int]], shift: int) -> None:
        """Weights and SHIFT first (one LOAD, atomic in the datapath), then the mode."""
        if len(weights) != self.nch:
            raise ValueError(f"{len(weights)} weights for {self.nch} channels")
        if not 0 <= int(shift) <= SHIFT_MAX:
            raise ValueError(f"shift {shift} not in 0..{SHIFT_MAX}")
        for c, (re, im) in enumerate(weights):
            self.m.write(RBF_W0 + 4 * c, pack_weight(re, im))
        self.m.write(RBF_SHIFT, int(shift))
        self.m.write(RBF_LOAD, 1)
        self.m.write(RBF_CTRL, RBF_CTRL_ENABLE if enable else 0)

    def read(self) -> Tuple[bool, List[Tuple[int, int]], int]:
        """(enable, W registers, SHIFT) as the FPGA holds them."""
        return (bool(self.m.read(RBF_CTRL) & RBF_CTRL_ENABLE),
                [unpack_weight(self.m.read(RBF_W0 + 4 * c)) for c in range(self.nch)],
                self.m.read(RBF_SHIFT) & 0xF)
