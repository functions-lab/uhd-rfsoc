"""The control protocol (protocol.py, Protocol §2-3, §8, §10, §11) driven
against a Backend with the hardware stubbed: no board, no pynq
(python3 -m unittest discover -s rfsoc/server/tests)."""
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import vrt  # noqa: E402
from backend import Backend, coerce_nco  # noqa: E402
from protocol import ControlCore, Session  # noqa: E402


class FakeBackend(Backend):
    """N channels at fs, the Gen3 factors `factors` as installed rates (one
    bitstream per rate, like fixed builds); every §10 format converted."""

    def __init__(self, nch=1, factors=(2, 4, 8, 16), fs=2.5e9):
        self._lock = threading.RLock()
        self.num_channels = nch
        self.adc_rate = self.dac_rate = fs
        self._factors = factors
        self.rx_decim = self.tx_interp = factors[0]
        self.fpga_name = f"fake_v49_{nch}ch_qsfp"
        self.tx_buf_words, self.fc_interval = 32752, 512
        self._rx = [600e6] * nch
        self._tx = [600e6] * nch
        self._rxg = [0.0] * nch
        self._txg = [0.0] * nch
        self._time = 0
        self.rx_setup = None
        self.tx_setup = None
        self.cmds = []
        self.bf_writes = []

    # rates (§8)
    def available_rates(self):
        return sorted((self.adc_rate / f for f in self._factors), reverse=True)

    def _switch_rate(self, rate):
        self.rx_decim = self.tx_interp = int(round(self.adc_rate / rate))

    def otw_formats(self):
        return list(vrt.OTW_FORMATS)

    # tuning / gain
    def set_rx_freq(self, ch, hz):
        self._rx[ch] = coerce_nco(min(self.adc_rate / 2, max(0.0, hz)), self.adc_rate)
        return self._rx[ch]

    def get_rx_freq(self, ch):
        return self._rx[ch]

    def set_tx_freq(self, ch, hz):
        self._tx[ch] = coerce_nco(min(self.dac_rate / 2, max(0.0, hz)), self.dac_rate)
        return self._tx[ch]

    def get_tx_freq(self, ch):
        return self._tx[ch]

    def set_rx_gain(self, ch, db):
        self._rxg[ch] = self.plan_gain("rx", ch, db)
        return self._rxg[ch]

    def get_rx_gain(self, ch):
        return self._rxg[ch]

    def set_tx_gain(self, ch, db):
        self._txg[ch] = self.plan_gain("tx", ch, db)
        return self._txg[ch]

    def get_tx_gain(self, ch):
        return self._txg[ch]

    # time / streaming
    def set_time(self, ticks):
        self._time = int(ticks)

    def get_time(self):
        return self._time

    def stream_setup(self, ch, host_ip, host_mac, port_base, nports, spp, pattern, otw="sc16"):
        self.rx_setup = dict(host_ip=host_ip, port_base=port_base, nports=nports,
                             spp=spp, pattern=pattern, otw=otw)
        return spp, nports

    def stream_cmd(self, ch, mode, num_samps, now, time_ticks, cont=False):
        self.cmds.append((mode, num_samps, now, time_ticks, cont))
        return "new"

    def stop_streaming(self):
        self.cmds.append(("stop_cont", 0, True, 0, False))

    def stream_setup_tx(self, ch, host_ip, host_mac, async_port, otw="sc16"):
        self.tx_setup = dict(host_ip=host_ip, async_port=async_port, otw=otw)
        return self.tx_buf_words, self.fc_interval, 1234

    def stream_stop_tx(self, ch):
        self.tx_setup = None

    def is_streaming(self):
        return False

    # beamformers (§11): the N >= 2 builds have both
    @property
    def has_bf(self):
        return self.num_channels > 1

    @property
    def has_rbf(self):
        return self.num_channels > 1

    def _bf_write(self, enable, weights):
        self.bf_writes.append(("tx", enable, list(weights)))

    def _rbf_write(self, enable, weights, shift):
        self.bf_writes.append(("rx", enable, list(weights), shift))

    # sensors / clocks / stats
    def list_sensors(self):
        return ["pps_present", "mts_locked"]

    def get_sensor(self, name):
        return ("bool", "false", "absent") if name == "pps_present" else ("bool", "true", "locked")

    def set_clock_source(self, src):
        if src not in self.clock_sources():
            raise ValueError(src)

    def get_clock_source(self):
        return "internal"

    def stats(self):
        return {"pkts": 0, "overflows": 0}


