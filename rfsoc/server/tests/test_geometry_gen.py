#!/usr/bin/env python3
"""The .hwh geometry across RFDC generations: DAC VOP is Gen3 only (a Gen1
IP, the ZCU111's, reports C_DAC_VOP_Mode 1 without SetDACVOP)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import boards  # noqa: E402
import hw_backend  # noqa: E402


def params(ip_type=None, vop="1"):
    p = {"C_High_Speed_ADC": "1", "C_DAC_VOP_Mode": vop,
         "C_ADC_Slice00_Enable": "true", "C_ADC_Slice01_Enable": "true",
         "C_DAC_Slice00_Enable": "true"}
    for k in ("ADC", "DAC"):
        p[f"C_{k}0_Sampling_Rate"] = "3.93216"
        p[f"C_{k}0_Refclk_Freq"] = "3932.160"
        p[f"C_{k}0_PLL_Enable"] = "false"
        p[f"C_{k}0_Fabric_Freq"] = "245.760"
    for s in ("00", "01"):
        p[f"C_ADC_Decimation_Mode{s}"] = "2"
        p[f"C_ADC_Data_Width{s}"] = "8"
    p["C_DAC_Interpolation_Mode00"] = "2"
    p["C_DAC_Data_Width00"] = "16"
    if ip_type is not None:
        p["C_IP_Type"] = str(ip_type)
    return p


class GeometryGeneration(unittest.TestCase):
    def test_vop_gen3_only(self):
        b = boards.get_board("ZCU111")
        self.assertFalse(hw_backend.Geometry(params(0), b).vop_mode)     # Gen1
        self.assertTrue(hw_backend.Geometry(params(2), b).vop_mode)      # Gen3
        self.assertTrue(hw_backend.Geometry(params(None), b).vop_mode)   # older .hwh: Gen3
        self.assertFalse(hw_backend.Geometry(params(2, vop="0"), b).vop_mode)
        g = hw_backend.Geometry(params(0), b)
        self.assertEqual((g.ip_type, g.check()), (0, []))


if __name__ == "__main__":
    unittest.main()
