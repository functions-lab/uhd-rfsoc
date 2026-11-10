"""The TX DPD (Protocol §12) without a board: the model and fit in
rfsoc_lib/dsp/dpd.py, and the tx_dpd.py driver against a register-level fake
of tx_dpd.v (python3 -m unittest discover -s rfsoc/server/tests)."""
import os
import sys
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))                    # rfsoc/server
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))   # rfsoc (rfsoc_lib)
from rfsoc_lib.dsp import dpd  # noqa: E402
import tx_dpd  # noqa: E402


def waveform(n=4096, peak=0.7, seed=1):
    """Band-limited complex noise, int16, peak `peak` x full scale."""
    rng = np.random.default_rng(seed)
    x = rng.normal(size=n) + 1j * rng.normal(size=n)
    f = np.fft.fftfreq(n)
    x = np.fft.ifft(np.fft.fft(x) * (np.abs(f) < 0.15))
    x *= peak * 32767 / np.abs(x).max()
    return np.rint(x.real) + 1j * np.rint(x.imag)


def pa(z):
    """A memory PA: 3rd / 5th-order compression after a 2-tap filter, a delay
    of 3.3 samples and a loop gain of 0.5 / 60 deg."""
    u = np.convolve(z, [1.0, 0.15 - 0.05j])[:z.size]
    y = u * (1 - 0.25 * np.abs(u) ** 2 + 0.05 * np.abs(u) ** 4)
    return 0.5 * np.exp(1j * np.pi / 3) * dpd.apply_delay(y, 3.3)


class Model(unittest.TestCase):
    def test_identity_is_exact(self):
        x = waveform()
        x[:4] = [-32768 - 32768j, 32767 + 32767j, -32768 + 32767j, 0]
        r = dpd.dpd_fx(x.real, x.imag, [dpd.identity_q()])
        np.testing.assert_array_equal(r.i, x.real)
        np.testing.assert_array_equal(r.q, x.imag)
        self.assertEqual(r.sat_out.sum() + r.sat_gain.sum(), 0)

    def test_fixed_point_follows_the_float_model(self):
        x = waveform()
        c = dpd.dequantize(dpd.identity_q())
        c[dpd.idx_a(0, 1)] = -0.3 + 0.1j
        c[dpd.idx_a(1, 0)] = 0.05
        c[dpd.idx_b(0, 1)] = 0.02j
        cq = dpd.quantize(c)
        r = dpd.dpd_fx(x.real, x.imag, [cq])
        zf = dpd.dpd_float(x / 32768, dpd.dequantize(cq)) * 32768
        self.assertLess(np.abs(r.i + 1j * r.q - zf).max(), 2.0)

    def test_words_and_checks(self):
        cq = dpd.quantize(np.linspace(-3, 3, 20) * (1 - 0.5j))
        np.testing.assert_array_equal(dpd.from_words(dpd.to_words(cq)), cq)
        self.assertEqual(dpd.check_q(cq.reshape(-1)).shape, (20, 2))
        with self.assertRaises(ValueError):
            dpd.check_q([0] * 39)
        with self.assertRaises(ValueError):
            dpd.check_q([31 << 21] + [0] * 39)
        self.assertAlmostEqual(dpd.gain_bound(dpd.identity_q()), 1.0)

    def test_set_switch_and_bypass_per_sample(self):
        x = waveform(64)
        c = dpd.dequantize(dpd.identity_q())
        c[0] = 0.5
        sets = [dpd.identity_q(), dpd.quantize(c)]
        idx = np.r_[np.zeros(32, int), np.ones(32, int)]
        byp = np.r_[np.zeros(48, bool), np.ones(16, bool)]
        r = dpd.dpd_fx(x.real, x.imag, sets, set_idx=idx, bypass=byp)
        np.testing.assert_array_equal(r.i[:32], x.real[:32])
        np.testing.assert_array_equal(r.i[48:], x.real[48:])
        self.assertTrue(np.all(np.abs(r.i[32:48] - np.rint(x.real[32:48] / 2)) <= 1))

    def test_ila_linearises_a_memory_pa(self):
        x = waveform()
        cq, gain = dpd.identity_q(), None
        nmse = []
        for it in range(5):
            r = dpd.dpd_fx_periodic(x, cq)
            y = pa((r.i + 1j * r.q) / 32768)
            nmse.append(dpd.measure(y, x, 1.0, 0.3)["nmse_db"])
            res = dpd.ila_step(x, cq, y, gain=gain, damping=1.0 if it == 0 else 0.7)
            gain = res.gain
            self.assertTrue(3.3 <= res.delay < 3.6, res.delay)     # + the filter's group delay
            cq = dpd.quantize(res.c)
            ok, peak, so, sg = dpd.gate(x, cq)
            self.assertTrue(ok, (peak, so, sg))
        self.assertGreater(nmse[0] - nmse[-1], 15.0, nmse)
        m0 = dpd.measure(pa(x / 32768), x, 1.0, 0.3)
        r = dpd.dpd_fx_periodic(x, cq)
        m1 = dpd.measure(pa((r.i + 1j * r.q) / 32768), x, 1.0, 0.3)
        self.assertGreater(m0["acpr_hi"] - m1["acpr_hi"], 10.0, (m0, m1))


