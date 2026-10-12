"""The boards the UHD daemon serves, and where each puts UHD channel c.

One table per board, so hw_backend.py names no board. Two numberings of an
RF-ADC block exist and must not be mixed:

  IP slice   (tile, slice) of the RFDC IP / .hwh: C_ADC_Slice<t><s>_Enable,
             C_ADC_Decimation_Mode<t><s>, C_ADC_Data_Width<t><s>, m<t><s>_axis.
  API block  (tile, block) the xrfdc driver takes: adc_tiles[t].blocks[b].

On a quad RF-ADC tile (ZU49DR, ZCU216) they coincide. On a dual RF-ADC tile
(ZU48DR, ZCU208; the RFDC parameter C_High_Speed_ADC) each converter has TWO
IP slices in I/Q mode -- I on slice 2k, Q on slice 2k+1, each its own AXIS
stream of Data_Width samples per clock -- and ONE API block, k: the driver
maps block 1 to the second converter and rejects blocks 2 and 3. RF-DACs
are one slice = one block on both boards.

ZCU216  xczu49dr  channel c: ADC and DAC tile c // 4, block c % 4 (§9)
ZCU208  xczu48dr  ch0: DAC s20 (vout20), ADC tile 2 converter 0 (vin2_01,
                       slices m20 I / m21 Q)
                  ch1: DAC s00 (vout00), ADC tile 0 converter 1 (vin0_23,
                       slices m02 I / m03 Q)
        (hw_design/ZCU208/block_designs/zcu208_v49_qsfp/zcu208_v49_qsfp.tcl, v49_channel_slices; the
        ZCU208 v49 port is BUILT BUT NOT BOARD-TESTED -- hw_design/ZCU208/CLAUDE.md)
"""
from __future__ import annotations

import os
import re
from typing import List, Optional, Tuple

Slice = Tuple[int, int]


class Board:
    def __init__(self, name: str, dual_adc: bool, max_channels: int,
                 masked_tiles: Tuple[int, ...], default_bitstream: str,
                 lib_config: str, mts_note: str):
        self.name = name                    # rfsoc_lib board name (RfdcTask, MyMTS, xrfclk/<name>)
        self.prefix = name.lower()          # bitstream prefix: <prefix>_v49_<N>ch_qsfp*
        self.dual_adc = dual_adc
        self.max_channels = max_channels
        # tiles RfdcTask leaves unpowered on this board (set_board_rules)
        self.masked_tiles = masked_tiles
        self.default_bitstream = default_bitstream
        self.lib_config = lib_config        # rfdc_config name of its limits
        self.mts_note = mts_note
        self.bitstream_glob = f"{self.prefix}_v49_*ch_qsfp*.bit"
        self.bitstream_re = re.compile(rf"^{self.prefix}_v49_([0-9]+)ch_qsfp(?:_.*)?$")

    # -- channel map ------------------------------------------------------------
    def _check(self, c: int) -> int:
        c = int(c)
        if not 0 <= c < self.max_channels:
            raise ValueError(f"{self.name}: channel {c} not in 0..{self.max_channels - 1}")
        return c

    def dac_slice(self, c: int) -> Slice:
        """DAC (tile, block) of channel c (IP slice = API block)."""
        c = self._check(c)
        if self.name == "ZCU208":
            return ((2, 0), (0, 0))[c]
        return (c // 4, c % 4)

    def adc_block(self, c: int) -> Slice:
        """xrfdc (tile, block) of channel c's ADC."""
        c = self._check(c)
        if self.name == "ZCU208":
            return ((2, 0), (0, 1))[c]
        return (c // 4, c % 4)

    def adc_slices(self, c: int) -> List[Slice]:
        """The IP slices carrying channel c's ADC stream: [I, Q] on a dual
        tile, [the one interleaved I/Q slice] on a quad tile."""
        t, b = self.adc_block(c)
        return [(t, 2 * b), (t, 2 * b + 1)] if self.dual_adc else [(t, b)]

    def api_block(self, s: Slice) -> Slice:
        """IP slice -> the xrfdc API block that owns it."""
        t, b = s
        return (t, b // 2) if self.dual_adc else (t, b)

    def adc_samples_per_clock(self, data_width: int) -> float:
        """Complex samples per fabric clock of one ADC slice of Data_Width
        words: I and Q on separate slices (dual), else interleaved."""
        return float(data_width) if self.dual_adc else data_width / 2.0

    # -- bitstreams -------------------------------------------------------------
    def name_channels(self, name: str) -> Optional[int]:
        m = self.bitstream_re.match(os.path.splitext(os.path.basename(name))[0])
        return int(m.group(1)) if m else None


BOARDS = {
    "ZCU216": Board("ZCU216", dual_adc=False, max_channels=16, masked_tiles=(),
                    default_bitstream="zcu216_v49_1ch_qsfp_f2_fs2500.bit",   # 1 ch, 1250 MS/s
                    lib_config="ZCU216_MIN_MAX_CONFIG",
                    mts_note="the first attempt after a reboot fails on zcu216-0"),
    "ZCU208": Board("ZCU208", dual_adc=True, max_channels=2, masked_tiles=(1, 3),
                    default_bitstream="zcu208_v49_1ch_qsfp_f2_fs5000.bit",   # 1 ch, 2500 MS/s
                    lib_config="ZCU208_MIN_MAX_CONFIG",
                    mts_note="not yet measured on a ZCU208"),
}
DEFAULT_BOARD = "ZCU216"


def get_board(name: Optional[str]) -> Board:
    key = (name or DEFAULT_BOARD).upper()
    if key not in BOARDS:
        raise ValueError(f"unknown board {name!r}; known: {', '.join(BOARDS)}")
    return BOARDS[key]


def board_of_bitstream(name: str) -> Optional[Board]:
    """The board whose v49 naming `name` follows, None for any other name."""
    for b in BOARDS.values():
        if b.name_channels(name) is not None:
            return b
    return None


def detect_board(directory: str, bitstream: Optional[str] = None) -> Board:
    """$UHD_BOARD (or $ZCU216_UHD_BOARD), else the board of `bitstream`,
    else the one board whose v49 builds are in `directory`, else ZCU216."""
    env = os.environ.get("UHD_BOARD") or os.environ.get("ZCU216_UHD_BOARD")
    if env:
        return get_board(env)
    if bitstream:
        b = board_of_bitstream(bitstream)
        if b is not None:
            return b
    import glob
    found = [b for b in BOARDS.values()
             if glob.glob(os.path.join(directory, b.bitstream_glob))]
    if len(found) == 1:
        return found[0]
    if len(found) > 1:
        raise ValueError(f"{directory} holds v49 builds of "
                         f"{', '.join(b.name for b in found)}: pass --board")
    return BOARDS[DEFAULT_BOARD]
