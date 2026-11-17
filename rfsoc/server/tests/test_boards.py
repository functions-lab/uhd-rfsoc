#!/usr/bin/env python3
"""The board table (boards.py): channel maps, bitstream names, detection.
Pins what the bring-up and the .hwh scan rely on; a new board gets its own
case here."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import boards  # noqa: E402


class Boards(unittest.TestCase):
    def test_zcu216_channel_map(self):
        b = boards.get_board("zcu216")
        # Protocol §9: channel c = tile c // 4, block c % 4, one slice per ADC
        for c in range(16):
            self.assertEqual(b.dac_slice(c), (c // 4, c % 4))
            self.assertEqual(b.adc_slices(c), [(c // 4, c % 4)])
        self.assertEqual((b.mts_tiles, b.mts_ref_tile, b.masked_tiles), (0b1111, 1, ()))
        with self.assertRaises(ValueError):
            b.dac_slice(16)

    def test_rfsoc4x2_channel_map(self):
        b = boards.get_board("RFSoC4x2")
        # the SMA ports: ch0 DAC s20 / ADC m20 + m21, ch1 DAC s00 / ADC m02 + m03
        self.assertEqual([b.dac_slice(c) for c in (0, 1)], [(2, 0), (0, 0)])
        self.assertEqual([b.adc_slices(c) for c in (0, 1)], [[(2, 0), (2, 1)], [(0, 2), (0, 3)]])
        self.assertEqual([b.api_block(s) for s in b.adc_slices(1)], [(0, 1), (0, 1)])
        self.assertEqual((b.mts_tiles, b.mts_ref_tile, b.masked_tiles), (0b0101, 2, (1, 3)))
        self.assertEqual(b.adc_samples_per_clock(8), 8.0)
        with self.assertRaises(ValueError):
            b.adc_block(2)

    def test_zcu208_channel_map(self):
        b = boards.get_board("ZCU208")
        # channel c: ADC tile c % 4 converter c // 4 (I/Q on slices 2k, 2k+1),
        # DAC tile c % 4 slice 2 (c // 4); channels 0..3 = PYNQ's base overlay ports
        self.assertTrue(b.dual_adc)
        self.assertEqual([b.dac_slice(c) for c in range(8)],
                         [(0, 0), (1, 0), (2, 0), (3, 0), (0, 2), (1, 2), (2, 2), (3, 2)])
        self.assertEqual(b.adc_slices(0), [(0, 0), (0, 1)])
        self.assertEqual(b.adc_slices(5), [(1, 2), (1, 3)])
        self.assertEqual([b.api_block(s) for s in b.adc_slices(7)], [(3, 1), (3, 1)])
        # the CLK104's clocks enter ADC tile 1 (225) and DAC tile 2 (230)
        self.assertEqual((b.mts_tiles, b.mts_ref_tile), (0b1111, 2))
        self.assertEqual((b.mts_adc_tiles, b.mts_adc_ref_tile), (0b1111, 1))
        self.assertEqual((b.masked_tiles, b.gt_refclk), ((), "8a34001"))
        self.assertEqual(b.factors, boards.GEN3_FACTORS)
        with self.assertRaises(ValueError):
            b.dac_slice(8)

    def test_zcu111_channel_map(self):
        b = boards.get_board("ZCU111")
        # Gen1 ZU28DR: ADC tile c // 2 converter c % 2 (dual tiles), DAC tile
        # c // 4 block c % 4 (quad tiles, the default map)
        self.assertTrue(b.dual_adc)
        self.assertEqual([b.dac_slice(c) for c in range(8)], [(c // 4, c % 4) for c in range(8)])
        self.assertEqual([b.adc_slices(c) for c in (0, 1, 7)],
                         [[(0, 0), (0, 1)], [(0, 2), (0, 3)], [(3, 2), (3, 3)]])
        self.assertEqual([b.api_block(s) for s in b.adc_slices(3)], [(1, 1), (1, 1)])
        self.assertEqual((b.mts_tiles, b.mts_ref_tile, b.mts_adc_tiles, b.mts_adc_ref_tile),
                         (0b0011, 0, 0b1111, 0))
        self.assertEqual((b.factors, b.gt_refclk, b.masked_tiles), ((2, 4, 8), "si570", ()))
        self.assertEqual(boards.board_of_bitstream("zcu111_v49_4ch_qsfp_f4_fs4000.bit"), b)

    def test_mts_defaults_follow_the_dac(self):
        for name in ("ZCU216", "RFSOC4X2"):  # ZCU208 / ZCU111 set their own
            b = boards.BOARDS[name]
            self.assertEqual((b.mts_adc_tiles, b.mts_adc_ref_tile), (b.mts_tiles, b.mts_ref_tile))

    def test_bitstream_names(self):
        self.assertIs(boards.board_of_bitstream("zcu216_v49_4ch_qsfp_f2_fs2500.bit"),
                      boards.BOARDS["ZCU216"])
        self.assertIs(boards.board_of_bitstream("rfsoc4x2_v49_2ch_qsfp_f4_fs5000"),
                      boards.BOARDS["RFSOC4X2"])
        self.assertIs(boards.board_of_bitstream("zcu208_v49_8ch_qsfp_f8_fs5000.bit"),
                      boards.BOARDS["ZCU208"])
        self.assertIsNone(boards.board_of_bitstream("base.bit"))
        self.assertEqual(boards.BOARDS["ZCU216"].name_channels("zcu216_v49_16ch_qsfp_f8_fs2457p6.bit"), 16)
        for b in boards.BOARDS.values():
            self.assertTrue(os.path.basename(b.default_bitstream).startswith(b.prefix + "_v49_1ch_qsfp"))

    def test_detect(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIs(boards.detect_board(d), boards.BOARDS[boards.DEFAULT_BOARD])
            open(os.path.join(d, "rfsoc4x2_v49_1ch_qsfp_f2_fs5000.bit"), "w").close()
            self.assertIs(boards.detect_board(d), boards.BOARDS["RFSOC4X2"])
            open(os.path.join(d, "zcu216_v49_1ch_qsfp_f2_fs2500.bit"), "w").close()
            with self.assertRaises(ValueError):
                boards.detect_board(d)        # two boards' builds: --board needed
            self.assertIs(boards.detect_board(d, "zcu216_v49_1ch_qsfp_f2_fs2500.bit"),
                          boards.BOARDS["ZCU216"])

    def test_every_board_has_its_clock_files(self):
        here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        for b in boards.BOARDS.values():
            self.assertTrue(os.path.isdir(os.path.join(here, "rfsoc_lib", "xrfclk", b.name)), b.name)
            files = os.listdir(os.path.join(here, "rfsoc_lib", "xrfclk", b.name))
            self.assertEqual(any(f.startswith("LMK") and f.endswith("_ext.txt") for f in files),
                             b.external_ref, b.name)


if __name__ == "__main__":
    unittest.main()
