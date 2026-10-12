"""Hardware backend: the real ZCU216 running a zcu216_v49_{N}ch_qsfp build.

RFDC bring-up is the proven pattern of hw_design/ZCU216/CLAUDE.md, nothing else:

  1. RFSoCOverlay(bitstream)
  2. NEW_CONFIG carrying the COMPILED geometry, read from the .hwh (sampling
     rates, reference clock, ADC decimation / DAC interpolation of every
     enabled slice) -- never a run-time factor
  3. RfdcTask(ol, ...).start(); .join()
  4. print the DAC interp / ADC decim readback of EVERY enabled block and the
     PLL-lock / tile-state readback of every enabled tile, and refuse to run
     if a factor differs from the compiled one or a tile clock is not good
     (unless --allow-unlocked).

No retry ladder, no hand-rolled PLL or MTS calls. After bring-up the daemon
only touches: the fine-mixer NCO and Nyquist zone (set_*_freq), the ADC DSA
(set_rx_gain), the DAC VOP (set_tx_gain, only if the IP was built with VOP),
and the eth100g registers (eth100g.py, tx_beamformer.py, rx_beamformer.py).

Sample-rate variants are SEPARATE BITSTREAMS (zcu216_v49_<N>ch_qsfp[_f<F>]):
the converter factor is a block-design parameter, never a run-time one. So is
the channel count N: every zcu216_v49_{N}ch_qsfp*.bit (N = 1, 2, 4, 8, 16)
streams the first N channels, channel c = RFDC tile c // 4, block c % 4
(PROTOCOL.md §9). `scan_bitstreams()` reads N from the name and from each
.hwh the compiled factor, the fabric beat, udp_streamer/udp_player TICK_STEP
(so the build's own tick rate), the TX buffer, the tx_beamformer and the
rx_beamformer;
set_rx_rate/set_tx_rate (within one N) and set_channels (that N's sc16-max
build) reload that overlay and redo the WHOLE bring-up above (`_switch_to`).
The DAC is always fed by the UDP player (the DRAM/DMA path is gone).

The same daemon serves the ZCU208 (zcu208_v49_<N>ch_qsfp*, N = 1, 2; dual
RF-ADC tiles, channel map in boards.py). Everything board-specific -- the
bitstream names, which slices carry channel c, the IP-slice / xrfdc-block
numbering of a dual ADC tile, the rfsoc_lib board name -- comes from the
`Board` the backend is given; this file names no board. The ZCU208 path is
built but NOT board-tested (hw_design/ZCU208/CLAUDE.md).
"""
from __future__ import annotations

import glob
import logging
import os
import sys
import threading
import time
import xml.etree.ElementTree as ET
from typing import Dict, List, Optional, Tuple

from backend import (Backend, BackendError, default_fc_interval, DSA_MAX_DB,
                     DSA_STEP_DB, bool_sensor,
                     coerce_nco, default_rate, find_lib_root, gain_for_vop_ua,
                     nyquist_plan, read_sysmon_temp, v49_tick_step,
                     vop_ua_for_gain)
from boards import Board, board_of_bitstream, get_board
from rx_beamformer import RxBeamformer, default_shift
from tx_beamformer import TxBeamformer
import vrt

log = logging.getLogger("zcu216.hw")

PLL_LOCKED = 2            # XRFDC_PLL_LOCKED; 1 = XRFDC_PLL_UNLOCKED
TILE_STATE_DONE = 15


# --------------------------------------------------------------------------
# Compiled geometry from the .hwh
# --------------------------------------------------------------------------

class Geometry:
    """RFDC configuration compiled into the bitstream (from ip_dict params)."""

    def __init__(self, params: Dict[str, str], board: Optional[Board] = None):
        self.p = params
        # dual RF-ADC tiles (ZU48DR): I and Q of a converter on two slices,
        # each Data_Width samples per clock. The .hwh says so; without the
        # parameter (an older or synthetic .hwh) the board does.
        if "C_High_Speed_ADC" in params or "High_Speed_ADC" in params:
            self.dual_adc = self._bool("C_High_Speed_ADC")
        else:
            self.dual_adc = bool(board.dual_adc) if board is not None else False
        self.adc_slices = [(t, b) for t in range(4) for b in range(4)
                           if self._bool(f"C_ADC_Slice{t}{b}_Enable")]
        self.dac_slices = [(t, b) for t in range(4) for b in range(4)
                           if self._bool(f"C_DAC_Slice{t}{b}_Enable")]
        if not self.adc_slices or not self.dac_slices:
            raise RuntimeError(f"hwh lists no enabled ADC ({self.adc_slices}) "
                               f"or DAC ({self.dac_slices}) slice")
        self.adc_decim = {s: self._int(f"C_ADC_Decimation_Mode{s[0]}{s[1]}")
                          for s in self.adc_slices}
        self.dac_interp = {s: self._int(f"C_DAC_Interpolation_Mode{s[0]}{s[1]}")
                           for s in self.dac_slices}
        self.adc_width = {s: self._int(f"C_ADC_Data_Width{s[0]}{s[1]}")
                          for s in self.adc_slices}
        self.dac_width = {s: self._int(f"C_DAC_Data_Width{s[0]}{s[1]}")
                          for s in self.dac_slices}
        adc_tiles = sorted({t for t, _ in self.adc_slices})
        dac_tiles = sorted({t for t, _ in self.dac_slices})
        self.adc_fs = {t: 1e9 * self._float(f"C_ADC{t}_Sampling_Rate") for t in adc_tiles}
        self.dac_fs = {t: 1e9 * self._float(f"C_DAC{t}_Sampling_Rate") for t in dac_tiles}
        self.adc_ref = {t: self._float(f"C_ADC{t}_Refclk_Freq") for t in adc_tiles}
        self.dac_ref = {t: self._float(f"C_DAC{t}_Refclk_Freq") for t in dac_tiles}
        self.adc_pll = {t: self._bool(f"C_ADC{t}_PLL_Enable") for t in adc_tiles}
        self.dac_pll = {t: self._bool(f"C_DAC{t}_PLL_Enable") for t in dac_tiles}
        self.adc_fabric = {t: self._float(f"C_ADC{t}_Fabric_Freq") for t in adc_tiles}
        self.dac_fabric = {t: self._float(f"C_DAC{t}_Fabric_Freq") for t in dac_tiles}
        self.vop_mode = self.p.get("C_DAC_VOP_Mode", "0") in ("1", "true")

    def _raw(self, k):
        if k in self.p:
            return self.p[k]
        k2 = k[2:] if k.startswith("C_") else "C_" + k
        if k2 in self.p:
            return self.p[k2]
        raise KeyError(f"RFDC parameter {k} not in hwh")

    def _bool(self, k):
        try:
            return str(self._raw(k)).lower() in ("true", "1")
        except KeyError:
            return False

    def _int(self, k):
        return int(float(self._raw(k)))

    def _float(self, k):
        return float(self._raw(k))

    def check(self) -> List[str]:
        """Consistency of the compiled design. Returns a list of problems."""
        bad = []
        decims = set(self.adc_decim.values())
        interps = set(self.dac_interp.values())
        if len(decims) != 1:
            bad.append(f"ADC decimation differs across enabled slices: {self.adc_decim}")
        if len(interps) != 1:
            bad.append(f"DAC interpolation differs across enabled slices: {self.dac_interp}")
        if len(set(self.adc_fs.values())) != 1 or len(set(self.dac_fs.values())) != 1:
            bad.append(f"sampling rate differs across tiles: ADC {self.adc_fs} DAC {self.dac_fs}")
        refs = set(self.adc_ref.values()) | set(self.dac_ref.values())
        if len(refs) != 1:
            bad.append(f"RfdcTask programs ONE LMX frequency, but the tiles "
                       f"want {sorted(refs)} MHz")
        # Fabric_Freq = SampleRate / factor / (complex samples per clock):
        # Data_Width / 2 on an interleaved I/Q slice (CLAUDE.md), Data_Width
        # on a dual-tile ADC slice that carries I or Q alone
        for (t, b), d in self.adc_decim.items():
            w = self.adc_width[(t, b)]
            spc = self.adc_spc(w)
            want = self.adc_fs[t] / 1e6 / d / spc
            if abs(want - self.adc_fabric[t]) > 0.01:
                bad.append(f"ADC{t}{b}: Fabric_Freq {self.adc_fabric[t]} != "
                           f"{self.adc_fs[t]/1e6}/{d}/{spc:g} = {want:.3f} MHz")
        for (t, b), d in self.dac_interp.items():
            w = self.dac_width[(t, b)]
            want = self.dac_fs[t] / 1e6 / d / (w / 2.0)
            if abs(want - self.dac_fabric[t]) > 0.01:
                bad.append(f"DAC{t}{b}: Fabric_Freq {self.dac_fabric[t]} != "
                           f"{self.dac_fs[t]/1e6}/{d}/({w}/2) = {want:.3f} MHz")
        return bad

    def adc_spc(self, data_width: int) -> float:
        """Complex samples per fabric clock of one ADC slice."""
        return float(data_width) if self.dual_adc else data_width / 2.0

    @property
    def decim(self) -> int:
        return next(iter(self.adc_decim.values()))

    @property
    def interp(self) -> int:
        return next(iter(self.dac_interp.values()))

    @property
    def fs_adc(self) -> float:
        return next(iter(self.adc_fs.values()))

    @property
    def fs_dac(self) -> float:
        return next(iter(self.dac_fs.values()))

    @property
    def refclk(self) -> float:
        return next(iter(self.adc_ref.values()))

    def summary(self) -> str:
        return (f"ADC ({'dual' if self.dual_adc else 'quad'} tiles) slices "
                f"{self.adc_slices} fs {self.fs_adc/1e6:.3f} MHz decim "
                f"{self.adc_decim} width {self.adc_width} fabric {self.adc_fabric} "
                f"PLL {self.adc_pll}; DAC slices {self.dac_slices} fs "
                f"{self.fs_dac/1e6:.3f} MHz interp {self.dac_interp} PLL "
                f"{self.dac_pll}; refclk {self.refclk} MHz; VOP {self.vop_mode}")


