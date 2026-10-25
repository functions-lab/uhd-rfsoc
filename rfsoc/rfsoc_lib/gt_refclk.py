"""GT reference clock for the 100G CMAC: the Renesas 8A34001 ClockMatrix (U409).

Where the refclk comes from
---------------------------
The GTY quads that reach the zSFP cages (128/129) take MGTREFCLK1 from U409:

    8A34001 Q11 (output stage 7, FOD_7) -> MGTREFCLK1_128  (Y34/Y35)
    8A34001 Q7  (output stage 3, FOD_3) -> MGTREFCLK1_129  (T34/T35)

Output frequency = FOD frequency (DPLL_CTRL_n.DPLL_FOD_FREQ, M/N Hz) divided by
OUTPUT_n.OUT_DIV. The FODs run off the system APLL, so nothing comes out while
STATUS.SYS_APLL_STATUS says unlocked.

Bus facts (measured on a ZCU216)
--------------------------------
* /dev/i2c-10 = channel 4 of the TCA9548A at 1-0074 (PS I2C1). The bus number
  is resolved from sysfs at run time; do not hard-code it.
* 7-bit address **0x5B**. UG1390 says 0x58, but 0x58/0x59/0x5A NACK and
  STATUS.SER0_I2C_STATUS reports 0x5B. The S_A0/S_A1 straps are both high.
* Serial port 0 is I2C in 1-byte-offset mode (STATUS.SER0_STATUS = 0x01). The
  low address byte comes from the transaction. The upper byte comes from the
  per-port page register at offset 0xFC (4 bytes: 00 <page> 10 20), and every
  page can read that register. So the only reads that need no bus write at
  all are:
      page register (offset 0xFC..0xFF)
      whatever page is currently selected (0xC0 on a ZCU216 after boot: GENERAL_STATUS
      and STATUS)
  A read is "offset byte, repeated start, read" (programming guide fig. 2).
  The offset byte loads the port's address pointer and writes no register.
  To read the output/FOD registers you must write the page register. That
  write is addressing state only (no clock effect), but it is a write, so
  `read_status()` does it only when asked (`allow_page_select=True`) and
  puts the page back afterwards.
* Firmware 4.8.0, PRODUCT_ID 0x4001, BOOT_STATUS 0xA0. OTP config, OTP CSR config and
  EEPROM config all report 1 = "not found", so the chip boots with every
  register at its default. The defaults are FOD M = 0 (FOD off), OUT_DIV = 0,
  and OUT_CTRL_0.PAD_MODE = 0 (high-Z). SYS_APLL_STATUS = 0x11: the APLL is not
  locked, and the sticky bit shows it lost lock. All eight DPLLs are in
  freerun. **Q7 and Q11 output no clock today** unless something programs the
  chip after each power-up.

Programming
-----------
`program_gt_refclk()` applies a register file of (16-bit register address,
byte) writes. It accepts a Renesas Timing Commander ".txt" export, a Linux
rsmu "idtcm.bin" image, or a plain two-column "addr value" list; see
`parse_register_file`. It works like the Linux ptp_clockmatrix loader:

  * It skips the status area (< 0xC160 = GPIO_USER_CONTROL) and everything
    from SCRATCH up (the EEPROM/OTP/BYTE command modules).
  * It skips page offsets 0x7C-0x7F and 0xFC-0xFF, which the page register
    shadows.
  * If the file is a full configuration, it first issues
    RESET_CTRL.SM_RESET = 0x5A, then waits for BOOT_STATUS == 0xA0.
  * It writes each page as bursts. The guide requires a multi-byte field to
    arrive in one burst, and the highest byte of each module is its trigger.
  * Then it polls the system APLL lock and reads Q7/Q11 back.

Before any write, it replays the file into a register image and computes the
Q7/Q11 frequencies the file would produce. If those are not `freq_mhz`, it
refuses, so a wrong file fails without touching the bus. `dry_run=True` stops
after printing every I2C transaction.

The 156.25 MHz register file is `xrfclk/ZCU216/gt_refclk_8a34001_156M25.txt`. It is Xilinx's VCK190/VPK120 default 8A34001 design
(system-controller-app, BIT/clock_files/8A34001/8A34001_2020-0318_156MHz.txt:
54 MHz crystal, XO_DPLL 38.4 MHz, FOD0-3/5/6 at 625 MHz, Q0-Q10 at 156.25 MHz)
with 14 bytes changed, all listed in the file header:
  * Q11 is coupled to FOD6 (OUT_DIV_MUX.OUT_DIV11_MUX = 1), divides by 4, and
    uses Q7's pad settings.
  * Every other output except Q7 is high-Z, so outputs that were silent stay
    silent.
It is not a full configuration by the Linux test, so there is no SM_RESET,
which matches how Xilinx's own loader (8A34001.py Program_Clock) applies it.
It ASSUMES that the ZCU216's U409 has the VCK190's 54 MHz crystal (the
ZCU216 schematic is not public). If it does not, the APLL-lock poll fails
and `program_gt_refclk` raises. No ZCU216-specific Timing Commander export
was found in public: the ASIAA "8A34001_20220215_all_156M25.txt" and the
BoardUI clockFiles are not downloadable. If you get one, pass
`regfile=`.

Rules: use only the kernel's muxed adapter (never write the TCA9548 control
register), never touch the TCA6416 0x20 P1.5 reset line, and never run the
write path while the 100G link is in use (it restarts the GT refclk).
"""
from __future__ import annotations