def core(nch=1, **kw):
    be = FakeBackend(nch, **kw)
    c = ControlCore(be, serial="FAKE-1", name="zcu216", data_ip="192.0.2.2",
                    data_mac="02:00:00:00:00:01")
    return be, c, Session("test:1", "192.0.2.1")


def kv(reply):
    return dict(x.split("=", 1) for x in reply[3:].split(";"))


class ProtocolBasics(unittest.TestCase):
    def test_ping_info_discovery(self):
        be, c, s = core()
        self.assertEqual(c.handle_line(s, "ping"), "OK pong")
        d = kv(c.handle_line(s, "info"))
        self.assertEqual(d["type"], "rfsoc")
        self.assertEqual(d["addr"], "192.0.2.1")
        self.assertEqual((d["num_rx"], d["num_tx"], d["claimed"]), ("1", "1", "0"))
        self.assertEqual(float(d["tick_rate"]), 1.25e9)          # N x rate, TICK_STEP 1
        self.assertEqual(d["rx_rates"], "1250000000,625000000,312500000,156250000")
        self.assertEqual(d["tick_rates"], d["rx_rates"])
        self.assertEqual(d["channel_counts"], "1")
        self.assertEqual(d["otw_formats"], "sc16,sc8,sc12,fc32")
        self.assertEqual((d["bf"], d["rbf"]), ("0", "0"))
        disc = c.discovery_reply("192.0.2.9")
        self.assertTrue(disc.startswith("UHD-RFSOC-DISC type=rfsoc;product=zcu216;serial=FAKE-1;"))
        self.assertIn(";addr=192.0.2.9;data_ip=192.0.2.2;claimed=0;fpga=fake_v49_1ch_qsfp;version=1", disc)
        # hosts from before the rename probe with ZCU216-DISC? and want type=zcu216
        old = c.discovery_reply("192.0.2.9", "ZCU216-DISC?")
        self.assertTrue(old.startswith("ZCU216-DISC type=zcu216;product=zcu216;serial=FAKE-1;"))
        self.assertIsNone(c.discovery_reply("192.0.2.9", "HELLO?"))

    def test_claim(self):
        be, c, s = core()
        s2 = Session("test:2", "192.0.2.1")
        self.assertEqual(c.handle_line(s, "get_time"), "ERR not claimed")
        self.assertEqual(c.handle_line(s, "claim"), "OK")
        self.assertEqual(c.handle_line(s2, "claim"), "ERR claimed")
        self.assertEqual(c.handle_line(s2, "get_time"), "ERR claimed")
        self.assertEqual(c.handle_line(s, "set_time 5"), "OK")
        self.assertEqual(c.handle_line(s, "get_time"), "OK 5")
        self.assertEqual(c.handle_line(s, "unclaim"), "OK")
        self.assertEqual(c.handle_line(s, "get_time"), "ERR not claimed")
        self.assertEqual(c.handle_line(s2, "claim"), "OK")

    def test_bad_requests(self):
        be, c, s = core()
        c.handle_line(s, "claim")
        self.assertTrue(c.handle_line(s, "bogus").startswith("ERR unknown command"))
        self.assertEqual(c.handle_line(s, ""), "ERR empty request")
        self.assertTrue(c.handle_line(s, "set_rx_freq 1 1e9").startswith("ERR channel 1 out of range"))
        self.assertTrue(c.handle_line(s, "set_rx_rate 0 abc").startswith("ERR bad rate"))
        self.assertEqual(c.handle_line(s, "stream_cmd 0 start_cont 0 1 0"), "ERR stream_setup first")
        self.assertEqual(c.handle_line(s, "get_bf"),
                         "ERR no TX beamformer in fake_v49_1ch_qsfp (the N >= 2 builds have one; this is N = 1)")
        self.assertEqual(c.handle_line(s, "ping  pong  "), "OK pong")   # stray whitespace


