"""The device interface of the uhd-rfsoc daemon.

`Backend` is what the control protocol (protocol.py) drives; its
implementation is `HwBackend` (hw_backend.py), the real board: pynq overlay,
RfdcTask bring-up, eth100g streamer + CMAC. It follows the FPGA semantics
(Protocol §4 "Granularity", §9, §10): spp is a whole number of 64-byte words
of the OTW format (16 sc16, 32 sc8, 64 sc12, 8 fc32 slots) and of N,
num_done bursts are rounded UP to that granule, a timed start begins at the
fabric beat containing the requested time.

Channels (§9): every build streams N channels (N = 1, 2, 4, 8, 16) as ONE
stream of interleaved 32-bit slots; channel c is RFDC tile c // 4, block c % 4.
N is a block-design property, so each N is its own set of bitstreams, and
`set_channels` switches build exactly like a rate change does (to that N's
sc16-max build). Every build has its own tick rate = aggregate slot rate x
TICK_STEP (§8, §9), and the N >= 2 builds a TX and an RX beamformer (§11)
whose state the Backend keeps across reloads.

The base class holds the parts that need no hardware: rate selection, the
NCO plan of a tune request (§3b), the beamformer state machine (§11), the
sensor helpers. tests/test_protocol.py runs the protocol against a Backend
with the hardware methods stubbed.
"""
from __future__ import annotations

import glob
import logging
import math
import os
import sys
from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Tuple

import rx_beamformer
import tx_beamformer
import vrt

log = logging.getLogger("uhd_rfsoc.backend")

STREAM_MODES = ("start_cont", "stop_cont", "num_done", "num_more")

# Gen3 RFDC (ZU49DR / ZU48DR) converter capabilities
DSA_MAX_DB, DSA_STEP_DB = 27.0, 1.0          # Gen3 production silicon DSA
VOP_MIN_UA, VOP_MAX_UA = 2250, 40500         # Gen3 DAC VOP current range
NCO_BITS = 48
# udp_streamer / udp_player TICK_STEP of every build (Protocol §8): one
# timekeeper tick per 32-bit slot. HwBackend reads the real value from each
# .hwh; this is the value for a .hwh without the cores.
TICK_STEP = 1
# udp_player FC_INTERVAL: an async flow-control update at least every 512
# consumed 64-byte words (32 KiB) while a burst plays. Small against the
# 2 MiB buffer (32752 words of credit), so the host's credit is never stale by
# more than 1.6 % of it; ~27 us of play-out at 1200 MS/s sc16 (~37 k status
# packets/s at the fastest rate, a negligible load on the 100G link).
DEFAULT_FC_INTERVAL = 512