import ctypes
import fcntl
import os
import re
import time
from fractions import Fraction
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------
# board wiring
# --------------------------------------------------------------------------
RENESAS_OUTPUTS = {"Q11": "MGTREFCLK1_128", "Q7": "MGTREFCLK1_129"}
CMAC_REFCLK_CHOICES_MHZ = (156.25, 161.1328125, 322.265625)
MUX_DEVICE = "1-0074"          # TCA9548A U20 on PS I2C1
MUX_CHANNEL = 4                # UG1390 table 11: port 4 = 8A34001 U409
I2C_ADDR = 0x5B                # measured; UG1390's 0x58 NACKs
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REGFILE = {156.25: os.path.join(HERE, "xrfclk", "ZCU216", "gt_refclk_8a34001_156M25.txt")}

# --------------------------------------------------------------------------
# 8A3xxxx register map (Family Programming Guide v4.8, Linux idt8a340_reg.h).
# Addresses are the 16-bit offsets; the full address is 0x2010_0000 | addr.
# --------------------------------------------------------------------------
PAGE_OFFSET = 0xFC
PAGE_HI = (0x10, 0x20)          # PAGE_ADDR[23:16], [31:24]: always 10h, 20h
RESET_CTRL = 0xC000
SM_RESET = {False: 0x12, True: 0x13}     # key: firmware >= 5.2
SM_RESET_CMD = 0x5A
GENERAL_STATUS = 0xC014
STATUS = 0xC03C
GPIO_USER_CONTROL = 0xC160      # first user-writable register
SCRATCH = {False: 0xCF50, True: 0xCF4C}  # writes stop here (EEPROM/OTP/BYTE)
DPLL_CTRL = (0xC600, 0xC63C, 0xC680, 0xC6BC, 0xC700, 0xC73C, 0xC780, 0xC7BC)
DPLL_FOD_FREQ = 0x1C            # M[47:0] (6 bytes) then N[15:0]
OUT_DIV_MUX = 0xCA12            # +0 FOD5_TO_OUT_DIV8, +1 FOD6_TO_OUT_DIV11
OUTPUT = {False: (0xCA14, 0xCA24, 0xCA34, 0xCA44, 0xCA54, 0xCA64,
                  0xCA80, 0xCA90, 0xCAA0, 0xCAB0, 0xCAC0, 0xCAD0),
          True: (0xCA20, 0xCA30, 0xCA40, 0xCA50, 0xCA60, 0xCA80,
                 0xCA90, 0xCAA0, 0xCAB0, 0xCAC0, 0xCAD0, 0xCAE0)}
