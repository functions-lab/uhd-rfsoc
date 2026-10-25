"""The board's LMK04828 + LMX2594 clock chain: which TICS register files a
build needs (clock_plan, no board access) and writing them through PYNQ's
xrfclk (program_clocks, on the board)."""
import os
import re
import logging
# xrfclk (PYNQ) is imported where the chips are written: it needs $BOARD and
# the board's I2C/SPI, and clock_plan() is used without either (the daemon's
# bitstream scan, off the board)


class ExternalClkConfig:
    def __init__(self, chip, freq_in, freq_out):
        self.chip = chip
        self.freq_in, self.freq_out = freq_in, freq_out
        self.file = None
        self.loc = None
        self.reg = None

    def read_registers(self):
        if not self.loc:
            raise ValueError("File location not set")
        with open(self.loc, 'r') as file:
            reg = [line.rstrip("\n") for line in file]
            self.reg = [int(r.split('\t')[-1], 16) for r in reg]

    def program_clock(self):
        import xrfclk
        if not self.reg:
            raise ValueError("Registers not loaded")

        if isinstance(self, LMK04828ClkConfig):
            devices = xrfclk.lmk_devices
            write_func = xrfclk.xrfclk._write_LMK_regs
        elif isinstance(self, LMX2594ClkConfig):
            devices = xrfclk.lmx_devices
            write_func = xrfclk.xrfclk._write_LMX_regs
        else:
            raise ValueError("Unknown clock type")

        for device in devices:
            write_func(self.reg, device)

    def to_dict(self):
        return {
            'file': self.file,
            'loc': self.loc,
            'chip': self.chip,
            'freq_in': self.freq_in,
            'freq_out': self.freq_out,
            'reg': self.reg
        }


class LMK04828ClkConfig(ExternalClkConfig):
    def __init__(self, chip, freq_in, freq_out, mts_pl_clk_freq=0.0, mts_pl_sysref_freq=0.0):
        super().__init__(chip, freq_in, freq_out)
        self.mts_pl_clk_freq = mts_pl_clk_freq
        self.mts_pl_sysref_freq = mts_pl_sysref_freq

    def to_dict(self):
        return dict(super().to_dict(), mts_pl_clk_freq=self.mts_pl_clk_freq,
                    mts_pl_sysref_freq=self.mts_pl_sysref_freq)


class LMX2594ClkConfig(ExternalClkConfig):
    pass


_LMK_RE = re.compile(r"LMK04828_([0-9.]+)_([0-9.]+)_([0-9.]+)_([0-9.]+)\.txt")
_LMX_RE = re.compile(r"LMX2594_([0-9.]+)_([0-9.]+)\.txt")


def _same(a, b):
    return abs(float(a) - float(b)) < 1e-6


def clock_plan(config_dir, lmx_out, pl_clk, lmk_in=10.0):
    """The clock plan that gives a build its clocks, from the TICS register
    files in `config_dir` (rfsoc_lib/xrfclk/<board>/):

      LMK04828_<lmk_in>_<ref>_<pl_clk>_<sysref>.txt  LMK04828 from its
          <lmk_in> MHz input: <ref> MHz to the LMX2594, the MTS PL clock
          <pl_clk> MHz (the build's MTS_clk_wiz input) and SYSREF <sysref> MHz
      LMX2594_<ref>_<lmx_out>.txt  LMX2594 from <ref> MHz: <lmx_out> MHz to
          the converter tiles (the build's Refclk_Freq)

    Two clock families exist: ref 250 MHz with PL_CLK 300 / SYSREF 10, and
    ref 245.76 MHz with PL_CLK 122.88 / SYSREF 7.68. Frequencies are compared
    as numbers ("250.0" = 250). -> (LMK04828ClkConfig, LMX2594ClkConfig) with
    their files set; FileNotFoundError when no LMK file has this PL clock
    with an LMX file for lmx_out from its reference, ValueError when more
    than one pair does."""
    names = sorted(os.listdir(config_dir))
    plans = []
    for fk in names:
        mk = _LMK_RE.fullmatch(fk)
        if not mk:
            continue
        fin, ref, pl, sysref = (float(v) for v in mk.groups())
        if not (_same(fin, lmk_in) and _same(pl, pl_clk)):
            continue
        for fx in names:
            mx = _LMX_RE.fullmatch(fx)
            if mx and _same(mx.group(1), ref) and _same(mx.group(2), lmx_out):
                lmk = LMK04828ClkConfig("LMK04828", fin, ref, pl, sysref)
                lmx = LMX2594ClkConfig("LMX2594", ref, float(lmx_out))
                lmk.file, lmk.loc = fk, os.path.join(config_dir, fk)
                lmx.file, lmx.loc = fx, os.path.join(config_dir, fx)
                plans.append((lmk, lmx))
    if not plans:
        raise FileNotFoundError(
            f"no clock plan in {config_dir} for PL clock {pl_clk:g} MHz and "
            f"converter clock {float(lmx_out):g} MHz: needs LMK04828_{lmk_in:g}_<ref>_"
            f"{pl_clk:g}_<sysref>.txt and LMX2594_<ref>_{float(lmx_out):g}.txt; there are "
            f"{', '.join(n for n in names if _LMK_RE.fullmatch(n) or _LMX_RE.fullmatch(n))}")
    if len(plans) > 1:
        raise ValueError(f"PL clock {pl_clk:g} MHz, converter clock {float(lmx_out):g} MHz: "
                         f"{len(plans)} clock plans in {config_dir}: "
                         + "; ".join(f"{k.file} + {x.file}" for k, x in plans))
    return plans[0]


def program_clocks(lmk_config, lmx_config):
    """Write the LMK04828 and then the LMX2594 register files (their .loc)
    to every such device xrfclk finds. -> (LMK dict, LMX dict)."""
    import xrfclk
    if not xrfclk.lmk_devices and not xrfclk.lmx_devices:
        xrfclk.xrfclk._find_devices()
    lmk_config.read_registers()
    lmx_config.read_registers()
    lmk_config.program_clock()
    lmx_config.program_clock()
    logging.info(f"clocks programmed: {lmk_config.file} + {lmx_config.file}")
    return lmk_config.to_dict(), lmx_config.to_dict()
