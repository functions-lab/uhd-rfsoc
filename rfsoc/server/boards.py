"""The boards the UHD daemon serves, and where each puts UHD channel c.

One `Board` per board, data only, so hw_backend.py (and rfsoc_lib, which gets
these facts as arguments) names no board. A new board is a new entry in
BOARDS (plus its builds, fpga/boards/<board>/, and its clock register files,
rfsoc_lib/xrfclk/<name>/). Two numberings of an
RF-ADC block exist and must not be mixed:

  IP slice   (tile, slice) of the RFDC IP / .hwh: C_ADC_Slice<t><s>_Enable,
             C_ADC_Decimation_Mode<t><s>, C_ADC_Data_Width<t><s>, m<t><s>_axis.
  API block  (tile, block) the xrfdc driver takes: adc_tiles[t].blocks[b].

On a quad RF-ADC tile (ZU49DR, ZCU216) they coincide. On a dual RF-ADC tile
(ZU48DR, RFSoC 4x2; the RFDC parameter C_High_Speed_ADC) each converter has TWO
IP slices in I/Q mode -- I on slice 2k, Q on slice 2k+1, each its own AXIS
stream of Data_Width samples per clock -- and ONE API block, k: the driver
maps block 1 to the second converter and rejects blocks 2 and 3. RF-DACs
are one slice = one block on both boards.

ZCU216    xczu49dr  channel c: ADC and DAC tile c // 4, block c % 4 (§9)
RFSoC4x2  xczu48dr  ch0: DAC s20 (vout20), ADC tile 2 converter 0 (vin2_01,
                         slices m20 I / m21 Q)
                    ch1: DAC s00 (vout00), ADC tile 0 converter 1 (vin0_23,
                         slices m02 I / m03 Q)
          (fpga/boards/rfsoc4x2/block_designs/rfsoc4x2_uhd_v49/rfsoc4x2_uhd_v49.tcl,
          v49_channel_slices; the PYNQ RFSoC4x2 base overlay enables the same slices)

GT refclk of the 100G CMAC: the ZCU216's comes from the 8A34001 (U409), which
boots unconfigured and is programmed by rfsoc_lib.gt_refclk; the RFSoC 4x2's
is a Si570 at 156.25 MHz from power-up (Board.gt_refclk "si570": left alone).
"""
from __future__ import annotations

import os
import re
from typing import List, Optional, Tuple

Slice = Tuple[int, int]


class Board:
    def __init__(self, name: str, dual_adc: bool, max_channels: int,
                 default_bitstream: str, lib_config: str,
                 masked_tiles: Tuple[int, ...] = (),
                 dac_blocks: Optional[Tuple[Slice, ...]] = None,
                 adc_blocks: Optional[Tuple[Slice, ...]] = None,
                 mts_tiles: int = 0b1111, mts_ref_tile: int = 1,
                 gt_refclk: str = "8a34001"):
        self.name = name                    # rfsoc_lib board name (rfsoc_lib/xrfclk/<name>/)
        self.prefix = name.lower()          # bitstream prefix <prefix>_v49_<N>ch_qsfp*, discovery product=
        self.dual_adc = dual_adc            # dual RF-ADC tiles (I and Q on two IP slices)
        self.max_channels = max_channels
        self.default_bitstream = default_bitstream  # loaded at start when present (the 1ch template)
        self.lib_config = lib_config        # rfdc_config name of its converter clock limits
        # tiles RfdcTask leaves unpowered on this board
        self.masked_tiles = masked_tiles
        # (tile, block) of channel c's DAC and of its ADC (the xrfdc API
        # block); None: tile c // 4, block c % 4 (four blocks per tile)
        self.dac_blocks = dac_blocks
        self.adc_blocks = adc_blocks
        # MTS: the tiles synchronised (bit t = tile t, DAC and ADC) and the
        # reference tile
        self.mts_tiles = mts_tiles
        self.mts_ref_tile = mts_ref_tile
        # the 100G GT refclk: "8a34001" (programmed at bring-up) or "si570"
        # (fixed, runs from power-up: never programmed)
        self.gt_refclk = gt_refclk
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
        return self.dac_blocks[c] if self.dac_blocks else (c // 4, c % 4)

    def adc_block(self, c: int) -> Slice:
        """xrfdc (tile, block) of channel c's ADC."""
        c = self._check(c)
        return self.adc_blocks[c] if self.adc_blocks else (c // 4, c % 4)

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
    "ZCU216": Board("ZCU216", dual_adc=False, max_channels=16,
                    default_bitstream="zcu216_v49_1ch_qsfp_f2_fs2500.bit",   # 1 ch, 1250 MS/s
                    lib_config="ZCU216_MIN_MAX_CONFIG"),
    "RFSOC4X2": Board("RFSoC4x2", dual_adc=True, max_channels=2,
                      default_bitstream="rfsoc4x2_v49_1ch_qsfp_f2_fs5000.bit",   # 1 ch, 2500 MS/s
                      lib_config="RFSOC4X2_MIN_MAX_CONFIG",
                      # only tiles 0 and 2 reach the SMA ports
                      masked_tiles=(1, 3), mts_tiles=0b0101, mts_ref_tile=2,
                      dac_blocks=((2, 0), (0, 0)), adc_blocks=((2, 0), (0, 1)),
                      gt_refclk="si570"),
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
    """$UHD_BOARD (or $UHD_RFSOC_BOARD), else the board of `bitstream`,
    else the one board whose v49 builds are in `directory`, else ZCU216."""
    env = os.environ.get("UHD_BOARD") or os.environ.get("UHD_RFSOC_BOARD")
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