OUT_DIV, OUT_CTRL_0, OUT_CTRL_1 = 0x0, 0x8, 0x9
# output pin -> (output-stage divider index, FOD in normal mode); datasheet table 14
Q_STAGE = {0: 0, 1: 0, 2: 1, 3: 1, 4: 2, 5: 2, 6: 3, 7: 3, 8: 4, 9: 5, 10: 6, 11: 7}
# The OUTPUT_n module index equals the Q number (12 output dividers, 8 FODs).
PAD_MODES = {0: "high-Z", 1: "differential", 2: "LVCMOS inverted",
             3: "LVCMOS in-phase", 6: "LVCMOS Q only"}
DPLL_STATES = {0: "freerun", 1: "lockacq", 2: "lockrec", 3: "locked",
               4: "holdover", 5: "open_loop", 6: "disabled"}
CONFIG_STATUS = {0: "success", 1: "not found", 2: "incomplete", 3: "wrong offset",
                 4: "wrong length", 5: "out of range", 6: "CRC error",
                 0xA: "corrupt header", 0xB: "EEPROM out of range"}

Write = Tuple[int, bytes]       # (16-bit start address, burst data)


class PageWriteRequired(RuntimeError):
    """Reading this register needs a page-register write, which was not allowed."""


# --------------------------------------------------------------------------
# sysfs (no bus access)
# --------------------------------------------------------------------------
def find_bus(mux: str = MUX_DEVICE, channel: int = MUX_CHANNEL) -> int:
    """/dev/i2c-N of the kernel's muxed adapter for `mux` channel `channel`."""
    link = f"/sys/bus/i2c/devices/{mux}/channel-{channel}"
    target = os.path.basename(os.path.realpath(link))
    m = re.fullmatch(r"i2c-(\d+)", target)
    if not m:
        raise FileNotFoundError(f"{link} does not resolve to an i2c adapter "
                                f"(pca954x driver not bound?)")
    return int(m.group(1))


# --------------------------------------------------------------------------
# transport: raw I2C_RDWR on the kernel's muxed adapter (no smbus2 on the board)
# --------------------------------------------------------------------------
_I2C_RDWR = 0x0707
_I2C_M_RD = 0x0001


class _I2cMsg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class _I2cRdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(_I2cMsg)), ("nmsgs", ctypes.c_uint32)]


class I2cDev:
    """One 7-bit client on /dev/i2c-N. Every call is one atomic I2C_RDWR, so
    the kernel holds the mux lock for the whole combined transaction."""

    def __init__(self, bus: int, addr: int = I2C_ADDR):
        self.bus, self.addr = bus, addr
        self.fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)

    def close(self) -> None:
        os.close(self.fd)

    def _xfer(self, msgs: Sequence[Tuple[int, bytearray]]) -> None:
        arr = (_I2cMsg * len(msgs))()
        keep = []
        for i, (flags, buf) in enumerate(msgs):
            cbuf = (ctypes.c_uint8 * len(buf)).from_buffer(buf)
            keep.append(cbuf)
            arr[i] = _I2cMsg(self.addr, flags, len(buf),
                             ctypes.cast(cbuf, ctypes.POINTER(ctypes.c_uint8)))
        req = _I2cRdwr(arr, len(msgs))
        fcntl.ioctl(self.fd, _I2C_RDWR, req)

    def read(self, offset: int, n: int) -> bytes:
        """offset byte, repeated start, n-byte read. Loads the pointer, writes no register."""
        out = bytearray(n)
        self._xfer([(0, bytearray([offset & 0xFF])), (_I2C_M_RD, out)])
        return bytes(out)

    def write(self, offset: int, data: bytes) -> None:
        self._xfer([(0, bytearray([offset & 0xFF]) + bytearray(data))])


