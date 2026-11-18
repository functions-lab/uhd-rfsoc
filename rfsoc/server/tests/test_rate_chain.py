#!/usr/bin/env python3
"""The low-rate chains in the daemon (design
docs/superpowers/specs/2026-11-17-low-rate-fir-design.md): rate points
fs/40/2^k of a build whose .hwh has eth100g/rx_rate + tx_rate, the retune
order, the clock measurement at depth k, the register driver. The builds
are the published bitstreams' .hwh (bitstreams/ submodule); a "new" build is
one of them with rx_rate / tx_rate MODULEs added, as the chained designs
write them."""
import os
import shutil
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import backend  # noqa: E402
import hw_backend  # noqa: E402
import rate_chain  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BITS = os.path.join(REPO, "bitstreams", "pynq2.7")


def old_build(board, name):
    p = os.path.join(BITS, board, name + ".bit")
    if not os.path.isfile(os.path.splitext(p)[0] + ".hwh"):
        raise unittest.SkipTest(f"{p}: no .hwh (bitstreams submodule not checked out)")
    return p


def chained_build(tmp, src_bit, nch, spc, k, g=1):
    """A copy of src_bit's .hwh with the two rate hubs, as the chained
    designs write them (MODTYPE rx_rate / tx_rate, N_CH SPC K G)."""
    name = os.path.splitext(os.path.basename(src_bit))[0]
    dst = os.path.join(tmp, name + ".bit")
    shutil.copy(src_bit, dst)
    tree = ET.parse(os.path.splitext(src_bit)[0] + ".hwh")
    mods = next(tree.getroot().iter("MODULES"))
    for d in ("rx", "tx"):
        m = ET.SubElement(mods, "MODULE", {"MODTYPE": f"{d}_rate", "FULLNAME": f"/eth100g/{d}_rate",
                                           "INSTANCE": f"eth100g_{d}_rate"})
        ps = ET.SubElement(m, "PARAMETERS")
        for key, val in (("N_CH", nch), ("SPC", spc), ("K", k), ("G", g)):
            ET.SubElement(ps, "PARAMETER", {"NAME": key, "VALUE": str(val)})
    tree.write(os.path.splitext(dst)[0] + ".hwh")
    return dst


