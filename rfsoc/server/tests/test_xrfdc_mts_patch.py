"""rfsoc/xrfdc_mts_patch.py against minimal copies of PYNQ 2.7's xrfdc wrapper
files: applies once, is a no-op the second time, refuses an unexpected layout.
No board needed (python3 -m unittest discover -s rfsoc/server/tests)."""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "xrfdc_mts_patch.py")
spec = importlib.util.spec_from_file_location("xrfdc_mts_patch", SCRIPT)
mp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mp)

# the anchors of the stock files, nothing else
STOCK_C = """\
typedef unsigned char u8;
typedef unsigned int u32;
typedef struct {
\tu32 DeviceId;
} XRFdc_Config;
typedef struct {
\tXRFdc_Config RFdc_Config;
} XRFdc;
u32 XRFdc_CfgInitialize(XRFdc *InstancePtr, XRFdc_Config *ConfigPtr);
void XRFdc_SetSignalFlow(XRFdc *InstancePtr, u32 Type);
u32 XRFdc_ResetInternalFIFOWidthObs(XRFdc *InstancePtr, u32 Tile_Id, u32 Block_Id);"""

STOCK_PY = """\
import cffi
import os

_THIS_DIR = os.path.dirname(__file__)
_ffi = cffi.FFI()
with open(os.path.join(_THIS_DIR, 'xrfdc_functions.c'), 'r') as f:
    _ffi.cdef(f.read())


def _safe_wrapper(name, *args, **kwargs):
    return name, args


class DefaultIP:
    def __init__(self, description):
        self.description = description


class RFdcAdcTile:
    pass


class RFdc(DefaultIP):
    def __init__(self, description):
        super().__init__(description)
        self._instance = _ffi.new("XRFdc*")
        self.adc_tiles = [RFdcAdcTile() for i in range(4)]

    def reset(self):
        return 0

    bindto = ["xilinx.com:ip:usp_rf_data_converter:2.6"]
"""