# --------------------------------------------------------------------------
# paged register access
# --------------------------------------------------------------------------
class ClockMatrix:
    """Paged access to an 8A3xxxx in I2C 1-byte-offset mode.

    `dev` needs `read(offset, n) -> bytes` and `write(offset, data)`. A dry-run
    or unit-test fake can stand in for I2cDev. `allow_writes=False` makes
    every write, including a page select, raise.
    """

    def __init__(self, dev, allow_writes: bool = False,
                 log: Optional[Callable[[str], None]] = None):
        self.dev, self.allow_writes, self.log = dev, allow_writes, log
        self._page: Optional[int] = None

    # -- page register -----------------------------------------------------
    def read_page_register(self) -> bytes:
        return self.dev.read(PAGE_OFFSET, 4)

    def page(self) -> int:
        if self._page is None:
            raw = self.read_page_register()
            self._page = raw[1]
        return self._page

    def select_page(self, page: int) -> None:
        if self.page() == page:
            return
        if not self.allow_writes:
            raise PageWriteRequired(f"page 0x{page:02X} not selected (current "
                                    f"0x{self.page():02X}) and writes are not allowed")
        self._raw_write(PAGE_OFFSET, bytes([0x00, page, *PAGE_HI]))
        self._page = page

    def _raw_write(self, offset: int, data: bytes) -> None:
        if self.log:
            self.log(f"i2c w 0x{offset:02X}: " + " ".join(f"{b:02X}" for b in data))
        self.dev.write(offset, data)

    # -- registers ----------------------------------------------------------
    def read(self, addr: int, n: int) -> bytes:
        out = b""
        while n > 0:
            page, off = addr >> 8, addr & 0xFF
            chunk = min(n, 0xFC - off if off < 0xFC else 0x100 - off)
            self.select_page(page)
            out += self.dev.read(off, chunk)
            addr, n = addr + chunk, n - chunk
        return out

    def write(self, addr: int, data: bytes) -> None:
        if not self.allow_writes:
            raise PermissionError("ClockMatrix opened read-only")
        i = 0
        while i < len(data):
            page, off = (addr + i) >> 8, (addr + i) & 0xFF
            chunk = min(len(data) - i, 0xFC - off)
            if chunk <= 0:
                raise ValueError(f"write into page-register shadow 0x{addr + i:04X}")
            self.select_page(page)
            self._raw_write(off, data[i:i + chunk])
            i += chunk

    def u(self, addr: int, n: int) -> int:
        return int.from_bytes(self.read(addr, n), "little")


# --------------------------------------------------------------------------
# decoding
# --------------------------------------------------------------------------
def decode_general_status(b: bytes) -> Dict[str, object]:
    """b = 0x28 bytes from GENERAL_STATUS (0xC014)."""
    u = lambda o, n: int.from_bytes(b[o:o + n], "little")  # noqa: E731
    major, minor, hotfix = b[0x10] >> 1, b[0x11], b[0x12]
    return {
        "boot_status": f"0x{u(0, 4):02X}" + (" (ready)" if u(0, 4) == 0xA0 else ""),
        "otp_status": f"0x{u(4, 4):07X}", "eeprom_status": f"0x{u(8, 2):04X}",
        "hw_rev_id": b[0x0A], "bond_id": b[0x0B],
        "fw_version": f"{major}.{minor}.{hotfix}",
        "fw_ge_5_2": (major, minor) >= (5, 2),
        "jtag_device_id": f"0x{u(0x1C, 2):04X}",
        "product_id": f"0x{u(0x1E, 2):04X}",
        "otp_scsr_config_select": b[0x22],
        "otp_config_status": CONFIG_STATUS.get(b[0x23], b[0x23]),
        "otp_csr_config_status": CONFIG_STATUS.get(b[0x24], b[0x24]),
        "eeprom_config_status": CONFIG_STATUS.get(b[0x26], b[0x26]),
    }


def decode_status(b: bytes) -> Dict[str, object]:
    """b = 0x2B bytes from STATUS (0xC03C)."""
    ser = lambda v: {0: "undefined", 1: "I2C", 2: "SPI", 3: "disabled"}[v & 3] \
        + (" 2-byte" if v & 4 else " 1-byte")  # noqa: E731
    apll = b[0x21]
    return {
        "ser0": ser(b[0x02]), "ser0_i2c_addr": f"0x{b[0x04] & 0x7F:02X}",
        "ser1": ser(b[0x05]), "ser1_i2c_addr": f"0x{b[0x07] & 0x7F:02X}",
        "in_mon_status": [f"0x{v:02X}" for v in b[0x08:0x18]],
        "dpll_state": [DPLL_STATES.get(v & 0xF, v & 0xF) for v in b[0x18:0x20]],
        "sys_dpll_state": DPLL_STATES.get(b[0x20] & 0xF, b[0x20] & 0xF),
        "sys_apll_locked": not (apll & 1), "sys_apll_loss_lock_sticky": bool(apll & 0x10),
        "dpll_ref": [f"0x{v:02X}" for v in b[0x22:0x2B]],
    }


