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


if __name__ == "__main__":
    unittest.main()