def default_fc_interval(tx_buf_words: int) -> int:
    """udp_player FC_INTERVAL the daemon programs: DEFAULT_FC_INTERVAL (512)
    words, or 1/8 of a buffer too small for that; $UHD_RFSOC_FC_INTERVAL
    overrides it (measurements). 0 if the build has no TX buffer."""
    env = os.environ.get("UHD_RFSOC_FC_INTERVAL")
    if env:
        return max(1, int(env))
    if not tx_buf_words:
        return 0
    return min(DEFAULT_FC_INTERVAL, max(1, int(tx_buf_words) // 8))


def link_problem(fmt: str, nch: int, rate: float, beat_bits: int = 0,
                 direction: str = "rx") -> Optional[str]:
    """Why OTW format `fmt` cannot carry an N-channel stream at `rate` per
    channel (Protocol §10), or None if it can:
    * the aggregate wire rate N x rate x bytes/slot exceeds the 100GbE
      payload capacity (vrt.LINK_PAYLOAD_BYTES_PER_S);
    * RX fc32 on a 512-bit-beat build (udp_streamer would need two FIFO words
      per clock: it drops every packet);
    * anything but sc8 on a 1024-bit-beat build (one beat is exactly one sc8
      wire word per clock, Protocol §10; the cores allow it, no shipped
      build has one)."""
    need = vrt.otw_wire_rate(fmt, int(nch) * float(rate))
    if need > vrt.LINK_PAYLOAD_BYTES_PER_S:
        return (f"otw={fmt}: {int(nch)} ch x {float(rate) / 1e6:g} MS/s x "
                f"{vrt.OTW_SLOT_BYTES[fmt]} B = {need / 1e9:.3f} GB/s exceeds the 100GbE "
                f"payload capacity {vrt.LINK_PAYLOAD_BYTES_PER_S / 1e9:.2f} GB/s")
    if int(beat_bits) >= 1024 and fmt != "sc8":
        return (f"otw={fmt}: a 1024-bit-beat build carries sc8 only "
                f"(udp_streamer / udp_player move one sc8 word per clock)")
    if direction == "rx" and fmt == "fc32" and int(beat_bits) >= 512:
        return ("otw=fc32: RX fc32 is not supported on a 512-bit-beat build "
                "(udp_streamer would need two FIFO words per clock)")
    return None


def default_rate(nch: int, rates: List[float]) -> float:
    """The rate `set_channels` loads for N channels: the sc16-max build, i.e.
    the highest rate whose sc16 stream fits the link (ZCU216 fs 2500: 1ch
    and 2ch 1250, 4ch 625, 8ch 312.5, 16ch 156.25 MS/s); the lowest rate
    if none does."""
    if not rates:
        raise BackendError(f"no {nch}-channel build")
    ok = [r for r in rates if link_problem("sc16", nch, r) is None]
    return max(ok) if ok else min(rates)


def find_lib_root(start: str) -> Optional[str]:
    """Nearest ancestor of `start` that contains rfsoc_lib/rfdc_task.py."""
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "rfsoc_lib", "rfdc_task.py")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _rfsoc_beamformer_class():
    """rfsoc_lib.dsp.beamformer.Beamformer from this repository (the same
    rfsoc_lib HwBackend brings the RFDC up with). Pure numpy: no pynq."""
    try:
        from rfsoc_lib.dsp.beamformer import Beamformer
        return Beamformer
    except ImportError:
        pass
    root = find_lib_root(os.path.dirname(os.path.abspath(__file__)))
    if not root:
        raise BackendError("cannot find rfsoc_lib (rfsoc_lib/dsp/beamformer.py) above "
                           "the daemon's directory")
    if root not in sys.path:
        sys.path.insert(0, root)
    from rfsoc_lib.dsp.beamformer import Beamformer
    return Beamformer


def steering_weights(nch: int, angle_deg: float, carrier_freq: float,
                     element_spacing: float) -> List[Tuple[int, int]]:
    """Protocol §11: Q1.15 weights (re, im) of a ULA steered to
    `angle_deg`, exactly rfsoc_lib's Beamformer.compute_weights_fixed_point."""
    bf = _rfsoc_beamformer_class()(num_channels=int(nch),
                                   element_spacing=float(element_spacing),
                                   carrier_freq=float(carrier_freq))
    re, im = bf.compute_weights_fixed_point(float(angle_deg))
    return [(int(r), int(i)) for r, i in zip(re, im)]


# --------------------------------------------------------------------------
# Converter arithmetic
# --------------------------------------------------------------------------

def coerce_nco(freq_hz: float, fs_hz: float) -> float:
    """`freq_hz` on the 48-bit NCO grid of a converter at `fs_hz`."""
    step = fs_hz / float(1 << NCO_BITS)
    return round(freq_hz / step) * step


def nyquist_plan(freq_hz: float, fs_hz: float) -> Tuple[int, int, float]:
    """(zone number 1.., driver zone 1=odd/2=even, frequency folded into [0, fs)).

    Folding by whole multiples of fs keeps the zone parity, and the xrfdc
    driver takes the parity (XRFDC_ODD/EVEN_NYQUIST_ZONE) plus an NCO value
    within [-fs, fs] and handles the even-zone spectral inversion itself.
    """
    half = fs_hz / 2.0
    zone = int(math.floor(freq_hz / half)) + 1 if freq_hz > 0 else 1
    if freq_hz > 0 and freq_hz % half == 0:
        zone -= 1          # exactly fs/2 belongs to zone 1, fs to zone 2 ...
    folded = math.fmod(freq_hz, fs_hz)
    return zone, (1 if zone % 2 else 2), folded


def ticks_per_sample(tick_rate: float, rate: float) -> int:
    """Timekeeper ticks per sample; must be a whole number (F even)."""
    r = tick_rate / rate
    n = int(round(r))
    if n < 1 or abs(r - n) > 1e-9 * r:
        raise ValueError(f"rate {rate:.17g} is not tick_rate {tick_rate:.17g} / "
                         f"an integer (ticks per sample {r})")
    return n


def coerce_rate(rates: List[float], hz: float) -> float:
    """The highest of `rates` at or below `hz` (1 ppm tolerance, so a request
    for a rate the build delivers to the last digit still matches it); below
    every rate, the lowest. Each rate is a bitstream (one RFDC factor), so a
    request is met from below: the bandwidth never exceeds what the client
    asked for."""
    if not rates:
        raise BackendError("no sample rate available")
    below = [r for r in rates if r <= float(hz) * (1 + 1e-6)]
    return max(below) if below else min(rates)


def tx_gain_range() -> Tuple[float, float, float]:
    return (20.0 * math.log10(VOP_MIN_UA / VOP_MAX_UA), 0.0, 0.1)


def vop_ua_for_gain(gain_db: float) -> int:
    ua = VOP_MAX_UA * 10.0 ** (gain_db / 20.0)
    return int(round(min(VOP_MAX_UA, max(VOP_MIN_UA, ua))))


def gain_for_vop_ua(ua: float) -> float:
    return 20.0 * math.log10(max(float(ua), 1.0) / VOP_MAX_UA)


def read_sysmon_temp(kind: str = "ps") -> Optional[float]:
    """PS/PL temperature in deg C from the AMS iio device (sysfs, read-only)."""
    for dev in glob.glob("/sys/bus/iio/devices/iio:device*"):
        try:
            with open(os.path.join(dev, "name")) as f:
                if f.read().strip() != "ams":
                    continue
            base = glob.glob(os.path.join(dev, f"in_temp*_{kind}_temp_raw"))
            if not base:
                return None
            stem = base[0][:-len("_raw")]
            vals = []
            for suffix in ("_raw", "_offset", "_scale"):
                with open(stem + suffix) as f:
                    vals.append(float(f.read().strip()))
            raw, off, scale = vals
            return (raw + off) * scale / 1000.0
        except (OSError, ValueError):
            continue
    return None


class BackendError(Exception):
    """A request the device cannot honour; becomes `ERR <msg>`."""


# --------------------------------------------------------------------------
# Interface
# --------------------------------------------------------------------------

class Backend(ABC):
    """What the control protocol needs from a device."""

    fpga_name: str = "none"
    num_channels: int = 1         # N: channels in the loaded build (§9)
    adc_rate: float = 2.5e9
    dac_rate: float = 2.5e9
    rx_decim: int = 2
    tx_interp: int = 2
    data_width: int = 8           # RFDC Data_Width (HwBackend: the build's)

    @property
    def num_rx(self) -> int:
        return self.num_channels

    @property
    def num_tx(self) -> int:
        return self.num_channels

    @property
    def tick_step(self) -> int:
        """Timekeeper ticks per 32-bit slot of the LOADED build (udp_streamer
        TICK_STEP; HwBackend reads it from the .hwh)."""
        return TICK_STEP

    @property
    def tick_rate(self) -> float:
        """UHD tick rate of the LOADED build = aggregate slot rate x
        TICK_STEP = N x per-channel rate (TICK_STEP 1 on every build: 1.25 GHz
        at 1ch F2, 5.0 GHz on the ZCU216 4-16ch templates at their top rate,
        2.5 GHz at their fastest sc16 rate). It can
        differ between two builds of one N, so a host re-reads it after every
        set_channels / set_rx_rate (both replies carry it)."""
        return self.num_channels * self.samp_rate * self.tick_step

    # -- channels (§9) ------------------------------------------------------
    def channel_counts(self) -> List[int]:
        """Every channel count some installed build offers, ascending."""
        return [self.num_channels]

    def set_channels(self, n: int) -> Tuple[int, float]:
        """Switch to the build with n channels (reloads the FPGA if n differs
        from the loaded one). -> (n, tick_rate now in effect)."""
        n = int(n)
        counts = self.channel_counts()
        if n not in counts:
            raise BackendError(f"no {n}-channel build installed (have "
                               f"{','.join(str(c) for c in counts)})")
        if n != self.num_channels:
            self._switch_channels(n)
        return self.num_channels, self.tick_rate

    def _switch_channels(self, n: int) -> None:
        raise BackendError(f"this device has one channel count ({self.num_channels})")

    @property
    def ticks_per_slot(self) -> int:
        """Timekeeper ticks per 32-bit slot of the stream (§4 tps, §9)."""
        return self.tick_step

    @property
    def beat_slots(self) -> int:
        """Slots per converter fabric beat: N x Data_Width/2 (128 bit = 4
        slots on the 1ch builds, up to 512 bit = 16 slots; HwBackend: the
        loaded build's)."""
        return self.num_channels * self.data_width // 2

    @property
    def beat_bits(self) -> int:
        return 32 * self.beat_slots

    def build_props(self, rate: float) -> Dict[str, object]:
        """What the build of the CURRENT channel count at `rate` (one of
        available_rates()) would give: tick_rate, beat_bits, bf / rbf (has a
        TX / RX beamformer). Used to vet a rate change before the reload."""
        return {"tick_rate": self.num_channels * float(rate) * self.tick_step,
                "beat_bits": self.beat_bits, "bf": self.has_bf, "rbf": self.has_rbf}

    def default_rate(self, n: Optional[int] = None) -> float:
        """The per-channel rate set_channels(n) loads (sc16-max build)."""
        return default_rate(self.num_channels if n is None else n,
                            self.rates_for(self.num_channels if n is None else n))

    def rates_for(self, n: int) -> List[float]:
        """Per-channel rates of the installed n-channel builds, descending."""
        return self.available_rates() if n == self.num_channels else []

    @property
    def slot_granule(self) -> int:
        """spp / burst granularity in slots of sc16: multiple of 16 and of N."""
        return vrt.slot_granule(self.num_channels)

    def otw_granule(self, otw: str = "sc16") -> int:
        """§10: whole 64-byte words of the format and a multiple of N."""
        return vrt.otw_granule(otw, self.num_channels)

    def otw_formats(self) -> List[str]:
        """§10 formats the loaded build converts (FPGA FMT registers)."""
        return ["sc16"]

    # -- rates ---------------------------------------------------------------
    # A rate is a converter factor: of a template build at run time, or of a
    # separate fixed bitstream (Protocol §8). RX and TX share the factor,
    # so the two directions always run at the same rate.
    @property
    def samp_rate(self) -> float:
        """Current complex sample rate (both directions)."""
        return self.adc_rate / self.rx_decim

    @property
    def ticks_per_sample(self) -> int:
        """Ticks between two samples of ONE channel (= N slots)."""
        return ticks_per_sample(self.tick_rate, self.samp_rate)

    def available_rates(self) -> List[float]:
        """Per-channel rates the installed builds with the CURRENT channel
        count deliver, descending (rate changes stay within one N, §9)."""
        return [self.samp_rate]

    def rx_rates(self, ch: int) -> List[float]:
        return self.available_rates()

    def tx_rates(self, ch: int) -> List[float]:
        return self.available_rates()

    def coerce_rate(self, hz: float) -> float:
        return coerce_rate(self.available_rates(), hz)

    def set_rate(self, hz: float) -> float:
        """Coerce to the highest available rate at or below `hz` (else the
        lowest: coerce_rate); switch variant if needed.
        Returns the rate now in effect (both directions)."""
        target = self.coerce_rate(hz)
        if target != self.samp_rate:
            self._switch_rate(target)
        return self.samp_rate

    def _switch_rate(self, rate: float) -> None:
        raise BackendError(f"this device has one rate ({self.samp_rate:.17g})")

    def set_rx_rate(self, ch: int, hz: float) -> float:
        return self.set_rate(hz)

    def get_rx_rate(self, ch: int) -> float:
        return self.samp_rate

    def set_tx_rate(self, ch: int, hz: float) -> float:
        return self.set_rate(hz)

    def get_tx_rate(self, ch: int) -> float:
        return self.samp_rate

    # -- tuning / gain -----------------------------------------------------
    # Tuning is limited to the first Nyquist zone, 0 .. fs/2 of the raw
    # converter rate (a design choice): the fine-mixer NCO runs
    # within +-fs/2, and zones 2+ (undersampling, mirrored spectrum, the DAC's
    # sinc roll-off) are not offered. A request outside is clamped.
    def rx_freq_range(self, ch: int) -> Tuple[float, float]:
        return (0.0, self.adc_rate / 2.0)

    def tx_freq_range(self, ch: int) -> Tuple[float, float]:
        return (0.0, self.dac_rate / 2.0)

    def rx_gain_range(self, ch: int) -> Tuple[float, float, float]:
        return (-DSA_MAX_DB, 0.0, DSA_STEP_DB)

    def tx_gain_range(self, ch: int) -> Tuple[float, float, float]:
        return tx_gain_range()

    @abstractmethod
    def set_rx_freq(self, ch: int, hz: float) -> float: ...
    @abstractmethod
    def get_rx_freq(self, ch: int) -> float: ...
    @abstractmethod
    def set_tx_freq(self, ch: int, hz: float) -> float: ...
    @abstractmethod
    def get_tx_freq(self, ch: int) -> float: ...
    @abstractmethod
    def set_rx_gain(self, ch: int, db: float) -> float: ...
    @abstractmethod
    def get_rx_gain(self, ch: int) -> float: ...
    @abstractmethod
    def set_tx_gain(self, ch: int, db: float) -> float: ...
    @abstractmethod
    def get_tx_gain(self, ch: int) -> float: ...

    # -- tune requests: RF "LO" + DSP offset folded into the one NCO ------------
    # Protocol §3b. A UHD tune request has an RF part (the frontend's LO)
    # and a DSP part (the DDC/DUC CORDIC offset). The RFDC has ONE mixer per
    # channel, the fine NCO, so the daemon keeps the two parts and programs
    # the NCO to the frequency they make together, with UHD's signs:
    #   RX: centre = rf - dsp      TX: centre = rf + dsp
    # The centre stays in the first Nyquist zone (0 .. fs/2, clamped) and on
    # the NCO's 48-bit grid; the DSP offset reported back is whatever makes
    # rf -/+ dsp equal the centre actually programmed. get_*_freq returns rf,
    # get_*_dsp_freq the offset; with no offset rf IS the NCO frequency.
    def _dsp_mem(self, kind: str) -> Dict[int, float]:
        m = getattr(self, "_dsp_offsets", None)
        if m is None:
            m = self._dsp_offsets = {"rx": {}, "tx": {}}
        return m[kind]

    def get_dsp_freq(self, kind: str, ch: int) -> float:
        return self._dsp_mem(kind).get(int(ch), 0.0)

    def get_rf_freq(self, kind: str, ch: int) -> float:
        """The tune request's RF part: NCO centre +/- the DSP offset."""
        centre = self.get_rx_freq(ch) if kind == "rx" else self.get_tx_freq(ch)
        dsp = self.get_dsp_freq(kind, ch)
        return centre + dsp if kind == "rx" else centre - dsp

    def plan_freq(self, kind: str, ch: int, rf: float, dsp: float = 0.0
                  ) -> Tuple[float, float, float]:
        """-> (rf, dsp, NCO centre) a request would give (nothing changes)."""
        lo, hi = self.rx_freq_range(ch) if kind == "rx" else self.tx_freq_range(ch)
        fs = self.adc_rate if kind == "rx" else self.dac_rate
        rf = min(hi, max(lo, float(rf)))
        half = self.samp_rate / 2.0
        dsp = min(half, max(-half, float(dsp)))
        centre = rf - dsp if kind == "rx" else rf + dsp
        centre = min(hi, coerce_nco(min(hi, max(lo, centre)), fs))
        if dsp == 0.0:
            return centre, 0.0, centre        # rf IS the NCO frequency
        dsp = rf - centre if kind == "rx" else centre - rf
        return rf, dsp, centre

    def apply_freqs(self, kind: str, items) -> List[Tuple[float, float]]:
        """Tune several channels of one direction together: items are
        (ch, rf, dsp). -> [(rf, dsp)] in effect. HwBackend programs the NCOs
        as one batch and resets their phases together (§3b)."""
        out = []
        with self._lock:
            for ch, rf, dsp in items:
                rf_a, dsp_a, centre = self.plan_freq(kind, ch, rf, dsp)
                (self.set_rx_freq if kind == "rx" else self.set_tx_freq)(ch, centre)
                self._dsp_mem(kind)[int(ch)] = dsp_a
                out.append((rf_a, dsp_a))
        return out

    def plan_gain(self, kind: str, ch: int, db: float) -> float:
        """The gain a set_*_gain would give (nothing changes)."""
        lo, hi, step = self.rx_gain_range(ch) if kind == "rx" else self.tx_gain_range(ch)
        if hi <= lo:
            return lo
        if kind == "rx":
            atten = min(-lo, max(0.0, -float(db)))
            return -(round(atten / step) * step) + 0.0
        return gain_for_vop_ua(vop_ua_for_gain(float(db)))

    def lo_locked(self, kind: str, ch: int) -> bool:
        """The converter tile clock of channel ch (its "LO": the NCO runs
        on the tile's sample clock)."""
        return True

    def rx_antennas(self, ch: int) -> List[str]:
        return ["RX"]

    def tx_antennas(self, ch: int) -> List[str]:
        return ["TX"]

    # -- time ----------------------------------------------------------------
    @abstractmethod
    def set_time(self, ticks: int) -> None: ...
    @abstractmethod
    def get_time(self) -> int: ...

    # -- streaming -----------------------------------------------------------
    @abstractmethod
    def stream_setup(self, ch: int, host_ip: str, host_mac: str,
                     port_base: int, nports: int, spp: int,
                     pattern: bool, otw: str = "sc16") -> Tuple[int, int]: ...

    @abstractmethod
    def stream_cmd(self, ch: int, mode: str, num_samps: int, now: bool,
                   time_ticks: int, cont: bool = False) -> str:
        """Queue one RX stream command (Protocol §4a). -> rx_cmdq.NEW
        (its own burst) or rx_cmdq.CONT (it continued an open num_more
        chain: no new SOB)."""

    # RX stream-command FIFO (rx_cmdq.py) over the backend's one-slot
    # streamer (the rxhw_* methods); created on first use
    rx_chain_grace_s: float = 0.001

    def rx_queue(self):
        q = getattr(self, "_rxq", None)
        if q is None:
            from rx_cmdq import RxCommandQueue
            q = self._rxq = RxCommandQueue(self, self._lock,
                                           chain_grace_s=self.rx_chain_grace_s)
        return q

    @abstractmethod
    def stop_streaming(self) -> None: ...

    # -- TX (host -> DAC), Protocol §6-7 -----------------------------------
    tx_buf_words: int = 0
    fc_interval: int = 0

    @abstractmethod
    def stream_setup_tx(self, ch: int, host_ip: str, host_mac: str,
                        async_port: int, otw: str = "sc16") -> Tuple[int, int, int]:
        """-> (tx_buf_words, fc_interval, consumed_words baseline).

        The FPGA's consumed-word count is free-running (only a reset clears
        it); the host must take the baseline from here."""

    @abstractmethod
    def stream_stop_tx(self, ch: int) -> None: ...

    @abstractmethod
    def is_streaming(self) -> bool: ...

    # -- TX and RX beamformers (Protocol §11, N >= 2 builds) ----------------
    # The daemon keeps each beamformer's state: enable, the ULA geometry for
    # angle steering, the last angle (None after raw weights), the weights and
    # (RX) the SHIFT. It is re-applied after every reload to a build that has
    # that beamformer (an angle is re-computed for the new N; raw weights and
    # an explicit SHIFT of another N fall back to unity / log2(N)) and reset to
    # bypass + unity + the default geometry when the claim is released.
    # `kind` is "tx" (eth100g/tx_beamformer, commands *_bf*) or "rx"
    # (eth100g/rx_beamformer, commands *_rbf*).
    @property
    def has_bf(self) -> bool:
        return False

    @property
    def has_rbf(self) -> bool:
        return False

    def _bfk_has(self, kind: str) -> bool:
        return self.has_bf if kind == "tx" else self.has_rbf

    def _bfk(self, kind: str) -> dict:
        attr = "_bf_state" if kind == "tx" else "_rbf_state"
        st = getattr(self, attr, None)
        if st is None:
            st = {"enable": False, "angle": None,
                  "carrier_freq": tx_beamformer.DEFAULT_CARRIER_FREQ,
                  "element_spacing": tx_beamformer.DEFAULT_ELEMENT_SPACING,
                  "weights": None, "shift": None}
            setattr(self, attr, st)
        return st

    def _bfk_need(self, kind: str) -> dict:
        if not self._bfk_has(kind):
            n = self.num_channels
            if kind == "tx":
                raise BackendError(f"no TX beamformer in {self.fpga_name} (the N >= 2 "
                                   f"builds have one; this is N = {n})")
            raise BackendError(
                f"no RX beamformer in {self.fpga_name} (eth100g/rx_beamformer is in the "
                f"N >= 2 builds that carry it; this is N = {n}"
                + (", a bitstream without it)" if n > 1 else ")"))
        return self._bfk(kind)

    def _bfk_weights(self, kind: str) -> List[Tuple[int, int]]:
        w = self._bfk(kind)["weights"]
        if w is None or len(w) != self.num_channels:
            return [tx_beamformer.UNITY] * self.num_channels
        return list(w)

    def _rbf_shift(self) -> int:
        """SHIFT in effect: the one set for this N, else log2(N) (the reset value)."""
        sh = self._bfk("rx")["shift"]
        if sh is None or sh[0] != self.num_channels:
            return rx_beamformer.default_shift(self.num_channels)
        return sh[1]

    def _bfk_apply(self, kind: str, enable: bool, weights: List[Tuple[int, int]]) -> None:
        if kind == "tx":
            self._bf_write(enable, weights)
        else:
            self._rbf_write(enable, weights, self._rbf_shift())

    def _bf_write(self, enable: bool, weights: List[Tuple[int, int]]) -> None:
        """TX: put enable + weights into the datapath (HwBackend: registers)."""

    def _rbf_write(self, enable: bool, weights: List[Tuple[int, int]], shift: int) -> None:
        """RX: put enable + weights + SHIFT into the datapath (HwBackend:
        registers)."""

    def _bfk_get(self, kind: str) -> dict:
        st = self._bfk_need(kind)
        d = {"enable": bool(st["enable"]), "angle_deg": st["angle"],
             "carrier_freq": st["carrier_freq"],
             "element_spacing": st["element_spacing"],
             "weights": self._bfk_weights(kind)}
        if kind == "rx":
            d["shift"] = self._rbf_shift()
        return d

    def _bfk_set_enable(self, kind: str, on: bool) -> bool:
        st = self._bfk_need(kind)
        self._bfk_apply(kind, bool(on), self._bfk_weights(kind))
        st["enable"] = bool(on)
        return st["enable"]

    def _bfk_set_params(self, kind: str, carrier_freq: float, element_spacing: float) -> None:
        st = self._bfk_need(kind)
        if not (carrier_freq > 0 and element_spacing > 0):
            raise BackendError("carrier_freq and element_spacing must be > 0")
        st["carrier_freq"], st["element_spacing"] = float(carrier_freq), float(element_spacing)
        if st["angle"] is not None:          # keep the beam where it was pointed
            self._bfk_set_angle(kind, st["angle"])

    def _bfk_set_angle(self, kind: str, angle_deg: float) -> List[Tuple[int, int]]:
        st = self._bfk_need(kind)
        w = steering_weights(self.num_channels, angle_deg, st["carrier_freq"],
                             st["element_spacing"])
        self._bfk_apply(kind, st["enable"], w)
        st["weights"], st["angle"] = w, float(angle_deg)
        return w

    def _bfk_set_weights(self, kind: str, weights: List[Tuple[int, int]]) -> None:
        st = self._bfk_need(kind)
        if len(weights) != self.num_channels:
            raise BackendError(f"need {self.num_channels} complex weights, got {len(weights)}")
        w = [(int(r), int(i)) for r, i in weights]
        for r, i in w:
            if not (-32768 <= r <= 32767 and -32768 <= i <= 32767):
                raise BackendError(f"weight ({r}, {i}) is not Q1.15 int16")
        self._bfk_apply(kind, st["enable"], w)
        st["weights"], st["angle"] = w, None

    def _bfk_restore(self, kind: str) -> None:
        if not self._bfk_has(kind):
            return
        st = self._bfk(kind)
        if st["angle"] is not None:
            st["weights"] = steering_weights(self.num_channels, st["angle"],
                                             st["carrier_freq"], st["element_spacing"])
        self._bfk_apply(kind, st["enable"], self._bfk_weights(kind))

    def _bfk_reset(self, kind: str) -> None:
        setattr(self, "_bf_state" if kind == "tx" else "_rbf_state", None)
        if self._bfk_has(kind):
            self._bfk_apply(kind, False, self._bfk_weights(kind))

    # TX: DAC c gets TX channel 0 x w[c]
    def bf_get(self) -> dict:
        return self._bfk_get("tx")

    def bf_set_enable(self, on: bool) -> bool:
        return self._bfk_set_enable("tx", on)

    def bf_set_params(self, carrier_freq: float, element_spacing: float) -> None:
        self._bfk_set_params("tx", carrier_freq, element_spacing)

    def bf_set_angle(self, angle_deg: float) -> List[Tuple[int, int]]:
        return self._bfk_set_angle("tx", angle_deg)

    def bf_set_weights(self, weights: List[Tuple[int, int]]) -> None:
        self._bfk_set_weights("tx", weights)

    def bf_restore(self) -> None:
        """After a reload: the kept state into the new build's beamformers."""
        self._bfk_restore("tx")
        self._bfk_restore("rx")

    def bf_reset(self) -> None:
        """Bypass and unity weights, geometry back to the defaults, for both
        beamformers (claim released: the next client starts from plain
        N-channel TX and RX)."""
        self._bfk_reset("tx")
        self._bfk_reset("rx")

    # RX: channel 0 of the RX stream carries sum_c x_c w[c] >> (15 + SHIFT)
    def rbf_get(self) -> dict:
        return self._bfk_get("rx")

    def rbf_set_enable(self, on: bool) -> bool:
        return self._bfk_set_enable("rx", on)

    def rbf_set_params(self, carrier_freq: float, element_spacing: float) -> None:
        self._bfk_set_params("rx", carrier_freq, element_spacing)

    def rbf_set_angle(self, angle_deg: float) -> List[Tuple[int, int]]:
        return self._bfk_set_angle("rx", angle_deg)

    def rbf_set_weights(self, weights: List[Tuple[int, int]]) -> None:
        self._bfk_set_weights("rx", weights)

    def rbf_set_shift(self, shift: int) -> int:
        st = self._bfk_need("rx")
        shift = int(shift)
        if not 0 <= shift <= rx_beamformer.SHIFT_MAX:
            raise BackendError(f"shift {shift} not in 0..{rx_beamformer.SHIFT_MAX}")
        self._rbf_write(st["enable"], self._bfk_weights("rx"), shift)
        st["shift"] = (self.num_channels, shift)
        return shift

    # -- sensors / clocks / stats --------------------------------------------
    @abstractmethod
    def list_sensors(self) -> List[str]: ...

    @abstractmethod
    def get_sensor(self, name: str) -> Tuple[str, str, str]:
        """(type, value, unit); type in bool/real/int/string."""

    def clock_sources(self) -> List[str]:
        return ["internal"]

    def time_sources(self) -> List[str]:
        return ["internal"]

    @abstractmethod
    def set_clock_source(self, src: str) -> None: ...
    @abstractmethod
    def get_clock_source(self) -> str: ...

    def set_time_source(self, src: str) -> None:
        if src not in self.time_sources():
            raise BackendError(f"unsupported time source {src}")
        self._time_source = src

    def get_time_source(self) -> str:
        return getattr(self, "_time_source", "internal")

    @abstractmethod
    def stats(self) -> Dict[str, object]: ...

    def close(self) -> None:
        for fn in (self.stop_streaming, lambda: self.stream_stop_tx(0)):
            try:
                fn()
            except Exception:  # pragma: no cover
                log.exception("stop during close")
        q = getattr(self, "_rxq", None)
        if q is not None:
            q.close()


def bool_sensor(value: bool, true_unit: str, false_unit: str) -> Tuple[str, str, str]:
    return ("bool", "true" if value else "false",
            true_unit if value else false_unit)
