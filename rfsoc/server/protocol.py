"""Control protocol of the ZCU216 UHD daemon (Protocol §2-3, §6-7 commands).

Transport-free: `ControlCore.handle_line(session, line)` takes one request line
and returns one reply line (without the newline). The TCP/UDP servers in
zcu216_uhd_daemon.py feed it, and the unit tests call it directly.

Every reply is `OK [values]` or `ERR <message>`; no request can raise out of
handle_line.
"""
from __future__ import annotations

import ipaddress
import itertools
import logging
import re
import threading
from typing import Callable, Dict, List, Optional, Tuple

import vrt
from backend import Backend, BackendError, STREAM_MODES, coerce_rate, link_problem
from cmd_timer import CommandTimer
from rx_cmdq import CONT

log = logging.getLogger("zcu216.protocol")

PROTO_VERSION = 1
DISC_REQUEST = "ZCU216-DISC?"
DISC_PREFIX = "ZCU216-DISC"
MAX_LINE = 4096
MTU = 9000
MAX_NPORTS = 64

_MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$")


def fmt_float(x: float) -> str:
    return "%.17g" % float(x)


class ProtocolError(Exception):
    """Malformed request; becomes `ERR <msg>`."""


class Session:
    """One control connection."""
    _ids = itertools.count(1)

    def __init__(self, peer: str = "?", local_ip: str = "0.0.0.0"):
        self.id = next(self._ids)
        self.peer = peer
        self.local_ip = local_ip

    def __repr__(self):
        return f"Session#{self.id}({self.peer})"


# -- argument parsing -----------------------------------------------------------

def _int(s: str, name: str, lo: Optional[int] = None, hi: Optional[int] = None) -> int:
    try:
        v = int(s, 10)
    except (TypeError, ValueError):
        raise ProtocolError(f"bad {name} '{s}'")
    if lo is not None and v < lo or hi is not None and v > hi:
        raise ProtocolError(f"{name} {v} out of range")
    return v


def _float(s: str, name: str) -> float:
    try:
        v = float(s)
    except (TypeError, ValueError):
        raise ProtocolError(f"bad {name} '{s}'")
    if v != v or v in (float("inf"), float("-inf")):
        raise ProtocolError(f"bad {name} '{s}'")
    return v


def _ipv4(s: str) -> str:
    try:
        return str(ipaddress.IPv4Address(s))
    except (ipaddress.AddressValueError, ValueError):
        raise ProtocolError(f"bad IPv4 address '{s}'")


def _mac(s: str) -> str:
    if not _MAC_RE.match(s):
        raise ProtocolError(f"bad MAC '{s}'")
    return s.lower()


def _port(s: str, name: str) -> int:
    return _int(s, name, 1, 65535)


# Antenna names UHD applications commonly pass (USRP port names). Each
# converter channel has ONE port, so any of these selects it; the reply names
# the real port (Protocol §3).
ANTENNA_ALIASES = {
    "rx": ("RX", "RX1", "RX2", "TX/RX", "RX/TX", "TRX", "IN", "RF", "A"),
    "tx": ("TX", "TX1", "TX2", "TX/RX", "RX/TX", "TRX", "OUT", "RF", "A"),
}


