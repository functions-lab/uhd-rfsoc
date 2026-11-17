"""The board's clock source: the config key and the LMK04828 register file it selects."""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

import board_config  # noqa: E402
from rfsoc_lib.clocks import clock_plan  # noqa: E402

XRFCLK = os.path.join(os.path.dirname(os.path.dirname(HERE)), "rfsoc_lib", "xrfclk")


def regs(path):
    out = {}
    with open(path) as f:
        for line in f:
            v = int(line.split("\t")[-1], 16)
            out[(v >> 8) & 0x1FFF] = v & 0xFF
    return out


class ClockSource(unittest.TestCase):
    def test_config_key(self):
        self.assertEqual(board_config.parse("data_ip = 192.168.5.2\nclock_source = Internal\n")["clock_source"], "internal")
        with self.assertRaises(board_config.ConfigError):
            board_config.parse("clock_source = gps\n")
        self.assertEqual(board_config.clock_source("internal")[0], "internal")
        with tempfile.NamedTemporaryFile("w", suffix=".conf") as f:      # a config without the key: the default
            f.write("data_ip = 192.168.5.2\n")
            f.flush()
            self.assertEqual(board_config.clock_source(None, config=f.name)[0], "external")
            f.write("clock_source = internal\n")
            f.flush()
            self.assertEqual(board_config.clock_source(None, config=f.name)[0], "internal")

    def test_plan_per_source(self):
        for board, lmx in (("ZCU216", 2457.6), ("ZCU216", 2500.0), ("RFSoC4x2", 4915.2), ("RFSoC4x2", 5000.0)):
            pl = 122.88 if lmx in (2457.6, 4915.2) else 300.0
            d = os.path.join(XRFCLK, board)
            ki, xi = clock_plan(d, lmx_out=lmx, pl_clk=pl, source="internal")
            ke, xe = clock_plan(d, lmx_out=lmx, pl_clk=pl, source="external")
            self.assertEqual(ke.file, ki.file[:-4] + "_ext.txt")
            self.assertEqual(xe.file, xi.file)
            ri, re_ = regs(ki.loc), regs(ke.loc)
            self.assertEqual(ri[0x147] >> 4 & 7, 1)      # CLKin1 only
            self.assertEqual(re_[0x147] >> 4 & 7, 4)     # automatic: CLKin0, then CLKin1
            self.assertEqual(re_[0x146] >> 3 & 3, 3)     # both inputs enabled
            diff = {a for a in ri if ri[a] != re_.get(a)}
            self.assertLessEqual(diff, {0x146, 0x147})   # nothing else changes
        with self.assertRaises(ValueError):
            clock_plan(os.path.join(XRFCLK, "ZCU216"), lmx_out=2500.0, pl_clk=300.0, source="gps")


class NewBoardPlans(unittest.TestCase):
    def test_zcu208_plans(self):
        d = os.path.join(XRFCLK, "ZCU208")
        for lmx, pl, want in ((5000.0, 300.0, "LMX2594_250.0_5000.0.txt"),
                              (4800.0, 300.0, "LMX2594_250.0_4800.0.txt"),
                              (4915.2, 122.88, "LMX2594_245.76_4915.2.txt")):
            for src in ("internal", "external"):
                k, x = clock_plan(d, lmx_out=lmx, pl_clk=pl, source=src)
                self.assertEqual((k.chip, x.file), ("LMK04828", want))
                self.assertEqual(k.file.endswith("_ext.txt"), src == "external")

    def test_zcu111_plans(self):
        d = os.path.join(XRFCLK, "ZCU111")
        # two families (TICS Pro): 4000 from a 320 MHz LMX reference (PL_CLK
        # 320, SYSREF 5), 3932.16 from 122.88 (PL_CLK 122.88, SYSREF 7.68)
        for lmx, ref, sysref, want in ((4000.0, 320.0, 5.0, "LMX2594_320.0_4000.0.txt"),
                                       (3932.16, 122.88, 7.68, "LMX2594_122.88_3932.16.txt")):
            k, x = clock_plan(d, lmx_out=lmx, pl_clk=ref, source="internal")
            self.assertEqual((k.chip, k.freq_in, k.freq_out, k.mts_pl_sysref_freq),
                             ("LMK04208", 12.8, ref, sysref))
            self.assertEqual(x.file, want)
            k.read_registers(), x.read_registers()       # TICS Pro's CRLF exports parse
            self.assertEqual((len(k.reg), len(x.reg)), (26, 113))
        # no external-reference plan on the ZCU111 (yet)
        with self.assertRaises(FileNotFoundError):
            clock_plan(d, lmx_out=4000.0, pl_clk=320.0, source="external")


if __name__ == "__main__":
    unittest.main()
