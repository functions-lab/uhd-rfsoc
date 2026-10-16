"""eth100g/tx_beamformer of the N >= 2 v49 builds (Protocol §11).

Register map: fpga_ip/ip_design/uhd_ip/src/tx_beamformer.v (header;
packaged as user.org:uhd:tx_beamformer:1.0). AXI-Lite at 0x8006_0000 in
every N >= 2 build; the N = 1 builds have none. The driver is only ever created from an ip_dict entry
named tx_beamformer (never from a fallback address: an AXI access to an
unmapped address can hang the PS).

  0x00 ID    RO  0x5A423031 'ZB01'
  0x04 CTRL  RW  [0] enable: 0 = bit-exact bypass, 1 = DAC c gets ch0 x w[c]
  0x08 NCH   RO  N
  0x0C LOAD  WO  1: apply W[0..N-1] atomically (between beats)
  0x40+4c W[c] RW int16 real [15:0], int16 imag [31:16], Q1.15; reset 0x00007FFF

The weights of an angle come from rfsoc_lib/dsp/beamformer.py
(backend.steering_weights); this module only moves numbers into registers.
"""
from __future__ import annotations

import logging
from typing import List, Optional, Tuple

log = logging.getLogger("zcu216.bf")

BF_NAME = "tx_beamformer"
BF_ID = 0x00
BF_ID_VALUE = 0x5A423031
BF_CTRL = 0x04
BF_CTRL_ENABLE = 1 << 0
BF_NCH = 0x08
BF_LOAD = 0x0C
BF_W0 = 0x40
BF_RANGE = 0x10000

UNITY = (32767, 0)                      # the RTL's reset weight 0x00007FFF
DEFAULT_ELEMENT_SPACING = 1.07e-3       # m   (rfsoc_lib Beamformer defaults)
DEFAULT_CARRIER_FREQ = 135e9            # Hz


def pack_weight(re: int, im: int) -> int:
    """(re, im) Q1.15 -> the 32-bit W[c] word: real [15:0], imag [31:16]."""
    for v in (re, im):
        if not -32768 <= int(v) <= 32767:
            raise ValueError(f"weight part {v} is not int16")
    return (int(re) & 0xFFFF) | ((int(im) & 0xFFFF) << 16)


def unpack_weight(word: int) -> Tuple[int, int]:
    def s16(x):
        x &= 0xFFFF
        return x - 0x10000 if x & 0x8000 else x
    return s16(word), s16(word >> 16)


class TxBeamformer:
    """The tx_beamformer registers of a loaded build."""

    def __init__(self, mmio, nch: int):
        self.m, self.nch = mmio, int(nch)
        got = self.m.read(BF_ID)
        if got != BF_ID_VALUE:
            raise RuntimeError(f"tx_beamformer: ID 0x{got:08x}, expected 0x{BF_ID_VALUE:08x}")
        n = self.m.read(BF_NCH)
        if n != self.nch:
            raise RuntimeError(f"tx_beamformer: NCH reads {n}, the build streams {self.nch}")

    @classmethod
    def from_ip_dict(cls, ip_dict: dict, nch: int, mmio_factory=None) -> Optional["TxBeamformer"]:
        """The build's beamformer, or None if its hwh lists none (N = 1)."""
        keys = [k for k in (ip_dict or {}) if k == BF_NAME or k.endswith("/" + BF_NAME)]
        if not keys:
            return None
        if len(keys) > 1:
            raise RuntimeError(f"several IPs named {BF_NAME}: {keys}")
        d = ip_dict[keys[0]]
        if mmio_factory is None:
            from pynq import MMIO as mmio_factory  # noqa: N813
        bf = cls(mmio_factory(int(d["phys_addr"]), int(d.get("addr_range", BF_RANGE))), nch)
        log.info("tx_beamformer: %s @0x%08x, %d channels", keys[0], int(d["phys_addr"]), nch)
        return bf

    def apply(self, enable: bool, weights: List[Tuple[int, int]]) -> None:
        """Weights first (one LOAD, atomic in the datapath), then the mode."""
        if len(weights) != self.nch:
            raise ValueError(f"{len(weights)} weights for {self.nch} channels")
        for c, (re, im) in enumerate(weights):
            self.m.write(BF_W0 + 4 * c, pack_weight(re, im))
        self.m.write(BF_LOAD, 1)
        self.m.write(BF_CTRL, BF_CTRL_ENABLE if enable else 0)

    def read(self) -> Tuple[bool, List[Tuple[int, int]]]:
        """(enable, W registers) as the FPGA holds them."""
        return (bool(self.m.read(BF_CTRL) & BF_CTRL_ENABLE),
                [unpack_weight(self.m.read(BF_W0 + 4 * c)) for c in range(self.nch)])