def q_frequency(fod_m: int, fod_n: int, out_div: int) -> Optional[float]:
    """Output frequency in Hz, or None if the FOD is off (M = 0)."""
    if fod_m == 0:
        return None
    f = Fraction(fod_m, fod_n or 1)
    return float(f / (out_div or 1))


def output_regs_from(get: Callable[[int, int], int], q: int, v520: bool) -> Dict[str, object]:
    """Decode Q`q` from any register source `get(addr, nbytes) -> int`."""
    stage = Q_STAGE[q]
    fod = stage
    if q == 8 and get(OUT_DIV_MUX, 1) & 1:
        fod = 5
    if q == 11 and get(OUT_DIV_MUX + 1, 1) & 1:
        fod = 6
    base = DPLL_CTRL[fod] + DPLL_FOD_FREQ
    m, n = get(base, 6), get(base + 6, 2)
    obase = OUTPUT[v520][q]
    div, ctrl0, ctrl1 = get(obase + OUT_DIV, 4), get(obase + OUT_CTRL_0, 1), get(obase + OUT_CTRL_1, 1)
    hz = q_frequency(m, n, div)
    return {"fod": fod, "fod_m": m, "fod_n": n, "fod_hz": q_frequency(m, n, 1),
            "out_div": div, "pad_mode": PAD_MODES.get(ctrl0 & 7, ctrl0 & 7),
            "out_ctrl_0": f"0x{ctrl0:02X}", "out_ctrl_1": f"0x{ctrl1:02X}",
            "freq_mhz": None if hz is None or (ctrl0 & 7) == 0 else hz / 1e6}


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
def _open(bus: Optional[int], addr: int) -> I2cDev:
    return I2cDev(find_bus() if bus is None else bus, addr)


def read_status(bus: Optional[int] = None, addr: int = I2C_ADDR,
                allow_page_select: bool = False, dev=None) -> Dict[str, object]:
    """Identity, boot/config status, PLL state and (optionally) Q7/Q11.

    The default does bus READS only: the page register, plus GENERAL_STATUS
    and STATUS if page 0xC0 is already selected. With
    `allow_page_select=True` it also writes the page register to reach the
    DPLL_CTRL/OUTPUT pages and decodes Q7 and Q11. It restores the original
    page afterwards. That write changes addressing state only, no clock
    configuration.
    """
    own = dev is None
    dev = dev or _open(bus, addr)
    res: Dict[str, object] = {"bus": getattr(dev, "bus", bus), "addr": f"0x{addr:02X}",
                              "outputs": RENESAS_OUTPUTS}
    try:
        cm = ClockMatrix(dev, allow_writes=allow_page_select)
        raw_page = cm.read_page_register()
        start_page = raw_page[1]
        res["page_register"] = " ".join(f"{b:02X}" for b in raw_page)
        try:
            gs = decode_general_status(cm.read(GENERAL_STATUS, 0x28))
            st = decode_status(cm.read(STATUS, 0x2B))
        except PageWriteRequired as e:
            res["error"] = str(e)
            res["note"] = "re-run with allow_page_select=True for status and outputs"
            return res
        res["general"], res["status"] = gs, st
        # the page register is per-port shared state: if another host moved it
        # between our reads, the bytes above came from the wrong page
        if not allow_page_select and cm.read_page_register()[1] != start_page:
            res["error"] = "page register changed during the read (another I2C user?)"
        res["configured"] = not (gs["otp_config_status"] == "not found"
                                 and gs["eeprom_config_status"] == "not found")
        if allow_page_select:
            v520 = bool(gs["fw_ge_5_2"])
            get = lambda a, n: cm.u(a, n)  # noqa: E731
            try:
                res["Q7"] = output_regs_from(get, 7, v520)
                res["Q11"] = output_regs_from(get, 11, v520)
            finally:
                cm.select_page(start_page)          # leave the port as found
            if not st["sys_apll_locked"]:
                for q in ("Q7", "Q11"):
                    res[q]["freq_mhz"] = None
                    res[q]["note"] = "system APLL unlocked: no valid output"
        else:
            res["Q7"] = res["Q11"] = ("not read (needs page select); "
                                      + ("chip unconfigured and APLL unlocked -> no clock"
                                         if not res["configured"] and not st["sys_apll_locked"]
                                         else "unknown"))
        return res
    finally:
        if own:
            dev.close()


