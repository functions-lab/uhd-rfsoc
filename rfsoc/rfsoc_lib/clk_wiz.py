"""clk_wiz.py -- run-time retune of a Clocking Wizard (clk_wiz 6.0) MMCM over
its AXI4-Lite dynamic-reconfiguration interface (PG065; the IP built with
USE_DYN_RECONFIG, which shares s_axi_lite with the clock monitor).

Register map (byte offsets):
  0x000 SRR   write 0xA: reset. The register file returns to the BUILD setting,
              so a caller that resets the MMCM (MyMTS.init_tile_sync) must
              program it again afterwards.
  0x004 SR    [0] locked
  0x200 CFG0  [7:0] DIVCLK_DIVIDE  [15:8] CLKFBOUT_MULT  [25:16] its fraction
              in 1/1000  [26] fraction enable
  0x208 CFG2  [7:0] CLKOUT0_DIVIDE  [17:8] its fraction  [18] fraction enable
  0x25C LOAD  [0] load  [1] SADDR (1: from the register file)

The output must be exact (the converter AXIS clock equals Fabric_Freq), so
the setting is solved exactly, as v49_clk_exact does at build time: VCO =
fin x M / D with M and CLKOUT0's O in 1/8 steps, VCO 800..1600 MHz, PFD >= 10
MHz. Measured on zcu216-0 (2026-10-14): relock in ~5 ms, every factor of the
1ch template 312.5 .. 15.625 MHz.
"""
import time

CW_SRR, CW_SR, CW_CFG0, CW_CFG2, CW_LOAD = 0x000, 0x004, 0x200, 0x208, 0x25C
VCO_MIN, VCO_MAX, PFD_MIN = 800.0, 1600.0, 10.0


def mmcm_exact(fout, fin):
    """-> (D, M, O, VCO MHz) giving exactly `fout` MHz from `fin` MHz, the
    first in (D up, O up) order; ValueError if there is none."""
    for d in range(1, 31):
        if fin / d < PFD_MIN:
            break
        for o8 in range(8, 1025):
            vco = fout * o8 / 8.0
            if vco < VCO_MIN or vco > VCO_MAX:
                continue
            m8 = vco * d * 8.0 / fin
            if abs(m8 - round(m8)) > 1e-6 or m8 < 16 or m8 > 1024:
                continue
            return d, round(m8) / 8.0, o8 / 8.0, vco
    raise ValueError(f"no exact MMCM setting for {fout} MHz from {fin} MHz")


def _frac(x):
    return int(round((x - int(x)) * 1000))


class ClkWiz:
    """One clk_wiz instance (`mmio`: its pynq MMIO; `fin`: CLKIN1 in MHz)."""

    def __init__(self, mmio, fin):
        self.mmio, self.fin = mmio, float(fin)

    def locked(self):
        return bool(self.mmio.read(CW_SR) & 1)

    def setting(self):
        """(D, M, O) in the register file."""
        c0, c2 = self.mmio.read(CW_CFG0), self.mmio.read(CW_CFG2)
        d = c0 & 0xFF
        m = ((c0 >> 8) & 0xFF) + (((c0 >> 16) & 0x3FF) / 1000.0 if c0 >> 26 & 1 else 0.0)
        o = (c2 & 0xFF) + (((c2 >> 8) & 0x3FF) / 1000.0 if c2 >> 18 & 1 else 0.0)
        return d, m, o

    def freq(self):
        """clk_out1 in MHz as the register file says (not a measurement)."""
        d, m, o = self.setting()
        return self.fin * m / d / o if d and o else 0.0

    def program(self, fout, timeout=2.0):
        """Write the exact setting for `fout` MHz, load it, wait for lock.
        -> {d, m, o, vco, lock_ms}; RuntimeError if it does not lock."""
        d, m, o, vco = mmcm_exact(fout, self.fin)
        mf, of = _frac(m), _frac(o)
        self.mmio.write(CW_CFG0, d | (int(m) << 8) | (mf << 16) | ((1 if mf else 0) << 26))
        self.mmio.write(CW_CFG2, int(o) | (of << 8) | ((1 if of else 0) << 18))
        self.mmio.write(CW_LOAD, 0x3)
        t0 = time.monotonic()
        # the reconfiguration state machine takes the MMCM out of lock a few
        # AXI clocks after LOAD: right after the write SR still says locked
        time.sleep(0.002)
        while not self.locked():
            if time.monotonic() - t0 > timeout:
                raise RuntimeError(f"MMCM did not lock at {fout:g} MHz "
                                   f"(D {d} M {m} O {o}, VCO {vco:g} MHz)")
            time.sleep(0.002)
        return {"d": d, "m": m, "o": o, "vco": vco,
                "lock_ms": round(1e3 * (time.monotonic() - t0), 1)}
