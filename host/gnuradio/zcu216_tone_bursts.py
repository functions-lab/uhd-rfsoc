"""
Embedded Python block (GRC epy_block) of the zcu216_tones_* flowgraphs:
one timed TX burst per message on the `fire` port, the same tone on every
channel.

Every channel carries amp x exp(j 2 pi tone_step n) (tone_step: a fraction of
the sample rate; 1/64 = 64 samples per period). A message on `fire` (a pmt
double: the device time t0, seconds) queues one burst of `burst_len` samples
per channel, tagged for gr-uhd's USRP Sink on output 0: tx_sob + tx_time (t0)
on its first sample, tx_eob on its last. Between bursts the block emits
nothing, so the sink sends nothing.

The burst is requested by message, not by a method call, because a message
wakes the block's thread at once: a source block that returned 0 items is
otherwise left idle for up to 250 ms by GNU Radio's scheduler, which made the
burst miss its start time (late packet, then an underflow per packet).

The block's very first output is one zero sample tagged tx_eob. gr-uhd's USRP
Sink opens a timed burst when it starts (an empty start-of-burst packet at
now + 0.15 s) and never ends it; left open, the first real burst would close
it with a packet whose time has passed -- a late (L) event. Ending it at once,
well before its time, plays one zero sample and reports nothing.
"""
import numpy as np
import pmt
from gnuradio import gr


class blk(gr.sync_block):
    def __init__(self, nchan=4, burst_len=32768, amp=0.25, tone_step=1.0 / 64):
        gr.sync_block.__init__(self, name="ZCU216 tone bursts", in_sig=None,
                               out_sig=[np.complex64] * int(nchan))
        self.nchan, self.burst_len = int(nchan), int(burst_len)
        n = np.arange(self.burst_len)
        self.sig = (amp * np.exp(2j * np.pi * tone_step * n)).astype(np.complex64)
        self.message_port_register_in(pmt.intern("fire"))
        self.set_msg_handler(pmt.intern("fire"), self._fire)
        self._pending = []
        self._pos = None
        self._t0 = 0.0
        self._closed_start = False

    def _fire(self, msg):
        self._pending.append(pmt.to_double(msg))

    def work(self, input_items, output_items):
        if not self._closed_start:
            # end gr-uhd's start-of-stream burst (see the module docstring)
            self._closed_start = True
            for k in range(self.nchan):
                output_items[k][0] = 0
            self.add_item_tag(0, self.nitems_written(0), pmt.intern("tx_eob"), pmt.PMT_T)
            return 1
        if self._pos is None:
            if not self._pending:
                return 0
            self._t0, self._pos = self._pending.pop(0), 0
        pos = self._pos
        n = min(len(output_items[0]), self.burst_len - pos)
        for k in range(self.nchan):
            output_items[k][:n] = self.sig[pos:pos + n]
        off = self.nitems_written(0)
        if pos == 0:
            secs = int(self._t0)
            self.add_item_tag(0, off, pmt.intern("tx_sob"), pmt.PMT_T)
            self.add_item_tag(0, off, pmt.intern("tx_time"),
                              pmt.make_tuple(pmt.from_uint64(secs), pmt.from_double(self._t0 - secs)))
        if pos + n == self.burst_len:
            self.add_item_tag(0, off + n - 1, pmt.intern("tx_eob"), pmt.PMT_T)
            self._pos = None
        else:
            self._pos = pos + n
        return n
