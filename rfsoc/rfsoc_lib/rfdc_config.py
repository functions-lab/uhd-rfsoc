import re


def merge_dict(dict1, dict2):
    dict2.update(dict1)
    return dict2


class RfdcConfig(dict):
    """The board config dict, readable in both key styles.

    Two styles meet here. The flat one (DACSampleRate, DACNCO,
    DACInterpolationRate, ...) is what NEW_CONFIG dicts and the agentic and
    UHD flows set. The per-tile/per-block one (DACSampleRate<t>,
    DACNCO<t><b>, DACInterpFactor<t><b>, ADCDecimFactor<t><b>) is what the
    config/<board>/*.json files and the v47 beamforming code use. A
    per-tile/per-block key that was never set reads its flat counterpart, so
    code in either style sees one configuration.

    LOGGER (the shared TxtLogger) is created on first use, so importing the
    config does not create a wave_files directory.
    """

    _FALLBACK = (
        (re.compile(r"^(DAC|ADC)SampleRate\d$"), lambda m: f"{m.group(1)}SampleRate"),
        (re.compile(r"^(DAC|ADC)NCO\d\d$"), lambda m: f"{m.group(1)}NCO"),
        (re.compile(r"^DACInterpFactor\d\d$"), lambda m: "DACInterpolationRate"),
        (re.compile(r"^ADCDecimFactor\d\d$"), lambda m: "ADCInterpolationRate"),
    )

    def __missing__(self, key):
        if key == "LOGGER":
            from rfsoc_lib.txt_logger import TxtLogger
            self["LOGGER"] = TxtLogger(log_dir="wave_files")
            return self["LOGGER"]
        if isinstance(key, str):
            for pat, flat in self._FALLBACK:
                m = pat.match(key)
                if m and flat(m) in self:
                    return self[flat(m)]
        raise KeyError(key)


ZCU216_MIN_MAX_CONFIG = {
    "RefClockForPLLMin": 102.40625,
    "RefClockForPLLMax": 615.0,
    "RefClockNoPLLDacMin": 500.0,
    "RefClockNoPLLDacMax": 10000.0,
    "RefClockNoPLLAdcMin": 500.0,
    "RefClockNoPLLAdcMax": 2500.0
}

ZCU216_DEMO3_CONFIG = {
    "RefClockForPLL": 500.0,
    "DACSampleRate": 4000.0,
    "DACInterpolationRate": 4,
    "DACNCO": 1000,
    "ADCSampleRate": 2000.0,
    "ADCInterpolationRate": 2,
    "ADCNCO": -1000
}

ZCU216_DEMO2_CONFIG = {
    "RefClockForPLL": 500.0,
    "DACSampleRate": 5000.0,
    "DACInterpolationRate": 20,
    "DACNCO": 425,
    "ADCSampleRate": 2500.0,
    "ADCInterpolationRate": 10,
    "ADCNCO": -425
}

ZCU216_DEMO1_CONFIG = {
    "RefClockForPLL": 500.0,
    "DACSampleRate": 4000.0,
    "DACInterpolationRate": 40,
    "DACNCO": 350,
    "ADCSampleRate": 2000.0,
    "ADCInterpolationRate": 20,
    "ADCNCO": -350
}