class ControlCore:
    """Command dispatcher + claim ownership, shared by all connections."""

    def __init__(self, backend: Backend, serial: str, name: str,
                 data_ip: str, data_mac: str, mgmt_ip: str = ""):
        self.be = backend
        self.serial, self.name = serial, name
        self.data_ip, self.data_mac = data_ip, data_mac
        self.mgmt_ip = mgmt_ip
        self.lock = threading.RLock()
        self.owner: Optional[Session] = None
        self._spp = vrt.DEFAULT_SPP         # info spp=: in sc16 slots
        # §10 formats: of the RX / TX stream setups (re-applied after a
        # reload), and the client's declared one (the last otw= it sent, on a
        # stream setup or set_rx_rate). A rate change must fit all of them.
        self._rx_otw = "sc16"
        self._tx_otw = "sc16"
        self._otw_pref = "sc16"
        self._rx_setup = False
        self._tx_setup = False
        self._antenna_rx = {}
        self._antenna_tx = {}
        # §3c: set_*_freq / set_*_gain at=<ticks>, run by the FPGA timekeeper
        self.timer = CommandTimer(lambda: self.be.get_time(),
                                  lambda: self.be.tick_rate, self._run_timed)
        # name -> (handler, needs_claim)
        self.cmds: Dict[str, Tuple[Callable, bool]] = {
            "ping": (self._ping, False),
            "info": (self._info, False),
            "claim": (self._claim, False),
            "unclaim": (self._unclaim, False),
            "set_channels": (self._set_channels, True),
            "get_channels": (self._get_channels, True),
            "get_rx_rates": (lambda s, a: self._rates(a, "rx"), True),
            "get_tx_rates": (lambda s, a: self._rates(a, "tx"), True),
            "set_rx_rate": (lambda s, a: self._set_rate(a, "rx"), True),
            "set_tx_rate": (lambda s, a: self._set_rate(a, "tx"), True),
            "get_rx_rate": (lambda s, a: self._get1(a, "rx", self.be.get_rx_rate), True),
            "get_tx_rate": (lambda s, a: self._get1(a, "tx", self.be.get_tx_rate), True),
            "set_rx_freq": (lambda s, a: self._set_freq(a, "rx"), True),
            "set_tx_freq": (lambda s, a: self._set_freq(a, "tx"), True),
            "get_rx_freq": (lambda s, a: self._get1(a, "rx", lambda c: self.be.get_rf_freq("rx", c)), True),
            "get_tx_freq": (lambda s, a: self._get1(a, "tx", lambda c: self.be.get_rf_freq("tx", c)), True),
            "get_rx_dsp_freq": (lambda s, a: self._get1(a, "rx", lambda c: self.be.get_dsp_freq("rx", c)), True),
            "get_tx_dsp_freq": (lambda s, a: self._get1(a, "tx", lambda c: self.be.get_dsp_freq("tx", c)), True),
            "get_rx_lo_locked": (lambda s, a: self._lo_locked(a, "rx"), True),
            "get_tx_lo_locked": (lambda s, a: self._lo_locked(a, "tx"), True),
            "get_rx_freq_range": (lambda s, a: self._range(a, "rx", self.be.rx_freq_range), True),
            "get_tx_freq_range": (lambda s, a: self._range(a, "tx", self.be.tx_freq_range), True),
            "set_rx_gain": (lambda s, a: self._set_gain(a, "rx"), True),
            "set_tx_gain": (lambda s, a: self._set_gain(a, "tx"), True),
            "get_rx_gain": (lambda s, a: self._get1(a, "rx", self.be.get_rx_gain), True),
            "get_tx_gain": (lambda s, a: self._get1(a, "tx", self.be.get_tx_gain), True),
            "get_rx_gain_range": (lambda s, a: self._range(a, "rx", self.be.rx_gain_range), True),
            "get_tx_gain_range": (lambda s, a: self._range(a, "tx", self.be.tx_gain_range), True),
            "set_rx_antenna": (lambda s, a: self._set_ant(a, "rx"), True),
            "set_tx_antenna": (lambda s, a: self._set_ant(a, "tx"), True),
            "get_rx_antenna": (lambda s, a: self._get_ant(a, "rx"), True),
            "get_tx_antenna": (lambda s, a: self._get_ant(a, "tx"), True),
            "get_rx_antennas": (lambda s, a: self._ants(a, "rx"), True),
            "get_tx_antennas": (lambda s, a: self._ants(a, "tx"), True),
            "set_time": (self._set_time, True),
            "get_time": (self._get_time, True),
            "stream_setup": (self._stream_setup, True),
            "stream_cmd": (self._stream_cmd, True),
            "stream_setup_tx": (self._stream_setup_tx, True),
            "stream_stop_tx": (self._stream_stop_tx, True),
            "get_sensor": (self._get_sensor, True),
            "list_sensors": (self._list_sensors, True),
            "get_clock_sources": (lambda s, a: self._sources(a, self.be.clock_sources), True),
            "get_time_sources": (lambda s, a: self._sources(a, self.be.time_sources), True),
            "set_clock_source": (lambda s, a: self._set_src(a, self.be.set_clock_source, self.be.get_clock_source), True),
            "set_time_source": (lambda s, a: self._set_src(a, self.be.set_time_source, self.be.get_time_source), True),
            "get_clock_source": (lambda s, a: self._get_src(a, self.be.get_clock_source), True),
            "get_time_source": (lambda s, a: self._get_src(a, self.be.get_time_source), True),
            "stats": (self._stats, True),
            "get_bf": (self._get_bf, True),
            "set_bf_enable": (self._set_bf_enable, True),
            "set_bf_params": (self._set_bf_params, True),
            "set_bf_angle": (self._set_bf_angle, True),
            "set_bf_weights": (self._set_bf_weights, True),
            "get_rbf": (self._get_rbf, True),
            "set_rbf_enable": (self._set_rbf_enable, True),
            "set_rbf_params": (self._set_rbf_params, True),
            "set_rbf_angle": (self._set_rbf_angle, True),
            "set_rbf_weights": (self._set_rbf_weights, True),
            "set_rbf_shift": (self._set_rbf_shift, True),
        }

    # -- entry points -------------------------------------------------------------
    def handle_line(self, sess: Session, line) -> str:
        try:
            if isinstance(line, (bytes, bytearray)):
                line = bytes(line).decode("utf-8")
            line = line.rstrip("\r\n")
            if len(line) > MAX_LINE:
                raise ProtocolError("line too long")
            toks = line.split(" ")
            if not line.strip():
                raise ProtocolError("empty request")
            if any(t == "" for t in toks):
                # tolerate stray whitespace rather than mis-numbering args
                toks = line.split()
            cmd, args = toks[0], toks[1:]
            entry = self.cmds.get(cmd)
            if entry is None:
                raise ProtocolError(f"unknown command '{cmd}'")
            handler, needs_claim = entry
            with self.lock:
                if needs_claim and self.owner is not sess:
                    raise ProtocolError("claimed" if self.owner is not None
                                        else "not claimed")
                return handler(sess, args)
        except (ProtocolError, BackendError) as e:
            return "ERR " + _one_line(str(e))
        except UnicodeDecodeError:
            return "ERR bad utf-8"
        except Exception as e:  # never let a request kill the daemon
            log.exception("request %r failed", line)
            return "ERR " + _one_line(f"{type(e).__name__}: {e}")

    def disconnect(self, sess: Session) -> None:
        """Connection closed: stop streaming and unclaim if it owned the device."""
        with self.lock:
            if self.owner is sess:
                log.info("%s disconnected while holding the claim: stopping "
                         "streams and unclaiming", sess)
                self._release()

    def _release(self) -> None:
        dropped = self.timer.clear()
        if dropped:
            log.info("claim released: %d pending timed command(s) dropped", dropped)
        for fn, what in ((self.be.stop_streaming, "rx"),
                         (lambda: self.be.stream_stop_tx(0), "tx")):
            try:
                fn()
            except Exception:
                log.exception("stopping %s stream on release", what)
        try:
            self.be.bf_reset()      # the next client starts from plain N-ch TX / RX
        except Exception:
            log.exception("resetting the beamformers on release")
        self.owner = None
        self._rx_setup = self._tx_setup = False
        self._rx_otw = self._tx_otw = self._otw_pref = "sc16"
        # info spp= follows the last stream_setup (in sc16 slots): reset it
        # too, or a client inherits its predecessor's (after an sc12 setup,
        # 2016 instead of 2048)
        self._spp = vrt.round_spp(vrt.DEFAULT_SPP, self.be.slot_granule)

    def discovery_reply(self, mgmt_ip: str) -> str:
        return f"{DISC_PREFIX} " + self._kv(self._disc_fields(mgmt_ip))

    # -- formatting helpers -------------------------------------------------------
    @staticmethod
    def _kv(fields: List[Tuple[str, object]]) -> str:
        return ";".join(f"{k}={v}" for k, v in fields)

    def _disc_fields(self, mgmt_ip: str) -> List[Tuple[str, object]]:
        # type is the UHD device (the protocol); product the board served
        return [("type", "zcu216"), ("product", getattr(self.be, "product", "zcu216")),
                ("serial", self.serial), ("name", self.name),
                ("addr", mgmt_ip or self.mgmt_ip),
                # no data IP (sim): the data plane lives on the management IP
                ("data_ip", self.data_ip or mgmt_ip or self.mgmt_ip),
                ("claimed", 1 if self.owner is not None else 0),
                ("fpga", self.be.fpga_name), ("version", PROTO_VERSION)]

    def _ch(self, args: List[str], idx: int, kind: str) -> int:
        if len(args) <= idx:
            raise ProtocolError("missing channel")
        n = self.be.num_rx if kind == "rx" else self.be.num_tx
        return _int(args[idx], "channel", 0, n - 1)

    @staticmethod
    def _nargs(args: List[str], n: int, usage: str) -> None:
        if len(args) != n:
            raise ProtocolError(f"usage: {usage}")

    # -- handlers -----------------------------------------------------------------
    def _ping(self, s, a):
        return "OK pong"

    def _info(self, s, a):
        rates = self.be.rx_rates(0)
        f = self._disc_fields(s.local_ip)
        f += [("num_rx", self.be.num_rx), ("num_tx", self.be.num_tx),
              ("tick_rate", fmt_float(self.be.tick_rate)),
              ("tick_step", self.be.ticks_per_slot),
              ("beat_slots", self.be.beat_slots),
              ("adc_rate", fmt_float(self.be.adc_rate)),
              ("dac_rate", fmt_float(self.be.dac_rate)),
              ("rx_rates", ",".join(fmt_float(r) for r in rates)),
              ("tx_rates", ",".join(fmt_float(r) for r in self.be.tx_rates(0))),
              # per rate of rx_rates: the tick rate of that build (it can
              # differ within one N) and the §10 formats the link carries there
              ("tick_rates", ",".join(fmt_float(self.be.build_props(r)["tick_rate"])
                                      for r in rates)),
              ("rate_otw", ",".join(f"{fmt_float(r)}:" + "+".join(self._rate_formats(r))
                                    for r in rates)),
              ("channel_counts", ",".join(str(n) for n in self.be.channel_counts())),
              ("spp", self._spp), ("mtu", MTU),
              ("data_mac", self.data_mac),
              ("tx_buf_words", self.be.tx_buf_words),
              ("fc_interval", self.be.fc_interval),
              ("otw_formats", ",".join(self.otw_formats())),
              ("rx_otw_formats", ",".join(self.otw_formats("rx"))),
              ("tx_otw_formats", ",".join(self.otw_formats("tx"))),
              ("bf", 1 if self.be.has_bf else 0),
              ("rbf", 1 if self.be.has_rbf else 0)]
        return "OK " + self._kv(f)

    # -- OTW formats (§10) --------------------------------------------------------
    def _otw_rate_error(self, fmt: str, direction: str = "rx") -> Optional[str]:
        """Why `fmt` cannot carry the loaded build's stream in `direction`
        (100GbE capacity; RX fc32 on a 512-bit beat), or None if it can."""
        return link_problem(fmt, self.be.num_channels, self.be.samp_rate,
                            self.be.beat_bits, direction)

    def otw_formats(self, direction: str = "both") -> List[str]:
        """Formats the loaded build converts AND whose stream fits the link:
        RX ("rx"), TX ("tx") or both directions ("both", info otw_formats=)."""
        dirs = ("rx", "tx") if direction == "both" else (direction,)
        return [f for f in self.be.otw_formats()
                if all(self._otw_rate_error(f, d) is None for d in dirs)]

    def _rate_formats(self, rate: float) -> List[str]:
        """§10 formats an N-channel stream at `rate` can use in both
        directions (link capacity and beat width of that build)."""
        beat = self.be.build_props(rate)["beat_bits"]
        return [f for f in vrt.OTW_FORMATS
                if link_problem(f, self.be.num_channels, rate, beat, "rx") is None]

    def _otw_option(self, tok: str, direction: str) -> str:
        fmt = tok.split("=", 1)[1]
        if fmt not in vrt.OTW_CODE:
            raise ProtocolError(f"bad option '{tok}' (want otw={'|'.join(vrt.OTW_FORMATS)})")
        if fmt not in self.be.otw_formats():
            raise ProtocolError(f"otw={fmt}: this bitstream ({self.be.fpga_name}) converts "
                                f"only {','.join(self.be.otw_formats())}")
        why = self._otw_rate_error(fmt, direction)
        if why:
            raise ProtocolError(why)
        return fmt

    def _rate_fits(self, rate: float) -> bool:
        """Whether the build at `rate` carries the client's formats."""
        try:
            self._check_rate_otw(rate, "rx")
        except ProtocolError:
            return False
        return True

    def _check_rate_otw(self, rate: float, kind: str) -> None:
        """Refuse a rate whose build cannot carry the client's formats (its
        declared otw and the formats of the stream setups that a reload
        re-applies) before anything is reloaded."""
        n = self.be.num_channels
        beat = self.be.build_props(rate)["beat_bits"]
        # the declared format: link capacity only (its direction is unknown)
        want = [(self._otw_pref, "tx", "the current otw (the last otw= the client "
                 "sent; sc16 by default)")]
        if self._rx_setup:
            want.append((self._rx_otw, "rx", "the RX stream's (stream_setup)"))
        if self._tx_setup:
            want.append((self._tx_otw, "tx", "the TX stream's (stream_setup_tx)"))
        for fmt, d, what in want:
            why = link_problem(fmt, n, rate, beat, d)
            if why:
                ok = self._rate_formats(rate)
                why = why.split(": ", 1)[1]
                raise ProtocolError(
                    f"set_{kind}_rate {fmt_float(rate)} refused: {what} is otw={fmt}, "
                    f"and in {fmt} {why}. "
                    f"{n} ch x {rate / 1e6:g} MS/s needs otw="
                    f"{' or otw='.join(ok) if ok else '<none>'}: choose it (UHD stream "
                    f"args otw_format / --wirefmt, or 'set_{kind}_rate <ch> <hz> "
                    f"otw={ok[0] if ok else 'sc8'}') and set the rate again")

    def _drop_unfit_setups(self) -> None:
        """After a build change: a stream setup whose format the new build
        cannot carry is forgotten (stream_cmd then asks for a new setup)."""
        if self._rx_setup and self._otw_rate_error(self._rx_otw, "rx"):
            log.warning("RX stream setup otw=%s does not fit %s: dropped",
                        self._rx_otw, self.be.fpga_name)
            self._rx_setup = False
        if self._tx_setup and self._otw_rate_error(self._tx_otw, "tx"):
            log.warning("TX stream setup otw=%s does not fit %s: dropped",
                        self._tx_otw, self.be.fpga_name)
            self._tx_setup = False

    def _claim(self, s, a):
        if self.owner is not None and self.owner is not s:
            raise ProtocolError("claimed")
        self.owner = s
        return "OK"

    def _unclaim(self, s, a):
        if self.owner is None:
            return "OK"
        if self.owner is not s:
            raise ProtocolError("claimed")
        self._release()
        return "OK"

    def _set_channels(self, s, a):
        """set_channels <N> [otw=<fmt>] -> OK <N> <tick_rate>. Reloads the
        FPGA (seconds, like a rate change, §8) to that N's default (sc16-max)
        build when N is not the loaded build's, or when it is but at a rate
        the current otw cannot carry; otherwise keeps the loaded build.
        otw= declares the client's format first (it becomes the current
        otw), so a client streaming sc8 keeps a loaded sc8-max build instead
        of reloading the sc16 default and then the sc8 build again."""
        if len(a) not in (1, 2):
            raise ProtocolError("usage: set_channels <N> [otw=<fmt>]")
        n = _int(a[0], "channel count", 1)
        if len(a) == 2:
            if not a[1].startswith("otw=") or a[1][4:] not in vrt.OTW_CODE:
                raise ProtocolError(f"bad option '{a[1]}' (want otw="
                                    f"{'|'.join(vrt.OTW_FORMATS)})")
            self._otw_pref = a[1][4:]
        if (n == self.be.num_channels and link_problem(
                self._otw_pref, n, self.be.samp_rate, direction="tx")):
            # this N is loaded, but at a rate the current otw cannot carry
            # (an sc8-max build left by an earlier client): its default build
            self.be.set_rate(self.be.default_rate())
        base = self._time_base()
        n, tick = self.be.set_channels(n)
        self._reloaded(base)
        self._spp = vrt.round_spp(self._spp, self.be.slot_granule)
        self._drop_unfit_setups()
        return "OK %d %s" % (n, fmt_float(tick))

    def _get_channels(self, s, a):
        self._nargs(a, 0, "get_channels")
        return "OK %d %s" % (self.be.num_channels, fmt_float(self.be.tick_rate))

    def _rates(self, a, kind):
        self._nargs(a, 1, f"get_{kind}_rates <ch>")
        ch = self._ch(a, 0, kind)
        rates = self.be.rx_rates(ch) if kind == "rx" else self.be.tx_rates(ch)
        return "OK " + " ".join(fmt_float(r) for r in rates)

    def _set_rate(self, a, kind):
        """set_<kind>_rate <ch> <hz> [otw=<fmt>] -> OK <actual hz> <tick_rate>.
        otw= declares the format the client will stream (it becomes the
        current otw); a rate whose build cannot carry the current formats is
        refused before any reload (§10)."""
        if len(a) not in (2, 3):
            raise ProtocolError(f"usage: set_{kind}_rate <ch> <hz> [otw=<fmt>]")
        ch = self._ch(a, 0, kind)
        hz = _float(a[1], "rate")
        pref = self._otw_pref
        if len(a) == 3:
            if not a[2].startswith("otw=") or a[2][4:] not in vrt.OTW_CODE:
                raise ProtocolError(f"bad option '{a[2]}' (want otw="
                                    f"{'|'.join(vrt.OTW_FORMATS)})")
            pref = a[2][4:]
        old_pref, self._otw_pref = self._otw_pref, pref
        # the highest rate at or below hz among the builds that carry the
        # client's formats (backend.coerce_rate); none carries them: refuse,
        # naming the formats that would
        fit = [r for r in self.be.available_rates() if self._rate_fits(r)]
        target = coerce_rate(fit, hz) if fit else self.be.coerce_rate(hz)
        try:
            self._check_rate_otw(target, kind)
        except ProtocolError:
            self._otw_pref = old_pref
            raise
        fn = self.be.set_rx_rate if kind == "rx" else self.be.set_tx_rate
        base = self._time_base()
        rate = fn(ch, target)
        self._reloaded(base)
        self._drop_unfit_setups()
        return "OK %s %s" % (fmt_float(rate), fmt_float(self.be.tick_rate))

    def _time_base(self) -> Tuple[str, float]:
        return (self.be.fpga_name, float(self.be.tick_rate))

    def _reloaded(self, old: Tuple[str, float]) -> None:
        """After set_channels / set_*_rate: another build, or the same build
        retuned to another rate (§8), means another time base: pending timed
        commands are dropped (§3c)."""
        if self._time_base() != old:
            n = self.timer.clear()
            if n:
                log.warning("%s at %g Hz -> %s at %g Hz: %d pending timed command(s) "
                            "dropped", old[0], old[1], self.be.fpga_name,
                            self.be.tick_rate, n)

    @staticmethod
    def _opts(a: List[str], allowed: Tuple[str, ...], usage: str) -> Dict[str, str]:
        out = {}
        for tok in a:
            k, eq, v = tok.partition("=")
            if not eq or k not in allowed or k in out:
                raise ProtocolError(f"bad option '{tok}' (usage: {usage})")
            out[k] = v
        return out

    def _set_freq(self, a, kind):
        """set_<kind>_freq <ch> <hz> [dsp=<hz>] [at=<ticks>] -> OK <rf> [<dsp>]
        (§3b: rf and the DSP offset folded into the one NCO; §3c: at= runs
        it when the timekeeper reaches <ticks>, replying with the values it
        will set)."""
        usage = f"set_{kind}_freq <ch> <hz> [dsp=<hz>] [at=<ticks>]"
        if len(a) < 2:
            raise ProtocolError(f"usage: {usage}")
        ch = self._ch(a, 0, kind)
        hz = _float(a[1], "freq")
        o = self._opts(a[2:], ("dsp", "at"), usage)
        dsp = _float(o["dsp"], "dsp") if "dsp" in o else 0.0
        if "at" in o:
            at = _int(o["at"], "at", 0, (1 << 64) - 1)
            rf, d, _centre = self.be.plan_freq(kind, ch, hz, dsp)
            self.timer.schedule(at, ("freq", kind, ch, hz, dsp))
        else:
            rf, d = self.be.apply_freqs(kind, [(ch, hz, dsp)])[0]
        return "OK " + fmt_float(rf) + (" " + fmt_float(d) if "dsp" in o else "")

    def _set_gain(self, a, kind):
        """set_<kind>_gain <ch> <db> [at=<ticks>] -> OK <db>"""
        usage = f"set_{kind}_gain <ch> <db> [at=<ticks>]"
        if len(a) < 2:
            raise ProtocolError(f"usage: {usage}")
        ch = self._ch(a, 0, kind)
        db = _float(a[1], "gain")
        o = self._opts(a[2:], ("at",), usage)
        if "at" in o:
            self.timer.schedule(_int(o["at"], "at", 0, (1 << 64) - 1),
                                ("gain", kind, ch, db))
            return "OK " + fmt_float(self.be.plan_gain(kind, ch, db))
        fn = self.be.set_rx_gain if kind == "rx" else self.be.set_tx_gain
        return "OK " + fmt_float(fn(ch, db))

    def _run_timed(self, ops, at: int = None) -> None:
        """One group of timed commands (§3c), on the timer thread: a set_time
        first (written as the value it should have had AT the group's time,
        so the timer's latency does not shift the new time base), then the
        tunes of each direction as one NCO batch, then the gains."""
        with self.lock:
            for op in ops:
                if op[0] == "time":
                    late = self.be.get_time() - at if at is not None else 0
                    self.be.set_time(op[1] + max(0, late))
            for kind in ("rx", "tx"):
                n = self.be.num_rx if kind == "rx" else self.be.num_tx
                items = [(ch, rf, dsp) for op, k, ch, rf, dsp in
                         (o for o in ops if o[0] == "freq") if k == kind and ch < n]
                if items:
                    self.be.apply_freqs(kind, items)
            for op in ops:
                if op[0] == "gain":
                    _op, kind, ch, db = op
                    if ch < (self.be.num_rx if kind == "rx" else self.be.num_tx):
                        (self.be.set_rx_gain if kind == "rx" else self.be.set_tx_gain)(ch, db)

    def _lo_locked(self, a, kind):
        """get_<kind>_lo_locked <ch> -> OK bool <true|false> <locked|unlocked>:
        the clock of that channel's converter tile (§3)."""
        self._nargs(a, 1, f"get_{kind}_lo_locked <ch>")
        v = bool(self.be.lo_locked(kind, self._ch(a, 0, kind)))
        return "OK bool %s %s" % ("true" if v else "false", "locked" if v else "unlocked")

    def _get1(self, a, kind, fn):
        self._nargs(a, 1, "<cmd> <ch>")
        return "OK " + fmt_float(fn(self._ch(a, 0, kind)))

    def _range(self, a, kind, fn):
        self._nargs(a, 1, "<cmd> <ch>")
        return "OK " + " ".join(fmt_float(x) for x in fn(self._ch(a, 0, kind)))

    def _ants(self, a, kind):
        self._nargs(a, 1, "<cmd> <ch>")
        ch = self._ch(a, 0, kind)
        return "OK " + " ".join(self.be.rx_antennas(ch) if kind == "rx"
                                else self.be.tx_antennas(ch))

    def _set_ant(self, a, kind):
        self._nargs(a, 2, f"set_{kind}_antenna <ch> <name>")
        ch = self._ch(a, 0, kind)
        names = self.be.rx_antennas(ch) if kind == "rx" else self.be.tx_antennas(ch)
        name = a[1]
        if name not in names:
            # one port per converter channel: the usual USRP names select it
            if len(names) == 1 and name.upper() in ANTENNA_ALIASES[kind]:
                name = names[0]
            else:
                raise ProtocolError(f"unsupported antenna '{a[1]}' (have {','.join(names)}; "
                                    f"aliases {','.join(ANTENNA_ALIASES[kind])})")
        (self._antenna_rx if kind == "rx" else self._antenna_tx)[ch] = name
        return "OK " + name

    def _get_ant(self, a, kind):
        self._nargs(a, 1, f"get_{kind}_antenna <ch>")
        ch = self._ch(a, 0, kind)
        names = self.be.rx_antennas(ch) if kind == "rx" else self.be.tx_antennas(ch)
        return "OK " + (self._antenna_rx if kind == "rx" else self._antenna_tx).get(ch, names[0])

    def _set_time(self, s, a):
        """set_time <ticks> [at=<ticks>]: now, or (§3c) the timekeeper reads
        <ticks> at the instant it reaches at= (the host's emulated PPS edge)"""
        usage = "set_time <ticks> [at=<ticks>]"
        if len(a) not in (1, 2):
            raise ProtocolError(f"usage: {usage}")
        t = _int(a[0], "ticks", 0, (1 << 64) - 1)
        o = self._opts(a[1:], ("at",), usage)
        if "at" in o:
            self.timer.schedule(_int(o["at"], "at", 0, (1 << 64) - 1), ("time", t))
        else:
            self.be.set_time(t)
        return "OK"

    def _get_time(self, s, a):
        self._nargs(a, 0, "get_time")
        return "OK %d" % self.be.get_time()

    def _stream_setup(self, s, a):
        if len(a) not in (6, 7, 8):
            raise ProtocolError("usage: stream_setup <ch> <host_ip> <host_mac> "
                                "<port_base> <nports> <spp> [pattern=0|1] [otw=<fmt>]")
        ch = self._ch(a, 0, "rx")
        host_ip, host_mac = _ipv4(a[1]), _mac(a[2])
        port_base = _port(a[3], "port_base")
        nports = _int(a[4], "nports", 1, MAX_NPORTS)
        if port_base + nports - 1 > 65535:
            raise ProtocolError("port_base + nports exceeds 65535")
        pattern, otw = False, "sc16"
        for tok in a[6:]:
            m = re.match(r"^pattern=([01])$", tok)
            if m:
                pattern = m.group(1) == "1"
            elif tok.startswith("otw="):
                otw = self._otw_option(tok, "rx")
            else:
                raise ProtocolError(f"bad option '{tok}' (want pattern=0|1 or otw=<fmt>)")
        # §10: whole 64-byte words of the format, a multiple of N, <= 8192 B
        spp = vrt.round_spp(_int(a[5], "spp", 1), self.be.otw_granule(otw),
                            vrt.otw_max_spp(otw))
        spp, nports = self.be.stream_setup(ch, host_ip, host_mac, port_base,
                                           nports, spp, pattern, otw=otw)
        # info spp= stays in sc16 slots (the same payload bytes)
        self._spp = vrt.round_spp(spp * vrt.OTW_SLOT_BYTES[otw] // 4, self.be.slot_granule)
        self._rx_otw = self._otw_pref = otw
        self._rx_setup = True
        return "OK %d %d" % (spp, nports)

    def _stream_cmd(self, s, a):
        """stream_cmd <ch> <mode> <num_samps> <now> <time_ticks> [cont=0|1]
        -> OK (a new burst) | OK cont (§4a: it continued the open num_more
        chain, no new SOB)."""
        usage = "stream_cmd <ch> <mode> <num_samps> <now> <time_ticks> [cont=0|1]"
        if len(a) not in (5, 6):
            raise ProtocolError(f"usage: {usage}")
        cont = False
        if len(a) == 6:
            if a[5] not in ("cont=0", "cont=1"):
                raise ProtocolError(f"bad option '{a[5]}' (usage: {usage})")
            cont = a[5] == "cont=1"
            a = a[:5]
        ch = self._ch(a, 0, "rx")
        mode = a[1]
        if mode not in STREAM_MODES:
            raise ProtocolError(f"bad mode '{mode}' (want {'|'.join(STREAM_MODES)})")
        num = _int(a[2], "num_samps", 0, (1 << 64) - 1)
        now = _int(a[3], "now", 0, 1)
        t = _int(a[4], "time_ticks", 0, (1 << 64) - 1)
        if mode in ("num_done", "num_more"):
            if num == 0:
                raise ProtocolError(f"{mode} needs num_samps > 0")
            # in SLOTS (the host multiplied by N); the FPGA works in whole
            # 64-byte words of the stream's format (§10)
            num = vrt.ceil_granule(num, self.be.otw_granule(self._rx_otw))
        if mode != "stop_cont" and not self._rx_setup:
            raise ProtocolError("stream_setup first")
        r = self.be.stream_cmd(ch, mode, num, bool(now), t, cont=cont)
        return "OK cont" if r == CONT else "OK"

    def _stream_setup_tx(self, s, a):
        if len(a) not in (4, 5):
            raise ProtocolError("usage: stream_setup_tx <ch> <host_ip> <host_mac> "
                                "<async_port> [otw=<fmt>]")
        ch = self._ch(a, 0, "tx")
        otw = "sc16"
        if len(a) == 5:
            if not a[4].startswith("otw="):
                raise ProtocolError(f"bad option '{a[4]}' (want otw=<fmt>)")
            otw = self._otw_option(a[4], "tx")
        buf, fc, base = self.be.stream_setup_tx(ch, _ipv4(a[1]), _mac(a[2]),
                                                _port(a[3], "async_port"), otw=otw)
        self._tx_otw = self._otw_pref = otw
        self._tx_setup = True
        # 3rd token: the free-running consumed-word count the host must use as
        # its flow-control baseline (udp_player.v never resets it)
        return "OK %d %d %d" % (buf, fc, base & 0xFFFFFFFF)

    def _stream_stop_tx(self, s, a):
        self._nargs(a, 1, "stream_stop_tx <ch>")
        self.be.stream_stop_tx(self._ch(a, 0, "tx"))
        self._tx_setup = False
        return "OK"

    # -- TX and RX beamformers (§11) -------------------------------------------
    # The *_bf* commands drive eth100g/tx_beamformer, the *_rbf* ones
    # eth100g/rx_beamformer; same arguments and replies (get_rbf adds shift=).
    @staticmethod
    def _weights_str(w) -> str:
        return ",".join(f"{r},{i}" for r, i in w)

    def _bf_get(self, cmd, get):
        st = get()
        kv = [("enable", int(st["enable"])),
              ("angle_deg", "none" if st["angle_deg"] is None else fmt_float(st["angle_deg"])),
              ("carrier_freq", fmt_float(st["carrier_freq"])),
              ("element_spacing", fmt_float(st["element_spacing"])),
              ("weights", self._weights_str(st["weights"]))]
        if "shift" in st:
            kv.append(("shift", int(st["shift"])))
        return "OK " + self._kv(kv)

    def _bf_enable(self, a, cmd, fn):
        self._nargs(a, 1, f"{cmd} <0|1>")
        return "OK %d" % int(fn(_int(a[0], "enable", 0, 1) == 1))

    def _bf_params(self, a, cmd, fn):
        self._nargs(a, 2, f"{cmd} <carrier_hz> <element_spacing_m>")
        fc, d = _float(a[0], "carrier_freq"), _float(a[1], "element_spacing")
        if fc <= 0 or d <= 0:
            raise ProtocolError("carrier_freq and element_spacing must be > 0")
        fn(fc, d)
        return "OK"

    def _bf_angle(self, a, cmd, fn):
        self._nargs(a, 1, f"{cmd} <deg>")
        return "OK " + self._weights_str(fn(_float(a[0], "angle")))

    def _bf_weights(self, a, cmd, fn):
        n = self.be.num_channels
        if len(a) != 2 * n:
            raise ProtocolError(f"usage: {cmd} <re0> <im0> ... <re{n - 1}> "
                                f"<im{n - 1}> ({2 * n} int16 values, Q1.15)")
        v = [_int(x, "weight", -32768, 32767) for x in a]
        fn(list(zip(v[0::2], v[1::2])))
        return "OK"

    def _get_bf(self, s, a):
        self._nargs(a, 0, "get_bf")
        return self._bf_get("get_bf", self.be.bf_get)

    def _set_bf_enable(self, s, a):
        return self._bf_enable(a, "set_bf_enable", self.be.bf_set_enable)

    def _set_bf_params(self, s, a):
        return self._bf_params(a, "set_bf_params", self.be.bf_set_params)

    def _set_bf_angle(self, s, a):
        return self._bf_angle(a, "set_bf_angle", self.be.bf_set_angle)

    def _set_bf_weights(self, s, a):
        return self._bf_weights(a, "set_bf_weights", self.be.bf_set_weights)

    def _get_rbf(self, s, a):
        self._nargs(a, 0, "get_rbf")
        return self._bf_get("get_rbf", self.be.rbf_get)

    def _set_rbf_enable(self, s, a):
        return self._bf_enable(a, "set_rbf_enable", self.be.rbf_set_enable)

    def _set_rbf_params(self, s, a):
        return self._bf_params(a, "set_rbf_params", self.be.rbf_set_params)

    def _set_rbf_angle(self, s, a):
        return self._bf_angle(a, "set_rbf_angle", self.be.rbf_set_angle)

    def _set_rbf_weights(self, s, a):
        return self._bf_weights(a, "set_rbf_weights", self.be.rbf_set_weights)

    def _set_rbf_shift(self, s, a):
        self._nargs(a, 1, "set_rbf_shift <0..15>")
        return "OK %d" % self.be.rbf_set_shift(_int(a[0], "shift", 0, 15))

    def _list_sensors(self, s, a):
        self._nargs(a, 0, "list_sensors")
        return "OK " + " ".join(self.be.list_sensors())

    def _get_sensor(self, s, a):
        self._nargs(a, 1, "get_sensor <name>")
        if a[0] not in self.be.list_sensors():
            raise ProtocolError(f"unknown sensor '{a[0]}'")
        typ, val, unit = self.be.get_sensor(a[0])
        return f"OK {typ} {val} {unit or '-'}"

    def _sources(self, a, fn):
        self._nargs(a, 0, "<cmd>")
        return "OK " + " ".join(fn())

    def _set_src(self, a, setter, getter):
        self._nargs(a, 1, "<cmd> <source>")
        setter(a[0])
        return "OK " + getter()

    def _get_src(self, a, fn):
        self._nargs(a, 0, "<cmd>")
        return "OK " + fn()

    def _stats(self, s, a):
        self._nargs(a, 0, "stats")
        return "OK " + self._kv(sorted(self.be.stats().items()))


def _one_line(msg: str) -> str:
    msg = " ".join(msg.split())
    return msg[:500] if msg else "error"
