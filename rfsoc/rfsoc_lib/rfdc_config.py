"""The RFDC configuration dict rfdc.py and rfdc_task.py read.

RFDC_CONFIG is the module-global configuration on every board (the daemon
copies the other board's clock limits into it, then its NEW_CONFIG: the
geometry compiled into the loaded bitstream). The keys:

    RefClockForPLL          MHz the LMX2594 makes for the tiles (= fs, PLLs bypassed)
    MTSPLClockFreq          MHz the LMK04828 gives the MTS clocking wizard (300 or 122.88)
    DACSampleRate, ADCSampleRate        MS/s
    DACInterpolationRate, ADCInterpolationRate   the factor (the ADC's is its DECIMATION)
    DACNCO, ADCNCO          MHz (ADC NCO <= 0: real -> I/Q convention)
    DACNyquistZone, ADCNyquistZone, InvSincFIR
    RefClock*Min / *Max     the converters' clock limits (ZCU216_MIN_MAX_CONFIG,
                            RFSOC4X2_MIN_MAX_CONFIG)
"""
import re


class RfdcConfig(dict):
    """The board config dict, readable in both key styles.

    The flat style (DACSampleRate, DACNCO, DACInterpolationRate, ...) is what
    the daemon's NEW_CONFIG sets. The per-tile / per-block style
    (DACSampleRate<t>, DACNCO<t><b>, DACInterpFactor<t><b>,
    ADCDecimFactor<t><b>) addresses one converter tile or block; a key of
    that style that was never set reads its flat counterpart, so code in
    either style sees one configuration.
    """

    _FALLBACK = (
        (re.compile(r"^(DAC|ADC)SampleRate\d$"), lambda m: f"{m.group(1)}SampleRate"),
        (re.compile(r"^(DAC|ADC)NCO\d\d$"), lambda m: f"{m.group(1)}NCO"),
        (re.compile(r"^DACInterpFactor\d\d$"), lambda m: "DACInterpolationRate"),
        (re.compile(r"^ADCDecimFactor\d\d$"), lambda m: "ADCInterpolationRate"),
    )

    def __missing__(self, key):
        if isinstance(key, str):
            for pat, flat in self._FALLBACK:
                m = pat.match(key)
                if m and flat(m) in self:
                    return self[flat(m)]
        raise KeyError(key)


# Gen3 RFDC clock limits (MHz): the tile PLL's reference range, and the
# converter rate when the PLL is bypassed and the tile samples its reference
ZCU216_MIN_MAX_CONFIG = {
    "RefClockForPLLMin": 102.40625,
    "RefClockForPLLMax": 615.0,
    "RefClockNoPLLDacMin": 500.0,
    "RefClockNoPLLDacMax": 10000.0,
    "RefClockNoPLLAdcMin": 500.0,
    "RefClockNoPLLAdcMax": 2500.0
}

# RFSoC 4x2 (ZU48DR): dual-tile RF-ADCs sample at up to 5 GS/s, so a bypassed
# ADC tile takes up to 5000 MHz (the quad-tile ZU49DR's limit is 2500)
RFSOC4X2_MIN_MAX_CONFIG = dict(ZCU216_MIN_MAX_CONFIG, RefClockNoPLLAdcMax=5000.0)

# placeholders until the daemon writes the loaded build's geometry
DEFAULT_CONFIG = {
    "RefClockForPLL": 500.0,
    "DACSampleRate": 2000.0,
    "DACInterpolationRate": 2,
    "DACNCO": 0,
    "DACNyquistZone": 1,
    "InvSincFIR": 1,  # 0: Disable, 1: 1st Nyquist, 2: 2nd Nyquist
    "ADCSampleRate": 2000.0,
    "ADCInterpolationRate": 2,
    "ADCNCO": -0,
    "ADCNyquistZone": 1
}

RFDC_CONFIG = RfdcConfig({**DEFAULT_CONFIG, **ZCU216_MIN_MAX_CONFIG})
