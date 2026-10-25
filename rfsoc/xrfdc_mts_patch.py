#!/usr/bin/env python3
"""Add the multi-tile-sync (MTS) bindings to PYNQ's xrfdc Python wrapper.

PYNQ 2.7's `xrfdc` package (the RFSoC 4x2 image) wraps libxrfdc.so with cffi
but declares none of the MTS API, so `RFdc` has no `mts_dac_config` /
`mts_adc_config` / `mts_dac()` / `mts_adc()`, which rfsoc_lib.mts needs and the
daemon refuses to run without. The shared library itself already exports
XRFdc_MultiConverter_Init / XRFdc_MultiConverter_Sync; only two wrapper files
need the declarations PYNQ 3.x ships:

  xrfdc_functions.c   the cffi cdef source: the three MTS structs are added
                      before the first function prototype, the two MTS
                      prototypes at the end
  __init__.py         class RFdc: the two config structs are created at the
                      end of __init__ and the methods mts_adc() / mts_dac()
                      added

Idempotent: a file that already has the bindings is left alone; a file whose
layout is not the expected one (neither stock nor patched, or without the
anchors) is refused and nothing is written. The originals are kept once as
`<file>.stock`. rfsoc/setup_board.sh runs this in the PYNQ venv and verifies
the import; by hand:

    sudo <pynq venv>/bin/python3 xrfdc_mts_patch.py --check [XRFDC_DIR]
    sudo <pynq venv>/bin/python3 xrfdc_mts_patch.py --apply [XRFDC_DIR]

XRFDC_DIR defaults to the installed package's directory. Exit status: 0 = the
bindings are there (--apply: were added or already present), 1 = --check:
missing, 2 = refused (unexpected layout) or error.
"""
import argparse
import os
import py_compile
import re
import shutil
import sys
from typing import Tuple

C_FILE, PY_FILE = "xrfdc_functions.c", "__init__.py"

C_TYPEDEFS = """
/**
 * MTS DTC Settings.
 */
typedef struct {
\tu32 RefTile;
\tu32 IsPLL;
\tint Target[4];
\tint Scan_Mode;
\tint DTC_Code[4];
\tint Num_Windows[4];
\tint Max_Gap[4];
\tint Min_Gap[4];
\tint Max_Overlap[4];
} XRFdc_MTS_DTC_Settings;

/**
 * MTS Sync Settings.
 */
typedef struct {
\tu32 RefTile;
\tu32 Tiles;
\tint Target_Latency;
\tint Offset[4];
\tint Latency[4];
\tint Marker_Delay;
\tint SysRef_Enable;
\tXRFdc_MTS_DTC_Settings DTC_Set_PLL;
\tXRFdc_MTS_DTC_Settings DTC_Set_T1;
} XRFdc_MultiConverter_Sync_Config;

/**
 * MTS Marker Struct.
 */
typedef struct {
\tu32 Count[4];
\tu32 Loc[4];
} XRFdc_MTS_Marker;

"""

C_PROTOTYPES = """
u32 XRFdc_MultiConverter_Sync(XRFdc *InstancePtr, u32 Type, XRFdc_MultiConverter_Sync_Config *ConfigPtr);
void XRFdc_MultiConverter_Init(XRFdc_MultiConverter_Sync_Config *ConfigPtr, int *PLL_CodesPtr, int *T1_CodesPtr);
"""

# what the patched files contain and the stock ones lack
C_MARKERS = ("XRFdc_MTS_DTC_Settings", "XRFdc_MultiConverter_Sync_Config",
             "XRFdc_MTS_Marker", "XRFdc_MultiConverter_Sync(", "XRFdc_MultiConverter_Init(")
PY_MARKERS = ("mts_adc_config", "mts_dac_config", "def mts_adc(", "def mts_dac(",
              "XRFdc_MultiConverter_Init", "XRFdc_MultiConverter_Sync")

PY_INIT_TAIL = """\
{b}self.mts_adc_config = _ffi.new('XRFdc_MultiConverter_Sync_Config*')
{b}self.mts_dac_config = _ffi.new('XRFdc_MultiConverter_Sync_Config*')
{b}_safe_wrapper("XRFdc_MultiConverter_Init", self.mts_adc_config, cffi.FFI.NULL, cffi.FFI.NULL)
{b}_safe_wrapper("XRFdc_MultiConverter_Init", self.mts_dac_config, cffi.FFI.NULL, cffi.FFI.NULL)
"""

PY_METHODS = """\

{m}def mts_adc(self):
{b}return _safe_wrapper("XRFdc_MultiConverter_Sync", self._instance, 0, self.mts_adc_config)

{m}def mts_dac(self):
{b}return _safe_wrapper("XRFdc_MultiConverter_Sync", self._instance, 1, self.mts_dac_config)
"""

# the first function prototype of the cdef (any XRFdc_* function at the start
# of a line, whatever its return type)
_C_PROTO = re.compile(r"^[A-Za-z_][A-Za-z0-9_ ]*\**\s*XRFdc_\w+\s*\(", re.M)
_C_U32 = re.compile(r"^\s*typedef\s+[\w ]+\s+u32\s*;", re.M)


class LayoutError(Exception):
    """The file is neither stock nor patched, or lacks the anchors."""


def status(text: str, markers: Tuple[str, ...]) -> str:
    """'patched' (every marker), 'stock' (none) or 'partial'."""
    n = sum(m in text for m in markers)
    return "patched" if n == len(markers) else "stock" if n == 0 else "partial"