def _rfdc_params(ol) -> Tuple[str, Dict[str, str]]:
    keys = [k for k in ol.ip_dict if k.endswith("usp_rf_data_converter")]
    if len(keys) != 1:
        raise RuntimeError(f"expected one usp_rf_data_converter, found {keys}")
    return keys[0], ol.ip_dict[keys[0]]["parameters"]


HWH_CORES = ("udp_streamer", "udp_player", "tx_beamformer", "rx_beamformer")


def _overlay_cores(ol) -> Dict[str, Dict[str, str]]:
    """HWH_CORES parameters from a loaded overlay's ip_dict (no .hwh file at
    hand): keys ending in /<core>."""
    out = {}
    for core in HWH_CORES:
        keys = [k for k in ol.ip_dict if k == core or k.endswith("/" + core)]
        if len(keys) == 1:
            out[core] = dict(ol.ip_dict[keys[0]].get("parameters", {}))
    return out


def hwh_params(hwh_path: str) -> Tuple[Dict[str, str], Dict[str, Dict[str, str]]]:
    """-> (RFDC PARAMETERs, {core: PARAMETERs} of the eth100g cores in
    HWH_CORES that the design has), straight from a .hwh file, no pynq: the
    same NAME/VALUE pairs PYNQ puts in ip_dict[...]["parameters"]."""
    rfdc, cores = [], {}
    for m in ET.parse(hwh_path).iter("MODULE"):
        mt = m.get("MODTYPE")
        if mt == "usp_rf_data_converter":
            rfdc.append(m)
        elif mt in HWH_CORES:
            if mt in cores:
                raise ValueError(f"{os.path.basename(hwh_path)}: two {mt} cores")
            cores[mt] = _module_params(m)
    if len(rfdc) != 1:
        raise ValueError(f"{os.path.basename(hwh_path)}: expected one "
                         f"usp_rf_data_converter MODULE, found {len(rfdc)}")
    return _module_params(rfdc[0]), cores


def _module_params(m) -> Dict[str, str]:
    params = m.find("PARAMETERS")
    return {p.get("NAME"): p.get("VALUE") for p in
            (params if params is not None else []) if p.get("NAME")}


def hwh_rfdc_params(hwh_path: str) -> Dict[str, str]:
    """RFDC PARAMETERs of a .hwh (see hwh_params)."""
    return hwh_params(hwh_path)[0]


# --------------------------------------------------------------------------
# Bitstream variants (one per channel count and converter factor)
# --------------------------------------------------------------------------

# <board>_v49_<N>ch_qsfp[_<variant>]: N channels streamed over the 100G path
# (Board.bitstream_glob / bitstream_re, boards.py)


def name_channels(name: str, board: Optional[Board] = None) -> Optional[int]:
    """N from a <board>_v49_<N>ch_qsfp* name (of `board`, else of any board),
    None for any other name."""
    if board is not None:
        return board.name_channels(name)
    b = board_of_bitstream(name)
    return b.name_channels(name) if b is not None else None


def stream_slices(geo: Geometry, nch: int, board: Board
                  ) -> Tuple[List[Tuple[int, int]], List[Tuple[int, int]]]:
    """-> (rx, tx): the xrfdc (tile, block) of the ADC and of the DAC of UHD
    channels 0..nch-1 (boards.py; ZCU216: tile c // 4, block c % 4, §9).
    RuntimeError unless the compiled design enables every IP slice they need:
    the DAC slice and the ADC slice(s) -- I and Q, on a dual ADC tile."""
    if not 1 <= nch <= board.max_channels:
        raise RuntimeError(f"{nch} channels: not in 1..{board.max_channels} "
                           f"on {board.name}")
    if geo.dual_adc != board.dual_adc:
        raise RuntimeError(f"the .hwh says {'dual' if geo.dual_adc else 'quad'} "
                           f"RF-ADC tiles, the {board.name} has "
                           f"{'dual' if board.dual_adc else 'quad'} ones: a build "
                           f"for another board")
    want_adc = [s for c in range(nch) for s in board.adc_slices(c)]
    want_dac = [board.dac_slice(c) for c in range(nch)]
    miss_adc = [s for s in want_adc if s not in geo.adc_slices]
    miss_dac = [s for s in want_dac if s not in geo.dac_slices]
    if miss_adc or miss_dac:
        raise RuntimeError(f"{nch}-channel stream needs ADC slices {want_adc} and "
                           f"DAC slices {want_dac}; not enabled: ADC {miss_adc} "
                           f"DAC {miss_dac}")
    return [board.adc_block(c) for c in range(nch)], want_dac


def _core_int(cores: Dict[str, Dict[str, str]], core: str, key: str) -> Optional[int]:
    v = cores.get(core, {}).get(key)
    if v is None:
        return None
    try:
        return int(float(v))
    except ValueError:
        raise RuntimeError(f"{core} {key} = {v!r} is not a number")