class FakeDpdRegs:
    """tx_dpd.v at register level: a COMMIT / CTRL applies at once (the
    crossing in zero time), unless `stalled` (the converter clock stopped)."""

    def __init__(self, nch, ssr=4):
        self.nch, self.ssr, self.stalled = nch, ssr, False
        ident = dpd.to_words(dpd.identity_q())
        self.ch = [{"byp": 1, "sh": list(ident), "act": list(ident), "cnt": 1, "pend": 0}
                   for _ in range(nch)]

    def read(self, off):
        c, o = divmod(off, dpd.CH_STRIDE)
        if c >= self.nch:
            return 0
        r = self.ch[c]
        if o == dpd.REG_ID:
            return dpd.DPD_ID
        if o == dpd.REG_TOPO:
            return self.nch | (self.ssr << 8) | (c << 16)
        if o == dpd.REG_CTRL:
            return r["byp"]
        if o == dpd.REG_STATUS:
            return r["byp"] | r["pend"] | (r["cnt"] << 8)
        if dpd.REG_SHADOW <= o < dpd.REG_SHADOW + 160:
            return r["sh"][(o - dpd.REG_SHADOW) // 4]
        if dpd.REG_ACTIVE <= o < dpd.REG_ACTIVE + 160:
            return r["act"][(o - dpd.REG_ACTIVE) // 4]
        return 0

    def write(self, off, v):
        c, o = divmod(off, dpd.CH_STRIDE)
        r = self.ch[c]
        if dpd.REG_SHADOW <= o < dpd.REG_SHADOW + 160:
            r["sh"][(o - dpd.REG_SHADOW) // 4] = v & ((1 << 27) - 1)
        elif o == dpd.REG_CTRL:
            r["byp"] = v & 1
            if self.stalled:
                r["pend"] = (dpd.STATUS_COMMIT_PENDING if v & dpd.CTRL_COMMIT else 0) \
                    | dpd.STATUS_MSG_PENDING
            elif v & dpd.CTRL_COMMIT:
                r["act"], r["cnt"] = list(r["sh"]), (r["cnt"] + 1) & 0xFF


class Driver(unittest.TestCase):
    def test_commit_enable_stats(self):
        regs = FakeDpdRegs(4)
        d = tx_dpd.TxDpd(regs, 4)
        self.assertEqual(d.ssr, 4)
        c = dpd.dequantize(dpd.identity_q())
        c[dpd.idx_a(2, 3)] = -1.5 + 2j
        cq = dpd.quantize(c)
        d.commit(2, cq, True)
        np.testing.assert_array_equal(d.read_active(2), cq)
        self.assertEqual(regs.ch[2]["byp"], 0)
        self.assertEqual(regs.ch[1]["act"], dpd.to_words(dpd.identity_q()))
        d.set_enable(2, False)
        self.assertEqual(regs.ch[2]["byp"], 1)
        st = d.stats(2)
        self.assertEqual((st["commits"], st["bypass"]), (2, 1))
        with self.assertRaises(ValueError):
            d.set_enable(4, True)

    def test_refuses_a_wrong_block_and_times_out(self):
        regs = FakeDpdRegs(2)
        with self.assertRaises(RuntimeError):
            tx_dpd.TxDpd(regs, 4)                  # TOPO says 2 channels
        d = tx_dpd.TxDpd(regs, 2)
        regs.stalled = True
        with self.assertRaises(RuntimeError):
            d.commit(0, dpd.identity_q(), False)
        self.assertIsNone(tx_dpd.TxDpd.from_ip_dict({"eth100g/udp_player": {}}, 2))


if __name__ == "__main__":
    unittest.main()
