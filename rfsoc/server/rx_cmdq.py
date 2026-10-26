"""RX stream-command queue of the uhd-rfsoc daemon (Protocol §4a).

The FPGA streamer (fpga/ip/src/uhd_ip/src/udp_streamer.v) holds ONE command: a start while it is
armed or running is rejected, and it goes idle after a finite burst. A USRP
queues stream commands and runs them in order, and chains `num_more`
commands into one contiguous stream. This module gives the daemon that
behaviour on top of the one-slot streamer (HwBackend's RTL):

* Commands run in arrival order (FIFO). The next one is issued when the
  streamer is idle; a timed one is armed then and starts at its time.
* `stop_cont` clears the queue and stops the streamer at once.
* A running `start_cont` is ended by the next start command: once it has
  produced at least one packet (so the host has seen its SOB and its
  pending-burst bookkeeping stays aligned), the streamer is stopped and the
  next command issued.
* A command whose time has already passed when it is issued (late) is not
  streamed: the daemon issues a one-granule `num_done` NOW instead, so the
  host receives a short burst whose SOB TSF is later than the requested time
  and reports ERROR_CODE_LATE_COMMAND (the RTL itself starts a late timed
  start at once; the marker keeps a late `start_cont` from streaming forever).
* `num_more` chains. A chain is a `num_more` followed by continuations: start
  commands the host flags `cont=1` (stream_now, or timed at exactly the
  chain's end). The FPGA cannot extend a finite burst, so an OPEN chain (last
  link `num_more`) runs as `start_cont` and the daemon stops it once the
  stream has passed the chain's end (+ `chain_grace_s`); a continuation that
  arrives before that extends it (reply `cont`: no new SOB, the samples are
  contiguous). Links queued together before the chain is issued are merged
  into one FPGA command (`num_done` of the sum when the chain is closed). A
  continuation that arrives too late becomes a new burst (reply `new`): the
  host sees a new SOB after the end of the chain and reports
  ERROR_CODE_BROKEN_CHAIN. A non-continuation start command (`cont=0`) closes
  an open chain: it still ends at its end, then the new command runs.

Counts are SLOTS (the host multiplied by N and the protocol rounded them up
to the format's granule); times are ticks.

The hardware the queue drives (duck-typed):

    rxhw_issue(mode, num, now, t) -> int   start one command; returns the
        burst's start tick, or an upper bound of it (a "now" start on the
        RTL); raises if the streamer refuses
    rxhw_stop()                  stop_cont
    rxhw_busy() -> bool          armed or streaming
    rxhw_time() -> int           the timekeeper
    rxhw_pos() -> int            the tick the stream has reached (the RTL
                                 streams in real time: the timekeeper)
    rxhw_pkts() -> int           packets emitted so far (monotonic)
    rxhw_geometry() -> (ticks per slot, beat ticks, granule slots, tick rate)

All calls are made with `lock` held (the backend's lock: the queue never
takes a second lock, so it cannot deadlock against the backend).
"""
from __future__ import annotations

import collections
import logging
import threading
import time
from typing import Optional

log = logging.getLogger("uhd_rfsoc.rxq")

START_MODES = ("start_cont", "num_done", "num_more")

# reply tokens of `stream_cmd` (Protocol §3/§4a)
NEW, CONT = "new", "cont"


class _Entry:
    """A queued command, or a chain of them merged before it was issued."""
    __slots__ = ("now", "t", "total", "open", "final")

    def __init__(self, mode, num, now, t):
        self.now, self.t = bool(now), int(t)
        self.total = int(num) if mode != "start_cont" else 0
        self.final = mode                  # mode of the last link
        self.open = mode == "num_more"     # a continuation may still join

    def extend(self, mode, num):
        if mode != "start_cont":
            self.total += int(num)
        self.final = mode
        self.open = mode == "num_more"

    def __repr__(self):
        return (f"<{self.final} {self.total} slots {'now' if self.now else self.t}"
                f"{' open' if self.open else ''}>")


class _Run:
    """What the streamer is doing for the queue."""
    __slots__ = ("kind", "end", "open", "pkts0", "t0")

    def __init__(self, kind, end=None, open_=False, pkts0=0):
        # finite: a num_done / num_more / late marker, ends by itself
        # cont:   a start_cont, ends at stop_cont or at the next start command
        # chain:  an open num_more chain streaming as start_cont until `end`
        # stopping: stop issued, waiting for the streamer to go idle
        self.kind, self.end, self.open, self.pkts0 = kind, end, open_, pkts0
        self.t0 = time.monotonic()