class Variant:
    """One bitstream and what its .hwh (and its name, for the channel count)
    says was compiled into it.

    Per build, all from the .hwh (never from a table keyed by N): F, the
    per-channel rate fs/F, the fabric beat (N x Data_Width/2 slots, checked
    against udp_streamer S_WIDTH), TICK_STEP (udp_streamer, = udp_player's)
    and so the UHD tick rate = aggregate slot rate x TICK_STEP, the TX buffer
    depth, and whether it has a TX beamformer (tx_beamformer, N_CH = N) and
    an RX beamformer (rx_beamformer, N_CH = N; not in the older builds). Two
    builds of one N can have different tick rates (4ch: 3.0 GHz at 750 MS/s,
    5.0 GHz at 1250 MS/s). A .hwh without the cores (a synthetic test file)
    gets v49_geometry's TICK_STEP (backend.v49_tick_step)."""

    def __init__(self, bitstream: str, geo: Geometry, nch: Optional[int] = None,
                 cores: Optional[Dict[str, Dict[str, str]]] = None,
                 board: Optional[Board] = None):
        self.board = board or board_of_bitstream(bitstream) or get_board(None)
        self.bitstream = os.path.abspath(bitstream)
        self.hwh = os.path.splitext(self.bitstream)[0] + ".hwh"
        self.name = os.path.splitext(os.path.basename(bitstream))[0]
        self.geo = geo
        cores = cores or {}
        self.nch = int(nch if nch is not None
                       else (self.board.name_channels(self.name) or 1))
        self.rx_blocks, self.tx_slices = stream_slices(geo, self.nch, self.board)
        adc_sl = [s for c in range(self.nch) for s in self.board.adc_slices(c)]
        spc = {geo.adc_spc(geo.adc_width[s]) for s in adc_sl}
        dac_spc = {geo.dac_width[s] / 2.0 for s in self.tx_slices}
        if len(spc) != 1 or spc != dac_spc:
            raise RuntimeError(f"streamed slices differ in samples per clock: ADC "
                               f"Data_Width { {s: geo.adc_width[s] for s in adc_sl} } "
                               f"DAC Data_Width { {s: geo.dac_width[s] for s in self.tx_slices} }")
        # one fabric beat = N channels x complex samples per clock = slots
        # (ADC Data_Width/2 on a quad tile, Data_Width on a dual one; DAC
        # Data_Width/2 on both)
        self.beat_slots = int(self.nch * next(iter(spc)))
        # (32 slots: the 1024-bit sc8max beat, one sc8 wire word per beat)
        if self.beat_slots < 1 or (vrt.GRANULE % self.beat_slots
                                   and self.beat_slots != 2 * vrt.GRANULE):
            raise RuntimeError(f"fabric beat of {self.beat_slots} slots does not "
                               f"pack into the {vrt.GRANULE}-slot CMAC word")
        sw = _core_int(cores, "udp_streamer", "S_WIDTH")
        if sw is not None and sw != 32 * self.beat_slots:
            raise RuntimeError(f"udp_streamer S_WIDTH {sw} != the converter beat "
                               f"{32 * self.beat_slots} bit ({self.nch} ch x "
                               f"{next(iter(spc)):g} samples/clock)")
        self.factor = geo.decim
        self.adc_rate = geo.fs_adc
        self.rate = geo.fs_adc / geo.decim              # per channel
        self.slot_rate = self.nch * self.rate
        self.fabric_mhz = next(iter(geo.adc_fabric.values()))
        ts = _core_int(cores, "udp_streamer", "TICK_STEP")
        tp = _core_int(cores, "udp_player", "TICK_STEP")
        if ts is not None and tp is not None and ts != tp:
            raise RuntimeError(f"TICK_STEP differs: udp_streamer {ts}, udp_player {tp}")
        if ts is None:
            ts = tp
        self.tick_step_from = "hwh" if ts is not None else "v49_geometry"
        if ts is None and self.nch == 1 and self.factor % 2:
            raise RuntimeError(f"F={self.factor}: a 1-channel build needs an even "
                               f"factor (TICK_STEP F/2 ticks per sample)")
        self.tps = self.tick_step = int(ts if ts is not None
                                        else v49_tick_step(self.nch, self.factor))
        if self.tick_step < 1:
            raise RuntimeError(f"TICK_STEP {self.tick_step}")
        self.tick_rate = self.slot_rate * self.tick_step
        self.tx_buf_words = _core_int(cores, "udp_player", "TX_BUF_WORDS")
        bf_n = _core_int(cores, "tx_beamformer", "N_CH")
        if bf_n is not None and bf_n != self.nch:
            raise RuntimeError(f"tx_beamformer N_CH {bf_n} != {self.nch} channels")
        self.has_bf = bf_n is not None
        rbf_n = _core_int(cores, "rx_beamformer", "N_CH")
        if rbf_n is not None and rbf_n != self.nch:
            raise RuntimeError(f"rx_beamformer N_CH {rbf_n} != {self.nch} channels")
        self.has_rbf = rbf_n is not None

    @property
    def beat_bits(self) -> int:
        return 32 * self.beat_slots

    @property
    def key(self) -> Tuple[int, float]:
        return (self.nch, self.rate)

    def __repr__(self):
        return (f"{self.name}: {self.nch} ch, F={self.factor} {self.rate / 1e6:g} "
                f"MS/s/ch, {self.beat_bits}-bit beat @ {self.fabric_mhz:g} MHz, "
                f"tick_rate {self.tick_rate / 1e6:g} MHz ({self.tick_step} tick(s)/slot, "
                f"TICK_STEP from {self.tick_step_from}), TX beamformer "
                f"{'yes' if self.has_bf else 'no'}, RX beamformer "
                f"{'yes' if self.has_rbf else 'no'}")


def load_variant(bitstream: str, nch: Optional[int] = None,
                 board: Optional[Board] = None) -> Variant:
    """Variant from `bitstream` + the .hwh next to it. ValueError if the
    compiled design cannot be served as one coupled RX/TX rate on the
    channels its name says it streams."""
    hwh = os.path.splitext(bitstream)[0] + ".hwh"
    if not os.path.isfile(bitstream):
        raise ValueError(f"{bitstream}: no such file")
    if not os.path.isfile(hwh):
        raise ValueError(f"{os.path.basename(bitstream)}: no .hwh next to it")
    try:
        params, cores = hwh_params(hwh)
        board = board or board_of_bitstream(bitstream) or get_board(None)
        geo = Geometry(params, board)
    except (KeyError, RuntimeError, ET.ParseError) as e:
        raise ValueError(f"{os.path.basename(hwh)}: {e}")
    bad = geo.check()
    if geo.decim != geo.interp:
        bad.append(f"ADC decimation {geo.decim} != DAC interpolation {geo.interp} "
                   f"(RX and TX rates are one coupled rate)")
    if geo.fs_adc != geo.fs_dac:
        bad.append(f"ADC fs {geo.fs_adc} != DAC fs {geo.fs_dac}")
    if bad:
        raise ValueError(f"{os.path.basename(hwh)}: " + "; ".join(bad))
    try:
        return Variant(bitstream, geo, nch, cores, board)
    except (ValueError, RuntimeError) as e:
        raise ValueError(f"{os.path.basename(hwh)}: {e}")


def scan_bitstreams(directory: str, extra: Tuple[str, ...] = (),
                    board: Optional[Board] = None) -> List[Variant]:
    """Every <board>_v49_<N>ch_qsfp*.bit of `board` (default ZCU216) in
    `directory` with a usable .hwh next
    to it (plus `extra` bitstreams, which win the (N, rate) they share),
    sorted by channel count, then highest rate first. Unusable files are
    logged and skipped. Each build keeps its own tick rate."""
    paths = [os.path.abspath(p) for p in extra]
    board = board or get_board(None)
    for p in sorted(glob.glob(os.path.join(directory, board.bitstream_glob))):
        if board.name_channels(p) is None:
            continue
        if os.path.abspath(p) not in paths:
            paths.append(os.path.abspath(p))
    by_key: Dict[Tuple[int, float], Variant] = {}
    for p in paths:
        try:
            v = load_variant(p, board=board)
        except ValueError as e:
            log.warning("bitstream variant skipped: %s", e)
            continue
        if v.key in by_key:
            log.warning("bitstream variant skipped: %s gives %d ch x %.17g S/s "
                        "like %s", v.name, v.nch, v.rate, by_key[v.key].name)
            continue
        by_key[v.key] = v
    return sorted(by_key.values(), key=lambda v: (v.nch, -v.rate))


# --------------------------------------------------------------------------
# Backend
# --------------------------------------------------------------------------

class _Unusable:
    """Stands in for the overlay-bound drivers after a reload failed twice:
    any use is refused instead of touching a PL in an unknown state (an AXI
    access to an unmapped address can hang the PS)."""

    def __init__(self, why: str):
        self._why = why

    def __getattr__(self, name):
        raise BackendError(f"device unusable: {self._why}; restart the daemon")