# --------------------------------------------------------------------------
# register files
# --------------------------------------------------------------------------
_HEX = r"(?:0x)?([0-9A-Fa-f]+)h?"


def parse_register_file(path: str) -> List[Tuple[int, int]]:
    """Return the ordered (addr16, byte) writes described by `path`.

    Formats accepted:
      * Linux rsmu "idtcm.bin": 4-byte records (hiaddr, loaddr, value, 0).
      * Burst-style text, e.g. Timing Commander / BoardUI exports:
        "Size: 0x5, Offset: FC, Data: 0x00, 0xC0, 0x10, 0x20". Writes to offset
        0xFC are tracked as the page register; other bursts expand to
        consecutive bytes at (page << 8) | offset.
      * Two-column text "ADDR VALUE" (hex, 16-bit address, 8-bit value);
        '#', ';' and '//' start comments.
    """
    with open(path, "rb") as f:
        raw = f.read()
    if path.endswith(".bin"):
        if len(raw) % 4:
            raise ValueError(f"{path}: size {len(raw)} is not a multiple of 4")
        out = []
        for i in range(0, len(raw), 4):
            hi, lo, val, rsv = raw[i:i + 4]
            if rsv:
                raise ValueError(f"{path}: record {i // 4} reserved byte non-zero")
            out.append(((hi << 8) | lo, val))
        return out
    return parse_register_text(raw.decode("ascii", "replace"), path)


def parse_register_text(text: str, name: str = "<text>") -> List[Tuple[int, int]]:
    out: List[Tuple[int, int]] = []
    page: Optional[int] = None
    for ln, line in enumerate(text.splitlines(), 1):
        s = re.split(r"#|;|//", line, 1)[0].strip()
        if not s:
            continue
        m = re.search(r"Offset\s*[:=]\s*" + _HEX + r".*?Data\s*[:=]\s*(.*)$", s, re.I)
        if m:
            off = int(m.group(1), 16)
            data = _data_bytes(m.group(2), name, ln)
            sz = re.search(r"Size\s*[:=]\s*" + _HEX, s, re.I)
            if sz and int(sz.group(1), 16) != len(data):
                raise ValueError(f"{name}:{ln}: Size 0x{int(sz.group(1), 16):X} but "
                                 f"{len(data)} data bytes")
            if off > 0xFFFF:
                raise ValueError(f"{name}:{ln}: offset 0x{off:X} out of range")
            if off >= 0xFFFC:           # 2-byte-mode page register (FFFD): addressing only
                continue
            if off > 0xFF:              # 2-byte offset export: full address
                out += [(off + i, v) for i, v in enumerate(data)]
                continue
            if off == PAGE_OFFSET:
                if len(data) < 2:
                    raise ValueError(f"{name}:{ln}: short page-register write")
                page = data[1]
                continue
            if page is None:
                raise ValueError(f"{name}:{ln}: data before any page-register write")
            out += [((page << 8) | (off + i), v) for i, v in enumerate(data)]
            continue
        toks = re.findall(_HEX, s)
        if len(toks) == 2:
            a, v = int(toks[0], 16), int(toks[1], 16)
            if a > 0xFFFF or v > 0xFF:
                raise ValueError(f"{name}:{ln}: bad pair {s!r}")
            out.append((a, v))
            continue
        # header / free text lines are ignored
    if not out:
        raise ValueError(f"{name}: no register writes found")
    return out


def _data_bytes(field: str, name: str, ln: int) -> List[int]:
    """Timing Commander writes the burst as one hex string in wire order
    ("0x00C01020" = 00 C0 10 20). Comma/space-separated bytes are also accepted."""
    toks = [t for t in re.split(r"[\s,]+", field.strip()) if t]
    if len(toks) == 1:
        h = toks[0][2:] if toks[0].lower().startswith("0x") else toks[0]
        if len(h) % 2 or not re.fullmatch(r"[0-9A-Fa-f]+", h):
            raise ValueError(f"{name}:{ln}: bad data field {field!r}")
        return list(bytes.fromhex(h))
    out = []
    for t in toks:
        v = int(t, 16)
        if v > 0xFF:
            raise ValueError(f"{name}:{ln}: {t} is not a byte")
        out.append(v)
    return out