class Rates(unittest.TestCase):
    def test_met_from_below(self):
        be, c, s = core()
        c.handle_line(s, "claim")
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 1e9"), "OK 625000000 625000000")
        self.assertEqual(c.handle_line(s, "get_tx_rate 0"), "OK 625000000")   # one factor
        self.assertEqual(c.handle_line(s, "set_tx_rate 0 1e6"), "OK 156250000 156250000")
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 1250000001"), "OK 1250000000 1250000000")
        self.assertEqual(kv(c.handle_line(s, "info"))["tick_rate"], "1250000000")

    def test_otw_picks_the_sc8_only_rate(self):
        be, c, s = core(4)                       # 4 ch: 1250 MS/s fits sc8 only (§3 example)
        c.handle_line(s, "claim")
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 1.25e9"), "OK 625000000 2500000000")
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 1.25e9 otw=sc8"), "OK 1250000000 5000000000")
        d = kv(c.handle_line(s, "info"))
        self.assertEqual(d["rate_otw"].split(",")[0], "1250000000:sc8")
        self.assertEqual(d["rate_otw"].split(",")[1], "625000000:sc16+sc8+sc12")  # no RX fc32 on 512 b
        self.assertEqual(d["rx_otw_formats"], "sc8")                 # at the sc8-only rate
        # a format only a lower rate carries: met from below among those builds
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 1.25e9 otw=fc32"), "OK 312500000 1250000000")

    def test_refused_before_any_reload(self):
        be, c, s = core(4, factors=(2,))         # only the sc8-only rate installed
        c.handle_line(s, "claim")
        r = c.handle_line(s, "set_rx_rate 0 1.25e9")
        self.assertTrue(r.startswith("ERR set_rx_rate 1250000000 refused: the current otw "
                                     "(the last otw= the client sent; sc16 by default) is otw=sc16"), r)
        self.assertIn("needs otw=sc8", r)
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 1.25e9 otw=sc8"), "OK 1250000000 5000000000")