class RatePoints(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_old_hwh_rates_unchanged(self):
        v = hw_backend.load_variant(old_build("zcu216", "zcu216_v49_4ch_qsfp_f2_fs2457p6"))
        self.assertEqual(v.rate_k, 0)
        self.assertEqual(v.run_points(), [(f, 0) for f in v.run_factors()])
        self.assertEqual([v.at_point(f, 0).rate for f in v.run_factors()],
                         [v.adc_rate / f for f in v.run_factors()])

    def test_points_zcu216_2457p6(self):
        b = chained_build(self.tmp, old_build("zcu216", "zcu216_v49_4ch_qsfp_f2_fs2457p6"), 4, 4, 5)
        v = hw_backend.load_variant(b)
        self.assertEqual(v.rate_k, 5)
        low = [v.at_point(f, k) for f, k in v.run_points() if k > 0]
        self.assertEqual([x.rate for x in low], [30.72e6, 15.36e6, 7.68e6, 3.84e6, 1.92e6])
        for x in low:
            self.assertEqual(x.factor, 40)
            self.assertAlmostEqual(x.fabric_mhz, 15.36, places=9)
            self.assertAlmostEqual(x.tick_rate, 4 * x.rate, places=3)
        # the factors' rates are still there, unchanged
        self.assertEqual([v.at_point(f, 0).rate for f in v.run_factors()],
                         [v.adc_rate / f for f in v.run_factors()])

    def test_points_rfsoc4x2_4915p2(self):
        b = chained_build(self.tmp, old_build("rfsoc4x2", "rfsoc4x2_v49_1ch_qsfp_f2_fs4915p2"), 1, 8, 6)
        v = hw_backend.load_variant(b)
        rates = sorted(v.at_point(f, k).rate for f, k in v.run_points())
        self.assertEqual(rates[0], 1.92e6)
        self.assertEqual(rates[1], 3.84e6)

    def test_scan_lists_points(self):
        b = chained_build(self.tmp, old_build("zcu216", "zcu216_v49_4ch_qsfp_f2_fs2457p6"), 4, 4, 5)
        vs = hw_backend.scan_bitstreams(self.tmp)
        rates = {v.rate for v in vs if v.nch == 4}
        for r in (61.44e6, 30.72e6, 1.92e6):
            self.assertIn(r, rates)
        self.assertEqual({v.depth for v in vs if v.rate == 1.92e6}, {5})

    def test_depth_only_at_f40(self):
        b = chained_build(self.tmp, old_build("zcu216", "zcu216_v49_4ch_qsfp_f2_fs2457p6"), 4, 4, 5)
        v = hw_backend.load_variant(b)
        with self.assertRaises(ValueError):
            v.at_point(24, 1)
        with self.assertRaises(ValueError):
            v.at_point(40, 6)

    def test_hub_geometry_mismatch_skipped(self):
        # a hub built for another channel count than the build streams is refused
        b = chained_build(self.tmp, old_build("zcu216", "zcu216_v49_4ch_qsfp_f2_fs2457p6"), 2, 4, 5)
        with self.assertRaises(ValueError):
            hw_backend.load_variant(b)

    def test_at_factor_drops_depth(self):
        b = chained_build(self.tmp, old_build("zcu216", "zcu216_v49_4ch_qsfp_f2_fs2457p6"), 4, 4, 5)
        v = hw_backend.load_variant(b).at_point(40, 3)
        base = v.at_factor(v.built_factor)
        self.assertEqual((base.factor, base.depth, base.rate), (2, 0, 1228.8e6))

    def test_coerce_new_rates(self):
        b = chained_build(self.tmp, old_build("zcu216", "zcu216_v49_1ch_qsfp_f2_fs2457p6"), 1, 4, 5)
        v = hw_backend.load_variant(b)
        rates = [v.at_point(f, k).rate for f, k in v.run_points()]
        self.assertEqual(backend.coerce_rate(rates, 2e6), 1.92e6)
        self.assertEqual(backend.coerce_rate(rates, 1e6), 1.92e6)
        self.assertEqual(backend.coerce_rate(rates, 31e6), 30.72e6)
        self.assertEqual(backend.coerce_rate(rates, 61.44e6), 61.44e6)


class FakeEth:
    """A timekeeper advancing BEAT_TICKS per OUTPUT beat: the converter
    clock / 2^depth beats per second."""

    def __init__(self, fabric_mhz, beat_ticks, depth):
        self.rate = fabric_mhz * 1e6 * beat_ticks / (1 << depth)
        self.t0 = time.monotonic()

    def get_time(self):
        return int((time.monotonic() - self.t0) * self.rate)


class Measure(unittest.TestCase):
    def test_measure_scaling(self):
        for depth in (0, 3, 6):
            fake = type("F", (), {})()
            fake.eth = FakeEth(15.36, 16, depth)
            fake.beat_slots, fake.tick_step, fake.rate_depth = 16, 1, depth
            got = hw_backend.HwBackend._measure_fabric_mhz(fake, secs=0.05)
            self.assertAlmostEqual(got / 15.36, 1.0, delta=5e-3)


class FakeChain:
    def __init__(self, log, k_max=5):
        self.log, self.k_max, self._d = log, k_max, 0

    def hold(self, on):
        self.log.append(("hold", bool(on)))

    def set_depth(self, k):
        self.log.append(("depth", k))
        self._d = k

    def depth(self):
        return self._d


class RetuneOrder(unittest.TestCase):
    def _fake(self, factor):
        log = []
        f = type("F", (), {})()
        f.rate_chain = FakeChain(log)
        f.rx_decim = factor
        f.rate_depth = 0
        f._retune_factor = lambda v: log.append(("factor", v.factor))
        f._check_retune = lambda v: log.append(("check",))
        return f, log

    def _v(self, factor, depth):
        v = type("V", (), {})()
        v.factor, v.depth, v.name = factor, depth, "x"
        return v

    def test_retune_sequence_order(self):
        f, log = self._fake(2)
        hw_backend.HwBackend._retune_hw(f, self._v(40, 3))
        self.assertEqual(log, [("hold", True), ("depth", 0), ("factor", 40),
                               ("depth", 3), ("hold", False), ("check",)])
        self.assertEqual(f.rate_depth, 3)

    def test_depth_only_skips_rfdc(self):
        f, log = self._fake(40)
        f.rate_depth = 3
        hw_backend.HwBackend._retune_hw(f, self._v(40, 5))
        self.assertNotIn(("factor", 40), log)
        self.assertEqual(log, [("hold", True), ("depth", 0), ("depth", 5), ("hold", False), ("check",)])

    def test_back_to_depth0_holds_chain(self):
        f, log = self._fake(40)
        f.rate_depth = 2
        hw_backend.HwBackend._retune_hw(f, self._v(24, 0))
        self.assertEqual(log, [("hold", True), ("depth", 0), ("factor", 24), ("check",)])
        self.assertEqual(f.rate_depth, 0)

    def test_depth_without_chain_refused(self):
        f, log = self._fake(40)
        f.rate_chain = None
        with self.assertRaises(RuntimeError):
            hw_backend.HwBackend._retune_hw(f, self._v(40, 1))


class Regs:
    def __init__(self, k=5, spc=4, nch=4, g=1):
        self.r = {rate_chain.RATE_ID: rate_chain.RATE_ID_VALUE, rate_chain.RATE_CTRL: 1,
                  rate_chain.RATE_DEPTH: 0,
                  rate_chain.RATE_INFO: k | ({1: 0, 2: 1, 4: 2, 8: 3}[spc] << 8) | (nch << 16) | (g << 24),
                  rate_chain.RATE_STATUS: 0}

    def read(self, a):
        return self.r[a]

    def write(self, a, v):
        if a == rate_chain.RATE_DEPTH and v > (self.r[rate_chain.RATE_INFO] & 0xF):
            return              # the RTL ignores a DEPTH above K
        self.r[a] = v


class Driver(unittest.TestCase):
    def test_ratechain_bounds(self):
        rc = rate_chain.RateChain(Regs(), nch=4)
        self.assertEqual((rc.k_max, rc.spc, rc.nch), (5, 4, 4))
        rc.hold(True)
        rc.set_depth(5)
        self.assertEqual(rc.depth(), 5)
        with self.assertRaises(ValueError):
            rc.set_depth(6)
        with self.assertRaises(ValueError):
            rc.set_depth(-1)
        self.assertIsNone(rate_chain.RateChain.from_ip_dict({}, 4))

    def test_wrong_id_or_nch(self):
        r = Regs()
        r.r[rate_chain.RATE_ID] = 0
        with self.assertRaises(RuntimeError):
            rate_chain.RateChain(r, nch=4)
        with self.assertRaises(RuntimeError):
            rate_chain.RateChain(Regs(nch=2), nch=4)

    def test_from_ip_dict(self):
        made = []

        def mmio(addr, rng):
            made.append((addr, rng))
            return Regs()
        rc = rate_chain.RateChain.from_ip_dict(
            {"eth100g/rx_rate": {"phys_addr": 0x80090000, "addr_range": 0x10000}}, 4, mmio)
        self.assertIsNotNone(rc)
        self.assertEqual(made, [(0x80090000, 0x10000)])


if __name__ == "__main__":
    unittest.main()