def register_image(writes: Iterable[Tuple[int, int]]) -> Dict[int, int]:
    img: Dict[int, int] = {}
    for a, v in writes:
        img[a] = v
    return img


def predicted_outputs(writes: Iterable[Tuple[int, int]], v520: bool = False,
                      qs: Sequence[int] = (7, 11)) -> Dict[str, Dict[str, object]]:
    """Q frequencies a register file produces on a chip that starts at defaults (0)."""
    img = register_image(writes)
    get = lambda a, n: int.from_bytes(bytes(img.get(a + i, 0) for i in range(n)), "little")  # noqa: E731
    return {f"Q{q}": output_regs_from(get, q, v520) for q in qs}


def is_full_configuration(writes: Iterable[Tuple[int, int]], v520: bool = False) -> bool:
    """Same test as Linux ptp_clockmatrix contains_full_configuration()."""
    scratch = SCRATCH[v520]
    full = (scratch - GPIO_USER_CONTROL) - ((scratch >> 7) - (GPIO_USER_CONTROL >> 7)) * 4
    cnt = sum(1 for a, _ in set(writes) if _writable(a, v520))
    return cnt >= full


def _writable(addr: int, v520: bool) -> bool:
    lo = addr & 0xFF
    if addr < GPIO_USER_CONTROL or addr >= SCRATCH[v520]:
        return False
    return not (0x7C <= lo <= 0x7F or lo >= 0xFC)


def plan_writes(writes: Sequence[Tuple[int, int]], v520: bool = False) -> List[Write]:
    """Filter like the Linux loader and coalesce consecutive addresses into
    bursts that never cross a 0x7C/0xFC page-register shadow, keeping file order."""
    bursts: List[Write] = []
    cur_a, cur = None, bytearray()
    for a, v in writes:
        if not _writable(a, v520):
            continue
        if cur_a is not None and a == cur_a + len(cur) and (a & 0xFF) not in (0x80, 0x00):
            cur.append(v)
            continue
        if cur_a is not None:
            bursts.append((cur_a, bytes(cur)))
        cur_a, cur = a, bytearray([v])
    if cur_a is not None:
        bursts.append((cur_a, bytes(cur)))
    return bursts


# --------------------------------------------------------------------------
# programming
# --------------------------------------------------------------------------
class _DryDev:
    """Pretends to be the chip for dry runs: page reads return page 0x00."""
    bus = None

    def read(self, offset: int, n: int) -> bytes:
        return bytes([0x00, 0x00, *PAGE_HI])[:n] if offset == PAGE_OFFSET else bytes(n)

    def write(self, offset: int, data: bytes) -> None:
        pass

    def close(self) -> None:
        pass


