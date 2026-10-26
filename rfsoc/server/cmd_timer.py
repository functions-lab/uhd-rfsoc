"""Timed control commands of the uhd-rfsoc daemon (Protocol §3c).

UHD's set_command_time() makes later tune and gain requests take effect at a
device time. The RFDC has no timed-command queue in the fabric, so the daemon
does it in software: `set_*_freq ... at=<ticks>` / `set_*_gain ... at=<ticks>`
are answered at once with the value that will be in effect, and executed by
this timer when the FPGA timekeeper reaches <ticks>.

* Accuracy: the timer reads the FPGA timekeeper (get_time) and sleeps on the
  PS's clock; it fires within ~0.2-1 ms after the requested time (Python on
  the A53, then the AXI writes of the update itself). It is NOT
  sample-synchronous.
* Grouping: every operation with the SAME <ticks> forms one group, executed in
  one go -- the tunes of a group are one NCO batch per direction (HwBackend
  writes every NCO, then resets the phases and fires one update event per
  tile, §3b), then the gains. A multi-channel set_command_time + tune loop
  therefore retunes all channels together.
* `set_time <t> at=<ticks>` (the host's emulated PPS edge) writes
  t + (time now - <ticks>): the timekeeper reads t at <ticks> within the AXI
  write latency, whatever the timer's own latency was.
* A time already in the past executes at once. Untimed requests do not wait
  for pending timed ones. Pending groups are dropped when their time base
  goes away: an FPGA reload (set_channels / a rate change) and the release of
  the claim.
"""
from __future__ import annotations

import collections
import logging
import threading
import time
from typing import Callable, Dict, List, Tuple

log = logging.getLogger("uhd_rfsoc.timer")


class CommandTimer:
    def __init__(self, now_fn: Callable[[], int], rate_fn: Callable[[], float],
                 run_fn: Callable[[List[tuple]], None], name: str = "cmd-timer"):
        self.now_fn, self.rate_fn, self.run_fn = now_fn, rate_fn, run_fn
        self.cv = threading.Condition()
        self.groups: Dict[int, List[tuple]] = collections.OrderedDict()
        self.closed = False
        self.fired = 0
        self.late = 0
        self._thread = None
        self.name = name

    def schedule(self, at: int, op: tuple) -> None:
        with self.cv:
            self.groups.setdefault(int(at), []).append(op)
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._loop, name=self.name,
                                                daemon=True)
                self._thread.start()
            self.cv.notify_all()

    def pending(self) -> int:
        with self.cv:
            return sum(len(g) for g in self.groups.values())

    def clear(self) -> int:
        with self.cv:
            n = sum(len(g) for g in self.groups.values())
            self.groups.clear()
            self.cv.notify_all()
            return n

    def close(self) -> None:
        with self.cv:
            self.closed = True
            self.groups.clear()
            self.cv.notify_all()

    def _due(self) -> Tuple[int, List[tuple]]:
        """(time, ops) of the earliest group once it is due, else waits.
        Called with cv held; returns (None, None) when closed."""
        while not self.closed:
            if not self.groups:
                self.cv.wait(1.0)
                continue
            at = min(self.groups)
            try:
                now = self.now_fn()
                rate = float(self.rate_fn())
            except Exception as e:      # backend busy / reloading: retry
                log.debug("timer: no time (%s)", e)
                self.cv.wait(0.01)
                continue
            dt = (at - now) / rate if rate > 0 else 0.0
            if dt <= 0:
                if dt < -0.001:
                    self.late += 1
                    log.info("timed command for %d executed %.3f ms late", at, -dt * 1e3)
                return at, self.groups.pop(at)
            # sleep most of the way on the PS clock, then re-read the FPGA
            # time (no drift between the two clocks accumulates)
            self.cv.wait(max(0.0001, min(0.1, dt - 0.0005 if dt > 0.002 else dt / 2)))
        return None, None

    def _loop(self) -> None:
        while True:
            with self.cv:
                at, ops = self._due()
            if at is None:
                return
            try:
                self.run_fn(ops, at)
                self.fired += 1
            except Exception:
                log.exception("timed command group at %d failed", at)