class PatchLogic(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        with open(os.path.join(self.d, mp.C_FILE), "w") as f:
            f.write(STOCK_C)
        with open(os.path.join(self.d, mp.PY_FILE), "w") as f:
            f.write(STOCK_PY)

    def tearDown(self):
        shutil.rmtree(self.d)

    def read(self, name):
        with open(os.path.join(self.d, name)) as f:
            return f.read()

    def test_stock_is_detected(self):
        self.assertEqual(mp.check(self.d), ("stock", "stock"))

    def test_apply_once_then_noop(self):
        self.assertTrue(mp.apply(self.d, log=lambda s: None))
        self.assertEqual(mp.check(self.d), ("patched", "patched"))
        self.assertTrue(os.path.exists(os.path.join(self.d, mp.C_FILE + ".stock")))
        self.assertEqual(self.read(mp.PY_FILE + ".stock"), STOCK_PY)
        c, p = self.read(mp.C_FILE), self.read(mp.PY_FILE)
        # second run: nothing written, files identical
        self.assertFalse(mp.apply(self.d, log=lambda s: None))
        self.assertEqual((self.read(mp.C_FILE), self.read(mp.PY_FILE)), (c, p))

    def test_patched_c_layout(self):
        c = mp.patch_c(STOCK_C)
        # the structs come after the typedefs they use and before the first prototype
        self.assertLess(c.index("typedef unsigned int u32;"), c.index("XRFdc_MTS_DTC_Settings"))
        self.assertLess(c.index("} XRFdc_MTS_Marker;"), c.index("u32 XRFdc_CfgInitialize"))
        self.assertTrue(c.rstrip().endswith(
            "void XRFdc_MultiConverter_Init(XRFdc_MultiConverter_Sync_Config *ConfigPtr, "
            "int *PLL_CodesPtr, int *T1_CodesPtr);"))
        self.assertIn("u32 XRFdc_ResetInternalFIFOWidthObs(XRFdc *InstancePtr, u32 Tile_Id, u32 Block_Id);\n"
                      "u32 XRFdc_MultiConverter_Sync(", c)

    def test_patched_py_layout(self):
        p = mp.patch_py(STOCK_PY)
        want_init = ("        self.adc_tiles = [RFdcAdcTile() for i in range(4)]\n"
                     "        self.mts_adc_config = _ffi.new('XRFdc_MultiConverter_Sync_Config*')\n"
                     "        self.mts_dac_config = _ffi.new('XRFdc_MultiConverter_Sync_Config*')\n"
                     "        _safe_wrapper(\"XRFdc_MultiConverter_Init\", self.mts_adc_config, "
                     "cffi.FFI.NULL, cffi.FFI.NULL)\n"
                     "        _safe_wrapper(\"XRFdc_MultiConverter_Init\", self.mts_dac_config, "
                     "cffi.FFI.NULL, cffi.FFI.NULL)\n"
                     "\n"
                     "    def mts_adc(self):\n"
                     "        return _safe_wrapper(\"XRFdc_MultiConverter_Sync\", self._instance, 0, "
                     "self.mts_adc_config)\n"
                     "\n"
                     "    def mts_dac(self):\n"
                     "        return _safe_wrapper(\"XRFdc_MultiConverter_Sync\", self._instance, 1, "
                     "self.mts_dac_config)\n"
                     "\n"
                     "    def reset(self):\n")
        self.assertIn(want_init, p)
        compile(p, "__init__.py", "exec")           # still valid Python

    def test_refuses_without_anchor(self):
        for bad_c in (STOCK_C.replace("typedef unsigned int u32;", "typedef unsigned int uint32;"),
                      "typedef unsigned int u32;\n/* no prototypes */\n"):
            with self.assertRaises(mp.LayoutError):
                mp.patch_c(bad_c)
        for bad_py in (STOCK_PY.replace("class RFdc(", "class RFdcX("),
                       STOCK_PY.replace("def _safe_wrapper(", "def _wrapper("),
                       STOCK_PY.replace("    def __init__(self, description):\n"
                                        "        super().__init__(description)\n"
                                        "        self._instance = _ffi.new(\"XRFdc*\")\n"
                                        "        self.adc_tiles = [RFdcAdcTile() for i in range(4)]\n",
                                        "    pass\n")):
            with self.assertRaises(mp.LayoutError):
                mp.patch_py(bad_py)

    def test_partial_is_refused_and_nothing_written(self):
        with open(os.path.join(self.d, mp.C_FILE), "a") as f:
            f.write("\nu32 XRFdc_MultiConverter_Sync(XRFdc *InstancePtr);\n")
        before = (self.read(mp.C_FILE), self.read(mp.PY_FILE))
        self.assertEqual(mp.check(self.d), ("partial", "stock"))
        with self.assertRaises(mp.LayoutError):
            mp.apply(self.d, log=lambda s: None)
        self.assertEqual((self.read(mp.C_FILE), self.read(mp.PY_FILE)), before)
        self.assertFalse(os.path.exists(os.path.join(self.d, mp.PY_FILE + ".stock")))

    def test_cli(self):
        run = lambda *a: subprocess.run([sys.executable, SCRIPT, *a, self.d],  # noqa: E731
                                        capture_output=True, text=True)
        self.assertEqual(run("--check").returncode, 1)
        self.assertEqual(run("--apply").returncode, 0)
        self.assertEqual(run("--check").returncode, 0)
        r = run("--apply")
        self.assertEqual(r.returncode, 0)
        self.assertIn("already present", r.stdout)

    @unittest.skipUnless(importlib.util.find_spec("cffi"), "cffi not installed")
    def test_patched_wrapper_imports_with_cffi(self):
        """The patched cdef parses and the class gets its MTS attributes, with
        the real cffi (the shared library is not needed for that)."""
        mp.apply(self.d, log=lambda s: None)
        pkg = os.path.join(self.d, "xrfdc")
        os.mkdir(pkg)
        for n in (mp.C_FILE, mp.PY_FILE):
            shutil.copy(os.path.join(self.d, n), pkg)
        r = subprocess.run([sys.executable, "-c",
                            "import sys; sys.path.insert(0, sys.argv[1]); import xrfdc; "
                            "assert hasattr(xrfdc.RFdc, 'mts_dac') and hasattr(xrfdc.RFdc, 'mts_adc'); "
                            "xrfdc._ffi.new('XRFdc_MultiConverter_Sync_Config*'); print('ok')",
                            self.d],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