class HwBackend(Backend):

    def __init__(self, bitstream: str, data_ip: str, data_mac: str,
                 lib_root: Optional[str] = None, load: bool = True,
                 allow_unlocked: bool = False,
                 rx_freq: float = 600e6, tx_freq: float = 600e6,
                 refclk: bool = True, rsfec: bool = True, rxpol: int = 0,
                 txpol: int = 0, dfe: bool = False, loopback: bool = False,
                 timeout: float = 5.0, printer=None,
                 variants: Optional[List[Variant]] = None,
                 nco_phase_reset: str = "all", rx_chain_grace_s: float = 0.001,
                 board: Optional[Board] = None):
        # the board: given, else the one the bitstream's name belongs to
        self.board = board or board_of_bitstream(bitstream) or get_board(None)
        self.product = self.board.prefix          # discovery product= (zcu216 / zcu208)
        if nco_phase_reset not in ("all", "tuned", "off"):
            raise ValueError(f"nco_phase_reset {nco_phase_reset!r}: all|tuned|off")
        self.nco_phase_reset = nco_phase_reset
        self.rx_chain_grace_s = float(rx_chain_grace_s)
        self._lock = threading.RLock()
        self._pr = printer or (lambda m: (print(m, flush=True), log.info("%s", m)))
        self.data_ip, self.data_mac = data_ip, data_mac
        self._clock_source = "internal"
        self._time_source = "internal"
        self._allow_unlocked = allow_unlocked
        self._refclk = refclk
        self._link = dict(rsfec=rsfec, rxpol=rxpol, txpol=txpol, dfe=dfe,
                          loopback=loopback, timeout=timeout)
        # what the client set, re-applied after a variant reload
        self._rx_cfg: Optional[dict] = None        # stream_setup args
        self._tx_cfg: Optional[dict] = None        # stream_setup_tx args
        self._user_rx_gain: Dict[int, float] = {}
        self._user_tx_gain: Dict[int, float] = {}
        # last NCO frequency of every channel ever tuned (any build), so a
        # channel-count switch gives each channel of the new build its value
        self._rx_freq_mem: Dict[int, float] = {}
        self._tx_freq_mem: Dict[int, float] = {}
        self._default_rx_freq, self._default_tx_freq = float(rx_freq), float(tx_freq)
        self._time_set = False
        self._streaming_cfg = None
        self.reloads = 0
        self.reload_settle_s = float(os.environ.get("ZCU216_RELOAD_SETTLE_S", "4.0"))

        self._import_libs(lib_root)

        # builds ((N, rate) -> Variant); the loaded one must be among them
        bitstream = os.path.abspath(bitstream)
        self.variants: Dict[Tuple[int, float], Variant] = {
            v.key: v for v in (variants or [])}
        initial = next((v for v in self.variants.values()
                        if os.path.realpath(v.bitstream) == os.path.realpath(bitstream)),
                       None)
        if initial is None:
            try:
                initial = load_variant(bitstream, board=self.board)
            except ValueError as e:
                # no readable .hwh here: serve the geometry the overlay reports
                log.warning("%s; its rate is taken from the loaded overlay", e)
        if initial is not None:
            other = self.variants.get(initial.key)
            if other is not None and other.bitstream != initial.bitstream:
                log.warning("%s replaces %s for %d ch x %.17g S/s (it is the one "
                            "loaded)", initial.name, other.name, initial.nch,
                            initial.rate)
            self.variants[initial.key] = initial
        for v in sorted(self.variants.values(), key=lambda v: (v.nch, -v.rate)):
            log.info("bitstream variant %r%s", v, "  <- initial" if v is initial else "")

        self._bring_up(bitstream, load=load, rx_freqs=None, tx_freqs=None,
                       rx_freq=rx_freq, tx_freq=tx_freq, refclk=refclk,
                       variant=initial)
        # without a readable .hwh, _bring_up described the build from the
        # overlay's own ip_dict
        self.variants.setdefault(self.variant.key, self.variant)

    def _import_libs(self, lib_root: Optional[str]) -> None:
        lib_root = lib_root or find_lib_root(os.path.dirname(os.path.abspath(__file__)))
        if not lib_root:
            raise RuntimeError("cannot find rfsoc_lib (pass --lib-root)")
        if lib_root not in sys.path:
            sys.path.insert(0, lib_root)
        # RfdcTask.set_external_clocks() reads rfsoc_lib/xrfclk/<board>/
        # relative to the CWD, so bring-up runs from the library root.
        os.chdir(lib_root)
        log.info("rfsoc_lib root: %s", lib_root)

        from rfsoc_lib.rfsoc_overlay import RFSoCOverlay
        from rfsoc_lib.rfdc_task import RfdcTask
        import rfsoc_lib.rfdc_config as rfdc_config
        import xrfdc
        self._xrfdc = xrfdc
        self._RFSoCOverlay, self._RfdcTask = RFSoCOverlay, RfdcTask
        # rfdc.py and rfdc_task.py read the module-global ZCU216_CONFIG
        # whatever the board, so that dict is the one NEW_CONFIG goes into;
        # another board's clock limits are copied into it first.
        self._rfdc_cfg = rfdc_config.ZCU216_CONFIG
        self._rfdc_cfg.update(getattr(rfdc_config, self.board.lib_config))

    # -- the full bring-up (initial, and after every variant reload) -------------
    def _bring_up(self, bitstream: str, load: bool,
                  rx_freqs: Optional[List[float]], tx_freqs: Optional[List[float]],
                  rx_freq: float = 600e6, tx_freq: float = 600e6,
                  refclk=True, variant: Optional[Variant] = None) -> None:
        pr = self._pr
        self.fpga_name = os.path.splitext(os.path.basename(bitstream))[0]

        # 1. overlay ---------------------------------------------------------
        log.info("%s overlay %s", "loading" if load else "attaching to (no download)",
                 bitstream)
        # pynq creates asyncio objects while loading an overlay. A rate change
        # reloads from the daemon's per-client thread, which has no event loop
        # ("There is no current event loop in thread 'client-...'"), so give
        # the calling thread one first.
        import asyncio
        try:
            asyncio.get_event_loop()
        except RuntimeError:
            asyncio.set_event_loop(asyncio.new_event_loop())
        self.ol = self._RFSoCOverlay(path_to_bitstream=bitstream, download=load)

        # 2. compiled geometry -> NEW_CONFIG -----------------------------------
        rfdc_key, params = _rfdc_params(self.ol)
        self.geo = Geometry(params, self.board)
        log.info("compiled RFDC (%s): %s", rfdc_key, self.geo.summary())
        problems = self.geo.check()
        if problems:
            raise RuntimeError("compiled RFDC geometry is inconsistent: "
                               + "; ".join(problems))
        if variant is not None and (self.geo.decim, self.geo.interp) != (
                variant.factor, variant.factor):
            raise RuntimeError(f"{self.fpga_name}: overlay reports decim/interp "
                               f"{self.geo.decim}/{self.geo.interp}, but its .hwh "
                               f"scan said F={variant.factor}")
        self.adc_rate, self.dac_rate = self.geo.fs_adc, self.geo.fs_dac
        self.rx_decim, self.tx_interp = self.geo.decim, self.geo.interp
        # The 100G data plane streams the FIRST N channels of the board's map
        # (boards.py; ZCU216: ADC / DAC tile c // 4, block c % 4, §9). The
        # donor enables more slices; only these N are streamed, so UHD sees N
        # RX and N TX channels. (ALL enabled slices get the compiled factor
        # and an NCO from the RfdcTask bring-up, and the readback below checks
        # every one of them.) rx_chans / tx_chans are xrfdc (tile, block).
        nch = variant.nch if variant is not None else (
            self.board.name_channels(bitstream) or 1)
        self.rx_chans, self.tx_chans = stream_slices(self.geo, nch, self.board)
        self.num_channels = nch
        if variant is None:
            variant = Variant(bitstream, self.geo, nch, _overlay_cores(self.ol),
                              self.board)
        # the build in effect: tick_step / tick_rate / beat / beamformer
        self.variant = variant
        rx_freqs = [(rx_freqs[ch] if rx_freqs and ch < len(rx_freqs) else rx_freq)
                    for ch in range(self.num_rx)]
        tx_freqs = [(tx_freqs[ch] if tx_freqs and ch < len(tx_freqs) else tx_freq)
                    for ch in range(self.num_tx)]

        _z, _p, rx_fold = nyquist_plan(rx_freqs[0], self.adc_rate)
        _z, _p, tx_fold = nyquist_plan(tx_freqs[0], self.dac_rate)
        NEW_CONFIG = {
            "RefClockForPLL": self.geo.refclk,
            "DACSampleRate": self.dac_rate / 1e6,
            "DACInterpolationRate": self.tx_interp,
            "DACNCO": tx_fold / 1e6,
            "ADCSampleRate": self.adc_rate / 1e6,
            "ADCInterpolationRate": self.rx_decim,     # rfsoc_lib's key for DECIMATION
            "ADCNCO": -rx_fold / 1e6,
        }
        self._rfdc_cfg.update(NEW_CONFIG)
        log.info("NEW_CONFIG (compiled geometry): %s", NEW_CONFIG)

        # 3. proven bring-up: RfdcTask start()/join() --------------------------
        errors = []
        prev_hook = threading.excepthook

        def hook(a):
            errors.append(a.exc_value)
            prev_hook(a)
        threading.excepthook = hook
        try:
            # MTS is run below, not inside the task: it must end LOCKED
            self.rfdc_t = self._RfdcTask(self.ol, mts_enable=False,
                                         debug_mode=False, board=self.board.name)
            for task in [self.rfdc_t]:
                task.start()
                task.join()
        finally:
            threading.excepthook = prev_hook
        self.my = self.rfdc_t.my_rfdc
        if errors:
            raise RuntimeError(f"RfdcTask.run() raised: {errors[0]!r}")
        # MTS before any sample is trusted (hw_design/ZCU216/CLAUDE.md): the
        # NCOs are programmed after it, as RfdcTask orders them
        self.mts = self._mts_lock()

        self._rx_freq = [0.0] * self.num_rx
        self._tx_freq = [0.0] * self.num_tx
        for ch in range(self.num_rx):
            self._program_nco("rx", ch, rx_freqs[ch])
        for ch in range(self.num_tx):
            self._program_nco("tx", ch, tx_freqs[ch])
        # §3d: every channel's NCO restarts in phase (per tile)
        self.reset_nco_phases("rx", range(self.num_rx))
        self.reset_nco_phases("tx", range(self.num_tx))

        # 4. readbacks, printed BEFORE any data is trusted ----------------------
        self.readback = self._readback(print_it=True)
        bad = [f"{k}: {v}" for k, v in self.readback["factor_errors"].items()]
        if bad:
            raise RuntimeError("converter factor readback != compiled factor "
                               "(the datapath would silently resample): "
                               + "; ".join(bad))
        if not (self.readback["adc_clock_ok"] and self.readback["dac_clock_ok"]):
            msg = ("tile clock NOT good: " + str(self.readback["tiles"]) +
                   " -- see hw_design/ZCU216/CLAUDE.md (zcu216-0's ADC "
                   "reference clock was dead as of 2026-09-01)")
            if not self._allow_unlocked:
                raise RuntimeError(msg + "; refusing (use --allow-unlocked to "
                                   "serve the test pattern anyway)")
            log.warning("%s; continuing because --allow-unlocked", msg)

        # 5. 100G path: refclk, clock meters, GT reset + wait for alignment,
        #    FPGA MAC/IP. A link that does not come up is NOT fatal: the daemon
        #    serves and reports it (sensor cmac_aligned / refclk_khz).
        from eth100g import Eth100G
        from bringup import link_bringup
        self.eth = Eth100G(self.ol)
        self.link = link_bringup(self.eth, refclk=refclk, pr=pr, **self._link)
        pr(f"[e] MAC/IP {self.data_mac} {self.data_ip} -> streamer + player (ARP on)")
        self.eth.set_addresses(self.data_mac, self.data_ip)
        # the DAC is fed by the UDP player, always: the DRAM/DMA DAC path is
        # gone from every v49 build (dac_src = 0 would select a tied-off
        # stream), and an idle player outputs zeros
        self.eth.player_enable()
        # §10: which OTW formats this bitstream converts (FMT read-back; a
        # build from before §10 has no FMT register and offers only sc16)
        self._otw_hw = self.eth.probe_formats() or ["sc16"]
        pr(f"[e] OTW formats (FMT registers): {','.join(self._otw_hw)}")
        self.tx_buf_words = self.eth.tx_buf_words()
        # FC update every 512 consumed words (1/8 of a smaller buffer);
        # $ZCU216_FC_INTERVAL overrides (measurements)
        self.fc_interval = default_fc_interval(self.tx_buf_words)
        # §11: the TX beamformer of an N >= 2 build (bypass + unity at reset;
        # the kept state is re-applied by bf_restore)
        try:
            self.bf = TxBeamformer.from_ip_dict(self.ol.ip_dict, nch)
        except RuntimeError as e:      # wrong ID / NCH: serve without it
            log.error("tx_beamformer unusable, beamforming disabled: %s", e)
            self.bf = None
        if self.bf is not None:
            self.bf.apply(False, [(32767, 0)] * nch)
        try:
            self.rbf = RxBeamformer.from_ip_dict(self.ol.ip_dict, nch)
        except RuntimeError as e:      # wrong ID / NCH: serve without it
            log.error("rx_beamformer unusable, RX beamforming disabled: %s", e)
            self.rbf = None
        if self.rbf is not None:
            self.rbf.apply(False, [(32767, 0)] * nch, default_shift(nch))
        pr(f"[e] TX beamformer: {'present (bypass)' if self.bf is not None else 'none'}; "
           f"RX beamformer: {'present (bypass)' if self.rbf is not None else 'none'}; "
           f"TX buffer {self.tx_buf_words} words, FC every {self.fc_interval}")
        self._rx_gain = [self._read_dsa_gain(ch) for ch in range(self.num_rx)]
        self._tx_gain = [self._read_vop_gain(ch) for ch in range(self.num_tx)]
        self._streaming_cfg = None
        pr(f"[+] {self.fpga_name}: {self.num_channels} channel(s) "
           f"{[f'{t}{b}' for t, b in self.rx_chans]} at {self.samp_rate / 1e6:g} "
           f"MS/s each (F={self.rx_decim}, {self.beat_bits}-bit beat, "
           f"{self.ticks_per_slot} tick(s)/slot at tick_rate "
           f"{self.tick_rate / 1e6:g} MHz)")

    # -- builds: one bitstream per (channel count, converter factor) --------------
    def available_rates(self):
        return self.rates_for(self.num_channels)

    def rates_for(self, n):
        return sorted((r for k, r in self.variants if k == int(n)), reverse=True)

    def channel_counts(self):
        return sorted({n for n, _ in self.variants})

    def _cur(self) -> Optional[Variant]:
        v = getattr(self, "variant", None)
        return v if v is not None and v.nch == self.num_channels else None

    @property
    def tick_step(self) -> int:
        v = self._cur()
        return v.tick_step if v is not None else super().tick_step

    @property
    def beat_slots(self) -> int:
        v = self._cur()
        return v.beat_slots if v is not None else super().beat_slots

    def build_props(self, rate):
        v = self.variants.get((self.num_channels, float(rate)))
        if v is None:
            return super().build_props(rate)
        return {"tick_rate": v.tick_rate, "beat_bits": v.beat_bits, "bf": v.has_bf,
                "rbf": v.has_rbf}

    @property
    def has_bf(self) -> bool:
        return getattr(self, "bf", None) is not None

    @property
    def has_rbf(self) -> bool:
        return getattr(self, "rbf", None) is not None

    def _bf_write(self, enable, weights):
        with self._lock:
            self.bf.apply(enable, weights)

    def _rbf_write(self, enable, weights, shift):
        with self._lock:
            self.rbf.apply(enable, weights, shift)

    def _switch_rate(self, rate: float) -> None:
        v = self.variants[(self.num_channels, rate)]
        old = self.variant
        self._switch_to(v, f"RATE CHANGE {old.rate / 1e6:g} -> {v.rate / 1e6:g} "
                           f"MS/s", f"rate change to {v.rate:.17g}")

    def _switch_channels(self, n: int) -> None:
        # that channel count's DEFAULT build: the sc16-max one (the highest
        # rate whose sc16 stream fits 100GbE), not the fastest -- the sc8-max
        # builds stream only with otw=sc8 (PROTOCOL.md §9)
        v = self.variants[(n, default_rate(n, self.rates_for(n)))]
        old = self.variant
        self._switch_to(v, f"CHANNEL CHANGE {old.nch} -> {v.nch} channel(s) "
                           f"({v.rate / 1e6:g} MS/s each)",
                        f"channel change to {v.nch}")

    def _switch_to(self, v: Variant, banner: str, what: str) -> None:
        """Load build `v` and redo the FULL bring-up, then restore what the
        client had set. RX and TX change together (one factor, one N).

        Kept across the reload: RX/TX NCO frequencies and the gains the client
        set, per channel, for every channel the new build has (a channel never
        tuned gets the daemon's initial frequency), stream_setup and
        stream_setup_tx (re-applied; the TX consumed-word count restarts at 0
        in the new FPGA, so the host must take a new baseline from a fresh
        stream_setup_tx), the FPGA MAC/IP, the TX and RX beamformer state (§11). The
        timekeeper is set to 0, unless a client had called set_time: then it
        continues from the same instant plus the wall-clock time the reload
        took, in the new build's ticks (each build has its own tick rate;
        accuracy ~ms, so re-issue set_time after a switch if sample alignment
        matters).
        """
        old = self.variant
        pr = self._pr
        t0 = time.monotonic()
        with self._lock:
            pr(f"==== {banner}: reloading {v.name} ({v.nch} ch, F={v.factor}, "
               f"fabric {v.fabric_mhz:g} MHz) and redoing the full bring-up; "
               f"streaming stops ====")
            state = self._quiesce()
            try:
                self._reload(v, state)
            except Exception as e:
                log.exception("bring-up of %s failed", v.name)
                msg = f"{what} ({v.name}) failed: {e}"
                pr(f"==== {msg}; going back to {old.name} ====")
                try:
                    self._reload(old, state)
                except Exception as e2:
                    log.exception("bring-up of %s failed too", old.name)
                    why = f"{msg}; reloading {old.name} failed too: {e2}"
                    self.eth = self.my = _Unusable(why)
                    self.bf = self.rbf = None   # no AXI access into an unknown PL
                    raise BackendError(why)
                raise BackendError(f"{msg}; {old.name} restored ({old.nch} ch "
                                   f"at {old.rate:.17g} S/s)")
            self.reloads += 1
            # The FPGA side re-aligns in < 0.1 s, but the NIC at the far end
            # takes ~2-3 s to bring its link back up after the GT restarts.
            # Anything the host sends in that window is dropped by the NIC
            # while the host has already counted it as in flight (lost TX
            # credit; measured on wei-duke-wsp5, 2026-09-28). So reply only
            # once the far end has had time to come back.
            time.sleep(getattr(self, "reload_settle_s", 0.0))
            pr(f"==== now {v.name}: {v.nch} channel(s) at {v.rate / 1e6:g} MS/s, "
               f"tick_rate {self.tick_rate / 1e6:g} MHz; reload took "
               f"{time.monotonic() - t0:.1f} s ====")

    def _quiesce(self) -> dict:
        """Stop RX streaming and TX playback; snapshot what must survive."""
        state = {"rx_cfg": self._rx_cfg, "tx_cfg": self._tx_cfg,
                 "rx_gain": dict(self._user_rx_gain),
                 "tx_gain": dict(self._user_tx_gain), "time": None}
        q = getattr(self, "_rxq", None)
        if q is not None:
            q.reset()               # queued / running stream commands are gone
        try:
            if self.eth.streaming():
                self.eth.stream_cmd("stop_cont", 0, True, 0)
                if not self.eth.wait_idle(0.2):
                    log.warning("streamer not idle before reload")
            if self._tx_cfg is not None:
                self.eth.player_stop()
            if self._time_set:
                state["time"] = (self.eth.get_time(), time.monotonic(),
                                 self.tick_rate)
        except Exception as e:     # the old FPGA is going away anyway
            log.warning("quiescing before reload: %s", e)
        return state

    def _reload(self, v: Variant, state: dict) -> None:
        # drop the old overlay's drivers before PYNQ reprograms the PL
        self.eth = self.my = self.rfdc_t = self.ol = self.bf = self.rbf = None
        rx_freqs = [self._rx_freq_mem.get(c, self._default_rx_freq) for c in range(v.nch)]
        tx_freqs = [self._tx_freq_mem.get(c, self._default_tx_freq) for c in range(v.nch)]
        self._bring_up(v.bitstream, load=True, rx_freqs=rx_freqs,
                       tx_freqs=tx_freqs,
                       refclk="auto" if self._refclk else False, variant=v)
        self._restore(state)

    def _restore(self, state: dict) -> None:
        pr = self._pr
        pr(f"[r] NCO RX {self._rx_freq} TX {self._tx_freq} Hz (restored per channel)")
        for ch, db in sorted(state["rx_gain"].items()):
            if ch < self.num_rx:
                pr(f"[r] RX gain ch{ch} {self.set_rx_gain(ch, db):g} dB (restored)")
        for ch, db in sorted(state["tx_gain"].items()):
            if ch < self.num_tx:
                pr(f"[r] TX gain ch{ch} {self.set_tx_gain(ch, db):g} dB (restored)")
        if state["time"] is None:
            self.eth.set_time(0)
            pr("[r] timekeeper set to 0 (no client had set the time)")
        else:
            t, mono, old_tick = state["time"]
            # the same instant in the new build's ticks (differs only when the
            # channel count changes the tick rate, i.e. to/from N = 16)
            secs = t / old_tick + (time.monotonic() - mono)
            now = int(round(secs * self.tick_rate))
            self.eth.set_time(now)
            pr(f"[r] timekeeper carried over: {now} ticks (was {t} at "
               f"{old_tick / 1e6:g} MHz, + the wall-clock time of the reload; "
               f"~ms accurate)")
        if state["rx_cfg"] is not None:
            spp, nports = self.stream_setup(**state["rx_cfg"])
            pr(f"[r] stream_setup re-applied: {state['rx_cfg']['host_ip']} port "
               f"{state['rx_cfg']['port_base']} x{nports} spp {spp}")
        if state["tx_cfg"] is not None:
            _b, _f, base = self.stream_setup_tx(**state["tx_cfg"])
            pr(f"[r] stream_setup_tx re-applied; consumed-word count restarted "
               f"(new baseline {base}) -- the host must re-read it")
        self.bf_restore()
        for kind, name in (("tx", "TX"), ("rx", "RX")):
            if self._bfk_has(kind):
                st = self._bfk(kind)
                pr(f"[r] {name} beamformer: enable {int(st['enable'])}, "
                   f"{'angle %g deg' % st['angle'] if st['angle'] is not None else 'weights'} "
                   f"{self._bfk_weights(kind)}"
                   + (f", shift {self._rbf_shift()}" if kind == "rx" else ""))

    # -- tiles / blocks ----------------------------------------------------------
    def _adc_block(self, ch):
        t, b = self.rx_chans[ch]
        return self.my.adc_tiles[t], b, self.my.adc_tiles[t].blocks[b]

    def _dac_block(self, ch):
        t, b = self.tx_chans[ch]
        return self.my.dac_tiles[t], b, self.my.dac_tiles[t].blocks[b]

    def _mts_lock(self) -> Dict[str, object]:
        """Multi-tile sync of every DAC and ADC tile (rfsoc_lib MyMTS.init():
        tile-sync reset, MTS clocking-wizard MMCM lock, mts_dac, mts_adc).
        It must end LOCKED, or the daemon refuses to serve. The first attempt
        after a board reboot fails on zcu216-0 and the second succeeds, so it
        runs at most twice; the attempt that locked is logged. MyMTS takes
        the board's tile mask and reference tile (ZCU208: tiles 0 and 2,
        RefTile 2)."""
        from rfsoc_lib.mts import MyMTS
        mts = MyMTS(self.ol.rfdc.usp_rf_data_converter, self.ol,
                    board=self.board.name)
        last = None
        for attempt in (1, 2):
            try:
                mts.init()
                mts.verify_clock_tree()
            except Exception as e:
                last = e
                log.warning("MTS attempt %d failed: %r", attempt, e)
                continue
            st = {"locked": True, "attempt": attempt}
            for kind, cfg in (("dac", mts.rfdc.mts_dac_config),
                              ("adc", mts.rfdc.mts_adc_config)):
                st[kind] = {"tiles": int(cfg.Tiles), "ref_tile": int(cfg.RefTile),
                            "latency": [int(cfg.Latency[i]) for i in range(4)],
                            "offset": [int(cfg.Offset[i]) for i in range(4)]}
            self._pr(f"[m] MTS LOCKED (attempt {attempt}): MMCM locked; "
                     f"DAC tiles {st['dac']['tiles']:#06b} latency {st['dac']['latency']} offset {st['dac']['offset']}; "
                     f"ADC tiles {st['adc']['tiles']:#06b} latency {st['adc']['latency']} offset {st['adc']['offset']}")
            return st
        raise RuntimeError(f"MTS NOT locked after 2 attempts ({last!r}); refusing "
                           "to serve -- hw_design/ZCU216/CLAUDE.md")

    def _tile_clock(self, tile) -> Dict[str, object]:
        """PLL-enabled tile: PLLLockStatus must be 2. Bypassed tile (the donor
        takes the fs MHz LMX clock straight in): no PLL to lock, so the
        power-up state machine reaching 15 (clock detected, released) is the
        only on-chip evidence."""
        d = {}
        try:
            d["pll_enabled"] = int(tile.PLLConfig.get("Enabled", 0))
        except Exception as e:
            d["pll_enabled"] = f"? ({e})"
        try:
            d["pll_lock"] = int(tile.PLLLockStatus)
        except Exception as e:
            d["pll_lock"] = f"? ({e})"
        try:
            d["clock_source"] = int(tile.ClockSource)
        except Exception:
            pass
        d["ok"] = (d.get("pll_lock") == PLL_LOCKED if d.get("pll_enabled") == 1
                   else None)
        return d

    def _readback(self, print_it=False) -> Dict[str, object]:
        """Tile clock of every tile holding a streamed channel, and the
        interpolation / decimation factor of EVERY enabled block (not only the
        streamed ones: one AXIS clock drives them all, and a block at the
        wrong factor resamples silently -- hw_design/ZCU216/CLAUDE.md).

        The compiled factors are per IP slice; they are read back per xrfdc
        block (a dual ADC tile's I and Q slices 2k, 2k+1 are block k). A tile
        the board leaves unpowered (RfdcTask set_board_rules; ZCU208 tiles 1
        and 3) is listed but not read: its blocks were never initialised and
        it carries no streamed channel (the build's verify_rate_variant
        checked its compiled factor)."""
        st = self.my.rfdc_status
        tiles, factor_errors = {}, {}
        lines = []
        for kind, chans, compiled, get_tiles, get_state, fac in (
                ("DAC", self.tx_chans, self.geo.dac_interp, self.my.dac_tiles,
                 st.get_dac_tile_state, "InterpolationFactor"),
                ("ADC", self.rx_chans, self.geo.adc_decim, self.my.adc_tiles,
                 st.get_adc_tile_state, "DecimationFactor")):
            streamed = set(chans)
            for t in sorted({t for t, _ in chans}):
                tile = get_tiles[t]
                d = self._tile_clock(tile)
                d["state"] = int(get_state(t))
                if d["ok"] is None:
                    d["ok"] = d["state"] == TILE_STATE_DONE
                    d["mode"] = "PLL bypassed"
                tiles[f"{kind}{t}"] = d
                lines.append(f"{kind} tile {t}: state {d['state']} PLL enabled "
                             f"{d['pll_enabled']} PLLLockStatus {d['pll_lock']} "
                             f"(2=locked) -> {'OK' if d['ok'] else 'NOT OK'}")
            # xrfdc block -> the compiled factors of its IP slice(s)
            blocks: Dict[Tuple[int, int], set] = {}
            for s_, f_ in compiled.items():
                blk_id = self.board.api_block(s_) if kind == "ADC" else s_
                blocks.setdefault(blk_id, set()).add(int(f_))
            masked = set(self.board.masked_tiles)
            for (t, b) in sorted(blocks):
                ch = (f" ch{chans.index((t, b))}" if (t, b) in streamed
                      else " (not streamed)")
                wants = blocks[(t, b)]
                want = min(wants)
                if t in masked:
                    lines.append(f"{kind} {t}{b}{ch}: not read, tile unpowered on "
                                 f"the {self.board.name} (compiled {want})")
                    continue
                if len(wants) != 1:
                    factor_errors[f"{kind}{t}{b}"] = f"its slices compiled {sorted(wants)}"
                try:
                    blk = get_tiles[t].blocks[b]
                    got = getattr(blk, fac)
                except Exception as e:
                    lines.append(f"{kind} {t}{b}{ch}: {fac} UNREADABLE ({e}) "
                                 f"(compiled {want})")
                    factor_errors[f"{kind}{t}{b}"] = f"{fac} unreadable: {e}"
                    continue
                try:
                    mix = dict(blk.MixerSettings)
                    nz = blk.NyquistZone
                except Exception as e:
                    mix, nz = f"? ({e})", "?"
                lines.append(f"{kind} {t}{b}{ch}: {fac} {got} (compiled {want}) "
                             f"NyquistZone {nz} NCO {mix.get('Freq') if isinstance(mix, dict) else mix} MHz")
                if int(got) != int(want):
                    factor_errors[f"{kind}{t}{b}"] = f"{fac} {got} != compiled {want}"
        out = {
            "tiles": tiles, "factor_errors": factor_errors,
            "adc_clock_ok": all(v["ok"] for k, v in tiles.items() if k.startswith("ADC")),
            "dac_clock_ok": all(v["ok"] for k, v in tiles.items() if k.startswith("DAC")),
        }
        if print_it:
            print("---- RFDC readback (compiled geometry) ----", flush=True)
            for ln in lines:
                print(ln, flush=True)
                log.info(ln)
            print("-------------------------------------------", flush=True)
        return out

    # -- tuning ------------------------------------------------------------------
    # One NCO per channel (the fine mixer); PROTOCOL.md §3b folds a tune
    # request's RF and DSP parts into it. After NCOs change, the phase
    # accumulators of the direction's channels are reset TOGETHER (§3d):
    # XRFdc_ResetNCOPhase on every block, then ONE mixer update event per
    # tile (EventSource is EVNT_SRC_TILE, so the event applies every block of
    # the tile at the same clock edge). Channels of one tile then keep a
    # fixed relative phase after every retune -- what the §11 beamformer's
    # weights assume. Across tiles (N = 8, 16) the per-tile events are
    # software writes microseconds apart: their phase offset is NOT
    # deterministic (that needs SYSREF-timed events, i.e. MTS).
    #   nco_phase_reset = "all"   every streamed channel of the direction
    #                     "tuned" only the channels of this batch
    #                     "off"   never (the driver's NCO keeps running)
    nco_phase_reset = "all"

    def _program_nco(self, kind, ch, hz):
        """Write one channel's NCO (and Nyquist zone); -> the frequency."""
        lo, hi = self.rx_freq_range(ch) if kind == "rx" else self.tx_freq_range(ch)
        hz = min(hi, max(lo, float(hz)))
        fs = self.adc_rate if kind == "rx" else self.dac_rate
        _zone, parity, folded = nyquist_plan(hz, fs)
        tile, b, blk = self._adc_block(ch) if kind == "rx" else self._dac_block(ch)
        with self._lock:
            blk.NyquistZone = parity
            if kind == "rx":
                # rfsoc_lib convention (real->I/Q): ADC NCO = -f. The driver
                # folds into [-fs/2, fs/2] and handles the even-zone inversion.
                self.my.config_adc_nco(tile, b, -folded / 1e6)
            else:
                self.my.config_dac_nco(tile, b, folded / 1e6)
        f = min(hi, coerce_nco(hz, fs))
        if kind == "rx":
            self._rx_freq[ch] = self._rx_freq_mem[ch] = f
        else:
            self._tx_freq[ch] = self._tx_freq_mem[ch] = f
        return f

    def reset_nco_phases(self, kind, chans):
        """§3d: ResetNCOPhase on the blocks of `chans` (all streamed channels
        with nco_phase_reset "all"), then one EVENT_MIXER update per tile.
        Guarded: a driver without ResetNCOPhase disables the feature (logged
        once); any other failure is logged and the tune stands."""
        mode = getattr(self, "nco_phase_reset", "off")
        if mode == "off":
            return []
        slices = self.rx_chans if kind == "rx" else self.tx_chans
        if mode == "all":
            chans = range(len(slices))
        sl = sorted({slices[c] for c in chans if 0 <= c < len(slices)})
        if not sl:
            return []
        tiles = self.my.adc_tiles if kind == "rx" else self.my.dac_tiles
        event = getattr(getattr(self, "_xrfdc", None), "EVENT_MIXER", 1)
        try:
            with self._lock:
                for t, b in sl:
                    tiles[t].blocks[b].ResetNCOPhase()
                for t in sorted({t for t, _ in sl}):
                    b0 = min(b for tt, b in sl if tt == t)
                    tiles[t].blocks[b0].UpdateEvent(event)
        except AttributeError as e:
            log.error("NCO phase reset unavailable in this xrfdc (%s): disabled; "
                      "inter-channel phase is NOT reset on tune", e)
            self.nco_phase_reset = "off"
            return []
        except Exception as e:
            log.error("NCO phase reset (%s %s) failed: %s", kind, sl, e)
            return []
        return sl

    def set_rx_freq(self, ch, hz):
        f = self._program_nco("rx", ch, hz)
        self.reset_nco_phases("rx", [ch])
        return f

    def get_rx_freq(self, ch):
        return self._rx_freq[ch]

    def set_tx_freq(self, ch, hz):
        f = self._program_nco("tx", ch, hz)
        self.reset_nco_phases("tx", [ch])
        return f

    def get_tx_freq(self, ch):
        return self._tx_freq[ch]

    def apply_freqs(self, kind, items):
        """§3b/§3d: every NCO of the batch, THEN one phase reset + update
        event per tile, so the batch's channels restart in phase together."""
        out = []
        with self._lock:
            for ch, rf, dsp in items:
                rf_a, dsp_a, centre = self.plan_freq(kind, ch, rf, dsp)
                self._program_nco(kind, ch, centre)
                self._dsp_mem(kind)[int(ch)] = dsp_a
                out.append((rf_a, dsp_a))
            self.reset_nco_phases(kind, [int(i[0]) for i in items])
        return out

    def lo_locked(self, kind, ch):
        """The converter tile of channel ch: PLL locked (PLL-enabled tile) or
        power-up state machine done (PLL bypassed), like the bring-up
        readback judges it."""
        t, _b = (self.rx_chans if kind == "rx" else self.tx_chans)[ch]
        with self._lock:
            tile = (self.my.adc_tiles if kind == "rx" else self.my.dac_tiles)[t]
            d = self._tile_clock(tile)
            if d["ok"] is None:
                st = self.my.rfdc_status
                get = st.get_adc_tile_state if kind == "rx" else st.get_dac_tile_state
                d["ok"] = int(get(t)) == TILE_STATE_DONE
        return bool(d["ok"])

    # -- gain ----------------------------------------------------------------------
    def _read_dsa_gain(self, ch) -> float:
        try:
            return -float(self._adc_block(ch)[2].DSA["Attenuation"])
        except Exception as e:
            log.warning("ADC DSA readback unavailable (%s); rx gain fixed 0", e)
            self._dsa_ok = False
            return 0.0

    def rx_gain_range(self, ch):
        if getattr(self, "_dsa_ok", True) is False:
            return (0.0, 0.0, 0.0)
        return (-DSA_MAX_DB, 0.0, DSA_STEP_DB)

    def set_rx_gain(self, ch, db):
        if getattr(self, "_dsa_ok", True) is False:
            return 0.0
        self._user_rx_gain[ch] = float(db)     # re-applied after a reload
        atten = min(DSA_MAX_DB, max(0.0, -float(db)))
        atten = round(atten / DSA_STEP_DB) * DSA_STEP_DB
        blk = self._adc_block(ch)[2]
        with self._lock:
            cur = blk.DSA
            blk.DSA = {"DisableRTS": cur.get("DisableRTS", 0),
                       "Attenuation": float(atten)}
            self._rx_gain[ch] = -float(blk.DSA["Attenuation"]) + 0.0
        return self._rx_gain[ch]

    def get_rx_gain(self, ch):
        return self._rx_gain[ch]

    def _read_vop_gain(self, ch) -> float:
        if not self.geo.vop_mode:
            return 0.0
        try:
            return gain_for_vop_ua(self._dac_block(ch)[2].OutputCurr)
        except Exception as e:
            log.warning("DAC OutputCurr readback failed (%s)", e)
            return 0.0

    def tx_gain_range(self, ch):
        if not self.geo.vop_mode:
            return (0.0, 0.0, 0.0)      # IP built without VOP: fixed output
        return super().tx_gain_range(ch)

    def set_tx_gain(self, ch, db):
        if not self.geo.vop_mode:
            return 0.0
        self._user_tx_gain[ch] = float(db)
        blk = self._dac_block(ch)[2]
        with self._lock:
            blk.SetDACVOP(vop_ua_for_gain(float(db)))
            self._tx_gain[ch] = gain_for_vop_ua(blk.OutputCurr)
        return self._tx_gain[ch]

    def get_tx_gain(self, ch):
        return self._tx_gain[ch]

    # -- time -------------------------------------------------------------------
    def set_time(self, ticks):
        with self._lock:
            self.eth.set_time(ticks)
            self._time_set = True      # a reload then carries the time over

    def get_time(self):
        with self._lock:
            return self.eth.get_time()

    # -- streaming --------------------------------------------------------------
    def otw_formats(self):
        return list(getattr(self, "_otw_hw", None) or ["sc16"])

    def stream_setup(self, ch, host_ip, host_mac, port_base, nports, spp, pattern,
                     otw="sc16"):
        with self._lock:
            if self.eth.streaming():
                raise BackendError("streaming active; stop_cont first")
            if otw not in self.otw_formats():
                raise BackendError(f"otw={otw}: {self.fpga_name} converts only "
                                   f"{','.join(self.otw_formats())}")
            # spp in slots: whole 64-byte words of the format and a multiple
            # of N (re-rounded when a setup made under another N is re-applied
            # after a switch)
            spp = vrt.round_spp(spp, self.otw_granule(otw), vrt.otw_max_spp(otw))
            # one stream carries all N channels: SID of channel 0 (§9)
            try:
                actual = self.eth.configure(
                    src_mac=self.data_mac, src_ip=self.data_ip, dst_mac=host_mac,
                    dst_ip=host_ip, src_port=vrt.FPGA_SRC_PORT,
                    dst_port_base=port_base, nports=nports, spp=spp,
                    sid=vrt.sid_for(0), pattern=pattern, fmt=otw)
            except RuntimeError as e:
                raise BackendError(str(e))
            self._streaming_cfg = (ch, host_ip, port_base, nports, actual, pattern)
            self._rx_cfg = dict(ch=ch, host_ip=host_ip, host_mac=host_mac,
                                port_base=port_base, nports=nports, spp=spp,
                                pattern=pattern, otw=otw)
            return int(actual), nports

    def stream_cmd(self, ch, mode, num_samps, now, time_ticks, cont=False):
        with self._lock:
            if self._streaming_cfg is None:
                if mode == "stop_cont":
                    return "new"      # never configured: nothing to stop
                raise BackendError("stream_setup first")
            # <ch> is ignored: one stream carries every channel (§9), and
            # num_samps is already in slots (the host multiplied by N). The
            # RTL holds one command: rx_cmdq queues them (PROTOCOL.md §4a).
            return self.rx_queue().post(mode, int(num_samps), bool(now),
                                        int(time_ticks), bool(cont))

    def stop_streaming(self):
        with self._lock:
            if self._streaming_cfg is None:
                return
            try:
                self.rx_queue().stop()
            except (RuntimeError, BackendError) as e:
                log.warning("stop_cont: %s", e)

    def is_streaming(self):
        return self.eth.streaming() or self.rx_queue().busy()

    # -- the RTL streamer, for rx_cmdq.RxCommandQueue (lock held) ----------------
    # STATUS[0] (streaming) crosses from adc_clk like CMDS does: a command
    # just accepted counts as busy for RX_SETTLE_S, so a short burst is never
    # mistaken for "already idle" before its status bit arrived.
    RX_SETTLE_S = 0.002

    def rxhw_issue(self, mode, num, now, t):
        if self._streaming_cfg is None:
            raise BackendError("stream_setup first")
        try:
            self.eth.stream_cmd(mode, int(num), bool(now), int(t))
            # every RTL stream command, to tell a short finite capture's
            # cause (what the FPGA was asked for vs what the host received)
            log.info("rx cmd %s num=%d now=%d t=%d spp=%s", mode, int(num), int(bool(now)),
                     int(t), getattr(self, "_rx_cfg", {}).get("spp"))
        except (RuntimeError, KeyError) as e:
            raise BackendError(str(e))
        self._rx_issue_mono = time.monotonic()
        if now:
            # the RTL starts on the beat after the command arrived: at or
            # before the time read now (an upper bound)
            return self.eth.get_time()
        beat = self.beat_slots * self.ticks_per_slot
        return int(t) - int(t) % beat

    def rxhw_stop(self):
        try:
            self.eth.stream_cmd("stop_cont", 0, True, 0)
        except RuntimeError as e:
            log.warning("stop_cont: %s", e)

    def rxhw_busy(self):
        if time.monotonic() - getattr(self, "_rx_issue_mono", 0.0) < self.RX_SETTLE_S:
            return True
        return self.eth.streaming()

    def rxhw_time(self):
        return self.eth.get_time()

    def rxhw_pos(self):
        return self.eth.get_time()      # the RTL streams in real time

    def rxhw_pkts(self):
        return self.eth.pkts()

    def rxhw_geometry(self):
        tps = self.ticks_per_slot
        otw = (self._rx_cfg or {}).get("otw", "sc16")
        return tps, self.beat_slots * tps, self.otw_granule(otw), self.tick_rate

    def stream_setup_tx(self, ch, host_ip, host_mac, async_port, otw="sc16"):
        with self._lock:
            if otw not in self.otw_formats():
                raise BackendError(f"otw={otw}: {self.fpga_name} converts only "
                                   f"{','.join(self.otw_formats())}")
            try:
                base = self.eth.player_setup(my_mac=self.data_mac, my_ip=self.data_ip,
                                             host_mac=host_mac, host_ip=host_ip,
                                             async_port=async_port,
                                             fc_interval=self.fc_interval,
                                             sid=vrt.tx_sid_for(0),   # one stream (§9)
                                             fmt=otw)
            except RuntimeError as e:
                raise BackendError(str(e))
            self._tx_cfg = dict(ch=ch, host_ip=host_ip, host_mac=host_mac,
                                async_port=async_port, otw=otw)
            return self.tx_buf_words, self.fc_interval, base

    def stream_stop_tx(self, ch):
        with self._lock:
            self._tx_cfg = None
            self.eth.player_stop()

    # -- sensors ------------------------------------------------------------------
    SENSORS = ("cmac_aligned", "adc_pll_locked", "dac_pll_locked",
               "ref_locked", "temp", "pl_temp", "streaming", "refclk_khz",
               "usrclk_khz", "pps_present", "mts_locked")

    def list_sensors(self):
        return list(self.SENSORS)

    def get_sensor(self, name):
        if name == "cmac_aligned":         # cmac_gpio status bit0
            with self._lock:
                return bool_sensor(self.eth.cmac_aligned(), "aligned", "unaligned")
        if name in ("refclk_khz", "usrclk_khz"):
            with self._lock:
                v = self.eth.refclk_khz() if name == "refclk_khz" else self.eth.usrclk_khz()
            return ("int", str(v), "kHz")
        if name in ("adc_pll_locked", "dac_pll_locked", "ref_locked"):
            with self._lock:
                rb = self._readback()
            if name == "adc_pll_locked":
                v = rb["adc_clock_ok"]
            elif name == "dac_pll_locked":
                v = rb["dac_clock_ok"]
            else:
                # the LMK04828/LMX2594 are write-only through xrfclk here, so
                # the reference is judged by the converter tiles it clocks
                v = rb["adc_clock_ok"] and rb["dac_clock_ok"]
            return bool_sensor(v, "locked", "unlocked")
        if name in ("temp", "pl_temp"):
            t = read_sysmon_temp("ps" if name == "temp" else "pl")
            if t is None:
                # a value, not an error: usrp_list_sensors reads every sensor
                return ("string", "n/a", "-")
            return ("real", "%.17g" % t, "C")
        if name == "streaming":
            return bool_sensor(self.is_streaming(), "streaming", "idle")
        if name == "mts_locked":
            # bring-up locked MTS (or refused to serve) AND the MTS clocking
            # wizard's MMCM is still locked now (PG065 status register 0x4)
            with self._lock:
                mmcm = self.ol.MTS_block.MTS_clk_wiz.mmio.read(0x4) == 1
            return bool_sensor(bool(getattr(self, "mts", {}).get("locked")) and mmcm,
                               "locked", "unlocked")
        if name == "pps_present":
            # no PPS input is wired to the timekeeper in any v49 build
            return bool_sensor(False, "present", "absent")
        raise BackendError(f"unknown sensor {name}")

    def set_clock_source(self, src):
        # 'external' needs an LMK04828 register file that selects CLKin0 (CLK104
        # REF IN) instead of the TCXO; none exists in rfsoc_lib/xrfclk/ZCU216.
        if src not in self.clock_sources():
            raise BackendError(f"unsupported clock source {src}")
        self._clock_source = src

    def get_clock_source(self):
        return self._clock_source

    def stats(self):
        with self._lock:
            s = self.eth.stats()
        s["backend"] = "hw"
        s["fpga"] = self.fpga_name
        s["samp_rate"] = "%.17g" % self.samp_rate
        s["reloads"] = self.reloads
        s["channels"] = self.num_channels
        return s