ZCU216_DEFAULT_CONFIG = {
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

GLOBAL_VAR = {
    "CONFIG_NAME": "default_config",
    "BB_GAIN": 1.0  # Baseband gain
}

EXP_CONFIG = {
    "QAM": "16QAM",
    "OFDM_ATTEN_DB": 0,
    "UsrpNameIfAny": "X310_322A005",
    "UsrpRx": "RFA_RX2",
    "ExternalAtten": 0.0,
    "UseSplitter": False,
    "SplitterType": "1-to-2",
    "BalunMode": "BALH0006",
    "BalunMin": 0.2,
    "BalunMax": 60,
}

ZCU216_CONFIG = merge_dict(ZCU216_MIN_MAX_CONFIG, ZCU216_DEFAULT_CONFIG)
ZCU216_CONFIG = merge_dict(ZCU216_CONFIG, GLOBAL_VAR)
ZCU216_CONFIG = RfdcConfig(merge_dict(ZCU216_CONFIG, EXP_CONFIG))

# RFSoC4x2 has 2 DAC tiles (228, 230) and 2 ADC tiles (224, 226) physically
# wired to SMA. Sample-rate / NCO defaults mirror ZCU216 — override per design.
RFSOC4X2_MIN_MAX_CONFIG = {
    "RefClockForPLLMin": 102.40625,
    "RefClockForPLLMax": 615.0,
    "RefClockNoPLLDacMin": 500.0,
    "RefClockNoPLLDacMax": 10000.0,
    "RefClockNoPLLAdcMin": 500.0,
    "RefClockNoPLLAdcMax": 4000.0,
}

RFSOC4X2_DEFAULT_CONFIG = {
    "RefClockForPLL": 500.0,
    "DACSampleRate": 2000.0,
    "DACInterpolationRate": 2,
    "DACNCO": 0,
    "DACNyquistZone": 1,
    "InvSincFIR": 1,
    "ADCSampleRate": 2000.0,
    "ADCInterpolationRate": 2,
    "ADCNCO": -0,
    "ADCNyquistZone": 1,
}

RFSOC4X2_CONFIG = merge_dict(RFSOC4X2_MIN_MAX_CONFIG, RFSOC4X2_DEFAULT_CONFIG)
RFSOC4X2_CONFIG = merge_dict(RFSOC4X2_CONFIG, GLOBAL_VAR)
RFSOC4X2_CONFIG = RfdcConfig(merge_dict(RFSOC4X2_CONFIG, EXP_CONFIG))


# ZCU208 (xczu48dr) carries the same LMK04828 + LMX2594 clock chain as ZCU216
# but exposes only 2 DAC tiles (228, 230) and 2 ADC tiles (224, 226).
# Sample-rate / NCO defaults mirror ZCU216 — override per design.
ZCU208_MIN_MAX_CONFIG = {
    "RefClockForPLLMin": 102.40625,
    "RefClockForPLLMax": 615.0,
    "RefClockNoPLLDacMin": 500.0,
    "RefClockNoPLLDacMax": 10000.0,
    "RefClockNoPLLAdcMin": 500.0,
    # dual-tile RF-ADC (ZU48DR): 5 GS/s, so a bypassed tile takes up to
    # 5000 MHz (the quad-tile ZU49DR's limit is 2500)
    "RefClockNoPLLAdcMax": 5000.0,
}

ZCU208_DEFAULT_CONFIG = {
    "RefClockForPLL": 500.0,
    "DACSampleRate": 2000.0,
    "DACInterpolationRate": 2,
    "DACNCO": 0,
    "DACNyquistZone": 1,
    "InvSincFIR": 1,
    "ADCSampleRate": 2000.0,
    "ADCInterpolationRate": 2,
    "ADCNCO": -0,
    "ADCNyquistZone": 1,
}

ZCU208_CONFIG = merge_dict(ZCU208_MIN_MAX_CONFIG, ZCU208_DEFAULT_CONFIG)
ZCU208_CONFIG = merge_dict(ZCU208_CONFIG, GLOBAL_VAR)
ZCU208_CONFIG = RfdcConfig(merge_dict(ZCU208_CONFIG, EXP_CONFIG))


BOARD_CONFIGS = {
    "ZCU216": ZCU216_CONFIG,
    "ZCU208": ZCU208_CONFIG,
    "RFSoC4x2": RFSOC4X2_CONFIG,
}


def get_board_config(board: str) -> dict:
    """Return the RFDC config dict for the named board.

    Raises KeyError if the board is unsupported.
    """
    try:
        return BOARD_CONFIGS[board]
    except KeyError:
        raise KeyError(
            f"Unsupported board '{board}'. Choose from: {list(BOARD_CONFIGS)}"
        )