class TuneAndStream(unittest.TestCase):
    def test_tune_with_dsp_part(self):
        be, c, s = core()
        c.handle_line(s, "claim")
        r = c.handle_line(s, "set_rx_freq 0 1e9")           # on the 48-bit NCO grid
        self.assertAlmostEqual(float(r[3:]), 1e9, delta=1e-3, msg=r)
        r = c.handle_line(s, "set_rx_freq 0 1e9 dsp=1e6").split()
        self.assertEqual(r[0], "OK")
        self.assertAlmostEqual(float(r[1]), 1e9, delta=1e-3)
        self.assertAlmostEqual(float(r[2]), 1e6, delta=1e-3)
        self.assertAlmostEqual(be.get_rx_freq(0), 999e6, delta=1e-3)      # NCO = rf - dsp
        self.assertAlmostEqual(float(c.handle_line(s, "get_rx_freq 0")[3:]), 1e9, delta=1e-3)
        self.assertAlmostEqual(float(c.handle_line(s, "get_rx_dsp_freq 0")[3:]), 1e6, delta=1e-3)
        self.assertEqual(c.handle_line(s, "set_tx_freq 0 3e9"), "OK 1250000000")   # clamped to fs/2
        self.assertEqual(c.handle_line(s, "get_rx_freq_range 0"), "OK 0 1250000000")
        self.assertEqual(c.handle_line(s, "set_rx_gain 0 -10.4"), "OK -10")
        self.assertEqual(c.handle_line(s, "get_rx_gain_range 0"), "OK -27 0 1")
        self.assertEqual(c.handle_line(s, "set_rx_antenna 0 RX2"), "OK RX")

    def test_stream_setup_granule_and_formats(self):
        be, c, s = core(4)
        c.handle_line(s, "claim")
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 625e6"), "OK 625000000 2500000000")
        setup = "stream_setup 0 192.0.2.1 aa:bb:cc:dd:ee:ff 49810 2 {spp}{opt}"
        self.assertEqual(c.handle_line(s, setup.format(spp=2047, opt="")), "OK 2032 2")
        self.assertEqual(c.handle_line(s, setup.format(spp=4096, opt=" otw=sc8")), "OK 4096 2")
        self.assertEqual(c.handle_line(s, setup.format(spp=2048, opt=" otw=sc12 pattern=1")),
                         "OK 2048 2")
        self.assertTrue(be.rx_setup["pattern"])
        self.assertEqual(kv(c.handle_line(s, "info"))["spp"], "1536")     # sc12 payload in sc16 slots
        self.assertEqual(c.handle_line(s, "stream_cmd 0 num_done 1000 1 0"), "OK")
        self.assertEqual(be.cmds[-1], ("num_done", 1024, True, 0, False))  # ceil to the sc12 granule
        r = c.handle_line(s, setup.format(spp=1024, opt=" otw=fc32"))
        self.assertTrue(r.startswith("ERR otw=fc32: 4 ch x 625 MS/s x 8 B = 20.000 GB/s exceeds"), r)
        # 4 ch at 312.5 MS/s: fc32 fits the link, but not RX on a 512-bit beat (§10)
        self.assertEqual(c.handle_line(s, "set_rx_rate 0 312.5e6"), "OK 312500000 1250000000")
        r = c.handle_line(s, setup.format(spp=1024, opt=" otw=fc32"))
        self.assertTrue(r.startswith("ERR otw=fc32: RX fc32 is not supported on a 512-bit-beat"), r)
        self.assertEqual(c.handle_line(s, "stream_setup_tx 0 192.0.2.1 aa:bb:cc:dd:ee:ff 49826 otw=fc32"),
                         "OK 32752 512 1234")
        self.assertEqual(c.handle_line(s, "stream_stop_tx 0"), "OK")

    def test_release_stops_and_resets(self):
        be, c, s = core(2)
        c.handle_line(s, "claim")
        self.assertEqual(c.handle_line(s, "set_bf_enable 1"), "OK 1")
        self.assertEqual(c.handle_line(s, "set_rbf_shift 3"), "OK 3")
        self.assertTrue(c.handle_line(s, "set_rbf_shift 16").startswith("ERR"))
        self.assertEqual(c.handle_line(s, "set_bf_angle 0"), "OK 32767,0,32767,0")
        self.assertEqual(kv(c.handle_line(s, "get_rbf"))["shift"], "3")
        c.disconnect(s)
        self.assertEqual(be.cmds[-1][0], "stop_cont")
        self.assertEqual(be.bf_writes[-2:], [("tx", False, [(32767, 0)] * 2),
                                             ("rx", False, [(32767, 0)] * 2, 1)])
        s2 = Session("test:2", "192.0.2.1")
        c.handle_line(s2, "claim")
        self.assertEqual(kv(c.handle_line(s2, "get_bf"))["enable"], "0")

    def test_sensors(self):
        be, c, s = core()
        c.handle_line(s, "claim")
        self.assertEqual(c.handle_line(s, "list_sensors"), "OK pps_present mts_locked")
        self.assertEqual(c.handle_line(s, "get_sensor pps_present"), "OK bool false absent")
        self.assertEqual(c.handle_line(s, "get_sensor nope"), "ERR unknown sensor 'nope'")
        self.assertEqual(c.handle_line(s, "get_clock_sources"), "OK internal")
        self.assertEqual(c.handle_line(s, "stats"), "OK overflows=0;pkts=0")


if __name__ == "__main__":
    unittest.main()
