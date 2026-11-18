"""eth100g/rx_rate of the chained v49 builds: the depth of the low-rate
chains (rates fs / 40 / 2^k below the RFDC's F = 40; design
docs/superpowers/specs/2026-11-17-low-rate-fir-design.md).

Register map and datapath: fpga/ip/src/uhd_ip/src/rx_rate.v (header;
packaged as user.org:uhd:rx_rate:1.0), AXI-Lite at 0x8009_0000. tx_rate takes
the depth and the chain reset from it. Bitstreams from before the chains have
none; the driver is only ever created from an ip_dict entry named rx_rate
(never from a fallback address: an AXI access to an unmapped address can hang
the PS).

  0x00 ID     RO  0x5A525431 'ZRT1'
  0x04 CTRL   RW  [0] chain reset (1 = held; reset value 1)
  0x08 DEPTH  RW  [3:0] 0..K (a write above K is ignored)
  0x0C INFO   RO  [3:0] K, [11:8] log2(SPC), [20:16] N_CH, [25:24] G
  0x10 STATUS RO  [0] stage-input stall, [1] centre FIFO overflow (sticky
                  since the last chain reset; either means lost samples)

DEPTH changes only with the chain held (CTRL[0] = 1) and streaming stopped;
depth 0 is the bit-exact bypass, and the chain stays held there.
"""
from __future__ import annotations

import logging
from typing import Optional

log = logging.getLogger("uhd_rfsoc.rate")

RATE_NAME = "rx_rate"
RATE_ID = 0x00
RATE_ID_VALUE = 0x5A525431
RATE_CTRL = 0x04
RATE_DEPTH = 0x08
RATE_INFO = 0x0C
RATE_STATUS = 0x10
RATE_RANGE = 0x10000


class RateChain:
    """The rx_rate registers of a loaded build."""

    def __init__(self, mmio, nch: int):
        self.m = mmio
        got = self.m.read(RATE_ID)
        if got != RATE_ID_VALUE:
            raise RuntimeError(f"rx_rate: ID 0x{got:08x}, expected 0x{RATE_ID_VALUE:08x}")
        info = self.m.read(RATE_INFO)
        self.k_max = info & 0xF
        self.spc = 1 << ((info >> 8) & 0xF)
        self.nch = (info >> 16) & 0x1F
        self.groups = (info >> 24) & 0x3
        if self.nch != int(nch):
            raise RuntimeError(f"rx_rate: N_CH reads {self.nch}, the build streams {nch}")

    @classmethod
    def from_ip_dict(cls, ip_dict: dict, nch: int, mmio_factory=None) -> Optional["RateChain"]:
        """The build's rate chain, or None if its hwh lists none."""
        keys = [k for k in (ip_dict or {}) if k == RATE_NAME or k.endswith("/" + RATE_NAME)]
        if not keys:
            return None
        if len(keys) > 1:
            raise RuntimeError(f"several IPs named {RATE_NAME}: {keys}")
        d = ip_dict[keys[0]]
        if mmio_factory is None:
            from pynq import MMIO as mmio_factory  # noqa: N813
        rc = cls(mmio_factory(int(d["phys_addr"]), int(d.get("addr_range", RATE_RANGE))), nch)
        log.info("rx_rate: %s @0x%08x, K %d, %d samples/clock, %d channels",
                 keys[0], int(d["phys_addr"]), rc.k_max, rc.spc, rc.nch)
        return rc

    def hold(self, on: bool) -> None:
        """Hold the chain (and every FIR of both directions) in reset, or run it."""
        self.m.write(RATE_CTRL, 1 if on else 0)

    def set_depth(self, k: int) -> None:
        k = int(k)
        if not 0 <= k <= self.k_max:
            raise ValueError(f"rate depth {k} not in 0..{self.k_max}")
        self.m.write(RATE_DEPTH, k)
        got = self.depth()
        if got != k:
            raise RuntimeError(f"rx_rate: DEPTH reads {got} after writing {k}")

    def depth(self) -> int:
        return self.m.read(RATE_DEPTH) & 0xF

    def status(self) -> int:
        """[0] stall, [1] overflow since the last chain reset (lost samples)."""
        return self.m.read(RATE_STATUS) & 0x3
