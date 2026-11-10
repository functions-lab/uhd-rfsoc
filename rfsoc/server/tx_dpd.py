"""eth100g/tx_dpd of the v49 builds (Protocol §12).

Register map: fpga/ip/src/uhd_ip/src/tx_dpd.v (header; packaged as
user.org:uhd:tx_dpd:1.0). AXI-Lite at 0x8008_0000 in every build that has
it (builds from before it have none). The driver is only ever created from
an ip_dict entry named tx_dpd (never from a fallback address: an AXI access
to an unmapped address can hang the PS). Every register answers while the
converter clock is stopped (a retune): only COMMIT / CTRL delivery waits
for it, and the driver gives up on that after a timeout.

Channel c's block is at 0x400*c:
  0x000 CTRL    RW  [0] BYPASS  [1] COMMIT  [2] CLR_STATS  [3] SHADOW_IDENTITY
  0x004 STATUS  RO  [0] bypass in the datapath  [1] COMMIT pending
                    [2] a message pending  [3] datapath reset since the last
                    COMMIT  [15:8] COMMITs applied
  0x008 ID 0x5A443031 'ZD01', 0x00C CONFIG, 0x010 SAT_OUT, 0x014 SAT_GAIN,
  0x018 PEAK [15:0] in [31:16] out, 0x01C TOPO [7:0] N [15:8] SSR [23:16] c
  0x100 + 4k SHADOW word k (k = 2i real, 2i+1 imaginary of coefficient i)
  0x200 + 4k ACTIVE word k

The model, coefficient layout and checks are rfsoc_lib/dsp/dpd.py; this
module only moves numbers into registers.
"""
import logging
import time
from typing import Dict, Optional

import numpy as np

from backend import dpd_lib

dpd = dpd_lib()

log = logging.getLogger("uhd_rfsoc.dpd")

DPD_NAME = "tx_dpd"
DPD_RANGE = 0x10000
COMMIT_TIMEOUT_S = 0.5      # a COMMIT crosses in microseconds while aclk runs


class TxDpd:
    """The tx_dpd registers of a loaded build."""

    def __init__(self, mmio, nch: int):
        self.m, self.nch = mmio, int(nch)
        for c in range(self.nch):
            b = dpd.CH_STRIDE * c
            got = self.m.read(b + dpd.REG_ID)
            if got != dpd.DPD_ID:
                raise RuntimeError(f"tx_dpd ch{c}: ID 0x{got:08x}, expected 0x{dpd.DPD_ID:08x}")
            topo = self.m.read(b + dpd.REG_TOPO)
            if topo & 0xFF != self.nch or (topo >> 16) & 0xFF != c:
                raise RuntimeError(f"tx_dpd ch{c}: TOPO 0x{topo:08x}, the build streams "
                                   f"{self.nch} channels")
        topo = self.m.read(dpd.REG_TOPO)
        self.ssr = (topo >> 8) & 0xFF

    @classmethod
    def from_ip_dict(cls, ip_dict: dict, nch: int, mmio_factory=None) -> Optional["TxDpd"]:
        """The build's DPD, or None if its hwh lists none (a build from before it)."""
        keys = [k for k in (ip_dict or {}) if k == DPD_NAME or k.endswith("/" + DPD_NAME)]
        if not keys:
            return None
        if len(keys) > 1:
            raise RuntimeError(f"several IPs named {DPD_NAME}: {keys}")
        d = ip_dict[keys[0]]
        if mmio_factory is None:
            from pynq import MMIO as mmio_factory  # noqa: N813
        p = cls(mmio_factory(int(d["phys_addr"]), int(d.get("addr_range", DPD_RANGE))), nch)
        log.info("tx_dpd: %s @0x%08x, %d channel(s), %d samples per clock", keys[0],
                 int(d["phys_addr"]), nch, p.ssr)
        return p

    def _reg(self, ch: int, off: int) -> int:
        if not 0 <= ch < self.nch:
            raise ValueError(f"channel {ch} not in 0..{self.nch - 1}")
        return dpd.CH_STRIDE * ch + off

    def _wait(self, ch: int, bit: int, what: str) -> None:
        t_end = time.monotonic() + COMMIT_TIMEOUT_S
        while self.m.read(self._reg(ch, dpd.REG_STATUS)) & bit:
            if time.monotonic() > t_end:
                raise RuntimeError(f"tx_dpd ch{ch}: {what} not applied within "
                                   f"{COMMIT_TIMEOUT_S} s (converter clock stopped?)")
            time.sleep(0.0005)

    def commit(self, ch: int, cq: np.ndarray, enable: bool) -> None:
        """SHADOW <- cq, then COMMIT with BYPASS = not enable: the set and the
        mode change on one beat. Checked: ACTIVE reads back the set. SHADOW
        is written only once no earlier COMMIT is waiting (the RTL takes its
        snapshot when the COMMIT launches: a pending one would carry a torn
        set)."""
        words = dpd.to_words(cq)
        self._wait(ch, dpd.STATUS_MSG_PENDING, "an earlier CTRL / COMMIT")
        for k, w in enumerate(words):
            self.m.write(self._reg(ch, dpd.REG_SHADOW + 4 * k), w)
        self.m.write(self._reg(ch, dpd.REG_CTRL),
                     dpd.CTRL_COMMIT | (0 if enable else dpd.CTRL_BYPASS))
        self._wait(ch, dpd.STATUS_COMMIT_PENDING, "COMMIT")
        got = [self.m.read(self._reg(ch, dpd.REG_ACTIVE + 4 * k)) & ((1 << dpd.COEF_W) - 1)
               for k in range(2 * dpd.NCOEF)]
        if got != words:
            raise RuntimeError(f"tx_dpd ch{ch}: ACTIVE does not read back the committed set")

    def set_enable(self, ch: int, enable: bool) -> None:
        """BYPASS only (the active set is kept)."""
        self.m.write(self._reg(ch, dpd.REG_CTRL), 0 if enable else dpd.CTRL_BYPASS)
        self._wait(ch, dpd.STATUS_MSG_PENDING, "CTRL")

    def clear_stats(self, ch: int) -> None:
        byp = self.m.read(self._reg(ch, dpd.REG_CTRL)) & dpd.CTRL_BYPASS
        self.m.write(self._reg(ch, dpd.REG_CTRL), dpd.CTRL_CLR_STATS | byp)
        self._wait(ch, dpd.STATUS_MSG_PENDING, "CLR_STATS")

    def stats(self, ch: int) -> Dict[str, int]:
        """The datapath's statistics (a snapshot a few us old)."""
        st = self.m.read(self._reg(ch, dpd.REG_STATUS))
        pk = self.m.read(self._reg(ch, dpd.REG_PEAK))
        return {"sat_out": self.m.read(self._reg(ch, dpd.REG_SAT_OUT)),
                "sat_gain": self.m.read(self._reg(ch, dpd.REG_SAT_GAIN)),
                "peak_in": pk & 0xFFFF, "peak_out": pk >> 16,
                "bypass": st & dpd.STATUS_BYPASS, "reset": (st & dpd.STATUS_RESET) >> 3,
                "commits": (st >> 8) & 0xFF}

    def read_active(self, ch: int) -> np.ndarray:
        return dpd.from_words([self.m.read(self._reg(ch, dpd.REG_ACTIVE + 4 * k))
                               for k in range(2 * dpd.NCOEF)])