def patch_c(text: str) -> str:
    st = status(text, C_MARKERS)
    if st == "patched":
        return text
    if st == "partial":
        raise LayoutError(f"{C_FILE}: some MTS declarations present, not all; "
                          "restore the stock file first")
    m = _C_PROTO.search(text)
    if not m:
        raise LayoutError(f"{C_FILE}: no XRFdc_* function prototype found")
    if not _C_U32.search(text[:m.start()]):
        raise LayoutError(f"{C_FILE}: no 'typedef ... u32;' before the first prototype")
    out = text[:m.start()] + C_TYPEDEFS.lstrip("\n") + "\n" + text[m.start():]
    if not out.endswith("\n"):
        out += "\n"
    return out + C_PROTOTYPES.lstrip("\n")


def patch_py(text: str) -> str:
    st = status(text, PY_MARKERS)
    if st == "patched":
        return text
    if st == "partial":
        raise LayoutError(f"{PY_FILE}: some MTS bindings present, not all; "
                          "restore the stock file first")
    for need in ("import cffi", "_ffi = ", "def _safe_wrapper("):
        if need not in text:
            raise LayoutError(f"{PY_FILE}: expected '{need}' (not PYNQ's xrfdc wrapper?)")
    lines = text.splitlines(keepends=True)
    cls = next((i for i, ln in enumerate(lines) if re.match(r"^class RFdc\b", ln)), None)
    if cls is None:
        raise LayoutError(f"{PY_FILE}: no 'class RFdc'")
    init = None
    for i in range(cls + 1, len(lines)):
        if re.match(r"^\S", lines[i]):          # the class ended
            break
        if re.match(r"^\s+def __init__\(", lines[i]):
            init = i
            break
    if init is None:
        raise LayoutError(f"{PY_FILE}: class RFdc has no __init__")
    method_indent = re.match(r"^(\s+)", lines[init]).group(1)
    body_indent = None
    end = len(lines)                             # first line after __init__'s body
    for i in range(init + 1, len(lines)):
        ln = lines[i]
        if not ln.strip():
            continue
        ind = re.match(r"^(\s*)", ln).group(1)
        if len(ind) <= len(method_indent):
            end = i
            break
        if body_indent is None:
            body_indent = ind
    if body_indent is None:
        raise LayoutError(f"{PY_FILE}: RFdc.__init__ has no body")
    # back up over the blank lines that separate __init__ from the next method
    while end > init + 1 and not lines[end - 1].strip():
        end -= 1
    tail = PY_INIT_TAIL.format(b=body_indent)
    methods = PY_METHODS.format(m=method_indent, b=body_indent)
    return "".join(lines[:end]) + tail + methods + "".join(lines[end:])


def check(xrfdc_dir: str) -> Tuple[str, str]:
    """(status of the C file, status of __init__.py)."""
    with open(os.path.join(xrfdc_dir, C_FILE)) as f:
        c = status(f.read(), C_MARKERS)
    with open(os.path.join(xrfdc_dir, PY_FILE)) as f:
        p = status(f.read(), PY_MARKERS)
    return c, p


def apply(xrfdc_dir: str, log=print) -> bool:
    """Patch both files (each only if stock). Both are vetted before either
    is written. -> True if anything was written."""
    paths = {n: os.path.join(xrfdc_dir, n) for n in (C_FILE, PY_FILE)}
    texts = {}
    for n, p in paths.items():
        with open(p) as f:
            texts[n] = f.read()
    new = {C_FILE: patch_c(texts[C_FILE]), PY_FILE: patch_py(texts[PY_FILE])}
    changed = False
    for n, p in paths.items():
        if new[n] == texts[n]:
            log(f"{p}: MTS bindings already present")
            continue
        backup = p + ".stock"
        if not os.path.exists(backup):
            shutil.copy2(p, backup)
            log(f"{p}: original kept as {os.path.basename(backup)}")
        with open(p, "w") as f:
            f.write(new[n])
        changed = True
        log(f"{p}: MTS bindings added")
    if status(new[C_FILE], C_MARKERS) != "patched" or status(new[PY_FILE], PY_MARKERS) != "patched":
        raise LayoutError("patched files do not read back as patched")
    py_compile.compile(paths[PY_FILE], doraise=True)
    pyc = os.path.join(xrfdc_dir, "__pycache__")
    if changed and os.path.isdir(pyc):
        shutil.rmtree(pyc, ignore_errors=True)
        log(f"{pyc}: cleared")
    return changed


def installed_dir() -> str:
    import xrfdc
    return os.path.dirname(os.path.abspath(xrfdc.__file__))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="report, change nothing")
    g.add_argument("--apply", action="store_true", help="add the bindings where missing")
    ap.add_argument("xrfdc_dir", nargs="?", help="the xrfdc package directory "
                    "[the installed xrfdc's]")
    a = ap.parse_args(argv)
    try:
        d = a.xrfdc_dir or installed_dir()
    except ImportError as e:
        print(f"cannot import xrfdc ({e}): run this with the PYNQ venv's python3 "
              "on the board, or name the xrfdc directory", file=sys.stderr)
        return 2
    try:
        if a.check:
            c, p = check(d)
            print(f"{d}: {C_FILE} {c}, {PY_FILE} {p}")
            if c == "patched" and p == "patched":
                return 0
            return 2 if "partial" in (c, p) else 1
        apply(d)
        return 0
    except (OSError, LayoutError, py_compile.PyCompileError) as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