class RxCommandQueue:
    def __init__(self, hw, lock, chain_grace_s: float = 0.001,
                 poll_s: float = 0.0005, name: str = "rx-cmdq"):
        self.hw = hw
        self.cv = threading.Condition(lock)
        self.q = collections.deque()
        self.run: Optional[_Run] = None
        self.chain_grace_s = float(chain_grace_s)
        self.poll_s = float(poll_s)
        self.name = name
        self.closed = False
        self._thread = None
        self.stats = collections.Counter()

    # -- client side --------------------------------------------------------
    def post(self, mode: str, num: int, now: bool, t: int, cont: bool = False) -> str:
        """One stream command. -> NEW (it is or will be its own burst, with
        a SOB) or CONT (it joined the open num_more chain: no SOB)."""
        with self.cv:
            if mode == "stop_cont":
                self._stop_all()
                return NEW
            if mode not in START_MODES:
                raise ValueError(f"bad mode {mode}")
            r = self.run
            if cont:
                tail = self.q[-1] if self.q else None
                if tail is not None and tail.open:
                    tail.extend(mode, num)
                    self.stats["merged"] += 1
                    return CONT
                if (not self.q and r is not None and r.kind == "chain" and r.open
                        and self.hw.rxhw_pos() < r.end + self._grace_ticks()):
                    self._extend_run(r, mode, num)
                    self.stats["extended"] += 1
                    self.cv.notify_all()
                    return CONT
                self.stats["chain_too_late"] += 1
            # a new burst: it closes an open chain (which still ends at its end)
            if r is not None and r.kind == "chain":
                r.open = False
            if self.q and self.q[-1].open:
                self.q[-1].open = False
            self.q.append(_Entry(mode, num, now, t))
            self._pump(sync=True)
            self._ensure_thread()
            self.cv.notify_all()
            return NEW

    def stop(self) -> None:
        with self.cv:
            self._stop_all()
            self.cv.notify_all()

    def reset(self) -> None:
        """The streamer was stopped behind the queue's back (FPGA reload):
        forget everything, touch nothing."""
        with self.cv:
            self.q.clear()
            self.run = None
            self.cv.notify_all()

    def busy(self) -> bool:
        with self.cv:
            try:
                self._pump()            # retire a burst that just ended
            except Exception:
                log.exception("rx command queue")
            return bool(self.q) or self.run is not None

    def close(self) -> None:
        with self.cv:
            self.closed = True
            self.cv.notify_all()
        t = self._thread
        if t is not None and t is not threading.current_thread():
            t.join(timeout=1.0)

    # -- internals (lock held) ------------------------------------------------
    def _grace_ticks(self) -> int:
        return int(self.chain_grace_s * self.hw.rxhw_geometry()[3])

    def _extend_run(self, r: _Run, mode: str, num: int) -> None:
        if mode == "start_cont":
            r.kind, r.end, r.open = "cont", None, False
            r.pkts0 = self.hw.rxhw_pkts()
            return
        r.end += int(num) * self.hw.rxhw_geometry()[0]
        r.open = mode == "num_more"

    def _stop_all(self) -> None:
        self.q.clear()
        if self.run is not None or self.hw.rxhw_busy():
            self.hw.rxhw_stop()
            self.run = _Run("stopping") if self.hw.rxhw_busy() else None
        else:
            self.run = None

    def _pump(self, sync: bool = False) -> None:
        """Advance: retire a finished command, stop what must stop, issue
        the next one. `sync`: called from post() (errors go to the client)."""
        hw = self.hw
        r = self.run
        if r is not None:
            if r.kind == "stopping":
                if not hw.rxhw_busy():
                    self.run = r = None
            elif r.kind == "chain" and r.end is not None and \
                    hw.rxhw_pos() >= r.end + self._grace_ticks():
                hw.rxhw_stop()
                self.stats["chain_stops"] += 1
                self.run = r = (_Run("stopping") if hw.rxhw_busy() else None)
            elif r.kind == "cont" and self.q and hw.rxhw_pkts() > r.pkts0:
                # replaced by the next start command, after its first packet
                hw.rxhw_stop()
                self.run = r = (_Run("stopping") if hw.rxhw_busy() else None)
            elif r.kind == "finite" and not hw.rxhw_busy():
                self.run = r = None
            elif r.kind in ("cont", "chain") and not hw.rxhw_busy():
                # stopped behind our back (e.g. the hardware's enable dropped)
                self.run = r = None
        if self.run is not None or not self.q:
            return
        if hw.rxhw_busy():          # not ours (or not settled yet): wait
            return
        e = self.q.popleft()
        tps, beat, gran, _rate = hw.rxhw_geometry()
        try:
            if not e.now and hw.rxhw_time() >= e.t - e.t % beat + beat:
                # late: a one-granule marker burst NOW (SOB TSF > requested)
                self.stats["late"] += 1
                log.info("late stream command %r (time now %d): marker burst", e,
                         hw.rxhw_time())
                hw.rxhw_issue("num_done", gran, True, 0)
                self.run = _Run("finite")
            elif e.final == "start_cont":
                hw.rxhw_issue("start_cont", 0, e.now, e.t)
                self.run = _Run("cont", pkts0=hw.rxhw_pkts())
            elif not e.open:
                hw.rxhw_issue(e.final, e.total, e.now, e.t)
                self.run = _Run("finite")
            else:
                start = hw.rxhw_issue("start_cont", 0, e.now, e.t)
                self.run = _Run("chain", end=int(start) + e.total * tps, open_=True,
                                pkts0=hw.rxhw_pkts())
            self.stats["issued"] += 1
        except Exception:
            self.run = None
            if sync:
                raise
            log.exception("issuing %r failed; dropped", e)

    def _ensure_thread(self) -> None:
        if self._thread is None or not self._thread.is_alive():
            self._thread = threading.Thread(target=self._loop, name=self.name,
                                            daemon=True)
            self._thread.start()

    def _wait_s(self) -> float:
        """How long the scheduler may sleep: short only while something waits
        on the streamer (a queued command, a chain nearing its end), so a
        long start_cont costs the daemon ~20 status reads a second."""
        r = self.run
        if r is None:
            return self.poll_s if self.q else 0.5
        if r.kind == "cont":
            return self.poll_s if self.q else 0.05
        if r.kind == "chain" and r.end is not None:
            try:
                rate = self.hw.rxhw_geometry()[3]
                dt = (r.end + self._grace_ticks() - self.hw.rxhw_pos()) / rate
            except Exception:
                dt = 0.0
            return min(0.05, max(self.poll_s, dt))
        if r.kind == "finite":
            return self.poll_s if self.q else 0.01
        return self.poll_s

    def _loop(self) -> None:
        with self.cv:
            while not self.closed:
                try:
                    self._pump()
                except Exception:      # never let the scheduler die
                    log.exception("rx command queue")
                    self.run = None
                self.cv.wait(self._wait_s())