def program_gt_refclk(freq_mhz: float = 156.25, dry_run: bool = False,
                      regfile: Optional[str] = None, bus: Optional[int] = None,
                      addr: int = I2C_ADDR, sm_reset: Optional[bool] = None,
                      lock_timeout_s: float = 3.0,
                      printer: Callable[[str], None] = print, dev=None) -> None:
    """Program 8A34001 Q7 and Q11 to `freq_mhz` from a register file.

    It checks the file before touching the bus: the file must drive Q7 and
    Q11 at `freq_mhz` from a chip at defaults, which is the state a ZCU216
    boots in. `dry_run=True` prints every I2C transaction and returns without
    opening the bus. Otherwise it programs, waits for the system APLL to lock,
    and reads Q7/Q11 back. If the result is wrong it raises RuntimeError.
    """
    if freq_mhz not in CMAC_REFCLK_CHOICES_MHZ:
        raise ValueError(f"{freq_mhz} MHz is not a CAUI-4 GT refclk ({CMAC_REFCLK_CHOICES_MHZ})")
    regfile = regfile or DEFAULT_REGFILE.get(freq_mhz)
    if not regfile or not os.path.exists(regfile):
        raise FileNotFoundError(f"no 8A34001 register file for {freq_mhz} MHz ({regfile})")

    writes = parse_register_file(regfile)
    v520 = False                     # the ZCU216's U409 runs firmware 4.8.0; re-checked below
    pred = predicted_outputs(writes, v520)
    bad = {q: p["freq_mhz"] for q, p in pred.items()
           if p["freq_mhz"] is None or abs(p["freq_mhz"] - freq_mhz) > 1e-6}
    if bad:
        raise ValueError(f"{os.path.basename(regfile)} does not give {freq_mhz} MHz "
                         f"on Q7/Q11: {bad}")
    full = is_full_configuration(writes, v520) if sm_reset is None else sm_reset
    bursts = plan_writes(writes, v520)

    printer(f"# 8A34001 @0x{addr:02X}: {os.path.basename(regfile)} -> "
            f"{len(writes)} bytes, {len(bursts)} bursts, full_config={full}")
    for q, p in pred.items():
        printer(f"#   {q}: FOD{p['fod']} {p['fod_hz'] / 1e6:.6f} MHz / {p['out_div']} "
                f"= {p['freq_mhz']:.6f} MHz, {p['pad_mode']}")

    if dry_run:
        cm = ClockMatrix(_DryDev(), allow_writes=True, log=printer)
        if full:
            cm.write(RESET_CTRL + SM_RESET[v520], bytes([SM_RESET_CMD]))
            printer("#   (wait for GENERAL_STATUS.BOOT_STATUS == 0xA0)")
        for a, data in bursts:
            cm.write(a, data)
        printer("# dry run: nothing sent")
        return

    own = dev is None
    dev = dev or _open(bus, addr)
    try:
        cm = ClockMatrix(dev, allow_writes=True)
        gs = decode_general_status(cm.read(GENERAL_STATUS, 0x28))
        if gs["product_id"] != "0x4001":
            raise RuntimeError(f"not an 8A34001: PRODUCT_ID {gs['product_id']}")
        if bool(gs["fw_ge_5_2"]) != v520:
            raise RuntimeError(f"firmware {gs['fw_version']}: register map differs; "
                               f"re-derive the file for this firmware")
        if full:
            cm.write(GENERAL_STATUS, bytes(4))              # clear BOOT_STATUS
            cm.write(RESET_CTRL + SM_RESET[v520], bytes([SM_RESET_CMD]))
            cm._page = None                                  # reset may clear the page
            _wait(lambda: cm.u(GENERAL_STATUS, 4) == 0xA0, lock_timeout_s,
                  "BOOT_STATUS != 0xA0 after SM_RESET")
        for a, data in bursts:
            cm.write(a, data)
        _wait(lambda: not (cm.read(STATUS + 0x21, 1)[0] & 1), lock_timeout_s,
              "system APLL did not lock")
        got = {q: output_regs_from(lambda a, n: cm.u(a, n), int(q[1:]), v520)
               for q in ("Q7", "Q11")}
        for q, p in got.items():
            printer(f"{q}: {p['freq_mhz']} MHz ({p['pad_mode']})")
            if p["freq_mhz"] is None or abs(p["freq_mhz"] - freq_mhz) > 1e-6:
                raise RuntimeError(f"{q} reads back {p['freq_mhz']} MHz, wanted {freq_mhz}")
    finally:
        if own:
            dev.close()


def _wait(cond: Callable[[], bool], timeout_s: float, msg: str) -> None:
    t0 = time.monotonic()
    while not cond():
        if time.monotonic() - t0 > timeout_s:
            raise RuntimeError(msg)
        time.sleep(0.05)


if __name__ == "__main__":
    import argparse
    import json

    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--status", action="store_true", help="read-only status (default)")
    ap.add_argument("--page-select", action="store_true",
                    help="allow page-register writes to read Q7/Q11 (no clock effect)")
    ap.add_argument("--program", type=float, metavar="MHZ")
    ap.add_argument("--regfile")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.program:
        program_gt_refclk(a.program, dry_run=a.dry_run, regfile=a.regfile)
    else:
        print(json.dumps(read_status(allow_page_select=a.page_select), indent=2, default=str))
