"""FPGA register map of the `eth100g` hierarchy of the zcu216_v49_<N>ch_qsfp builds.

EVERY FPGA ADDRESS THE DAEMON USES FOR THE 100G PATH LIVES IN THIS FILE.

Sources of truth:
  fpga/boards/<board>/block_designs/<board>_uhd_v49*/   IP names and addresses (AXI-Lite on pl_clk0)
  fpga/ip/src/uhd_ip/src/udp_streamer.v    streamer map (header table)
  fpga/ip/src/uhd_ip/src/udp_player.v      player map (header table)
  fpga/ip/src/uhd_ip/src/tx_beamformer.v   TX beamformer map (header)
  fpga/ip/src/uhd_ip/src/rx_beamformer.v   RX beamformer map (header)
  fpga/ip/src/cmac_100g/cmac_100g.v        CMAC ctl/status bit layout (header)

  0x8002_0000  eth100g/udp_streamer  ADC -> UDP/VRT
  0x8003_0000  eth100g/udp_player    UDP/VRT -> DAC, ARP, async status, flow control
  0x8004_0000  eth100g/cmac_gpio     AXI GPIO dual: ch1 = CMAC ctl (out, default
                                     0x0000F003), ch2 = CMAC status (in)
  0x8005_0000  eth100g/cmac_freq     AXI GPIO dual, inputs: ch1 = GT refclk kHz,
                                     ch2 = CMAC user clock kHz (156250 / 322266)
  0x8006_0000  eth100g/tx_beamformer N >= 2 builds only: tx_beamformer.py
  0x8007_0000  eth100g/rx_beamformer N >= 2 builds that have it: rx_beamformer.py

udp_streamer's m_axis_adc copy is unused and udp_player's s_axis_dma input
is tied idle in every build, so the DAC source is ALWAYS the player (CTRL
dac_src = 1): set at bring-up (`player_enable`) and kept by every later
write; an idle or flushed player outputs zeros.

There is NO cmac_usplus AXI4-Lite in this build: the CMAC is the example-design
core in the RTL top, and an RTL controller does RX + RS-FEC on, send RFI until
aligned, TX enable. Software controls it only through cmac_gpio.

IPs are resolved by ip_dict name (key suffix), with the addresses above as a
fallback when the hwh does not list them (module references can be missing).
"""
from __future__ import annotations

import logging
import time
from collections import OrderedDict
from typing import Callable, Dict, Optional, Tuple

log = logging.getLogger("uhd_rfsoc.eth100g")

# --------------------------------------------------------------------------
# IP names (ip_dict key suffixes) and fallback addresses
# --------------------------------------------------------------------------
IP_RANGE = 0x10000
STREAMER = ("udp_streamer", 0x80020000)
PLAYER = ("udp_player", 0x80030000)
CMAC_GPIO = ("cmac_gpio", 0x80040000)
CMAC_FREQ = ("cmac_freq", 0x80050000)

# --------------------------------------------------------------------------
# eth100g/udp_streamer (uhd_ip/src/udp_streamer.v)
# --------------------------------------------------------------------------
STR_ID = 0x00                 # RO 'ZS01'
STR_ID_VALUE = 0x5A533031
STR_CTRL = 0x04               # [0] enable [1] test pattern [2] clear stats (self-clearing)
STR_CTRL_ENABLE = 1 << 0      # 0 => every command is ignored
STR_CTRL_PATTERN = 1 << 1
STR_CTRL_CLEAR_STATS = 1 << 2
STR_STREAM_CMD = 0x08         # W: [1:0] mode, [8] now. Snapshots NUM_SAMPS/CMD_TIME.
STR_CMD_STOP = 0
STR_CMD_CONTINUOUS = 1
STR_CMD_NUM_DONE = 2
STR_CMD_NUM_MORE = 3          # like num_done, no EOB on the last packet
STR_CMD_NOW = 1 << 8
STR_NUM_SAMPS_LO = 0x0C       # RTL rounds up to 16
STR_NUM_SAMPS_HI = 0x10
STR_CMD_TIME_LO = 0x14
STR_CMD_TIME_HI = 0x18
STR_TIME_NOW_LO = 0x1C        # RO, reading LO freezes HI
STR_TIME_NOW_HI = 0x20
STR_TIME_SET_LO = 0x24
STR_TIME_SET_HI = 0x28
STR_TIME_CTRL = 0x2C          # [0] load TIME_SET now (strobe)
STR_TIME_CTRL_SET_NOW = 1 << 0
STR_SRC_MAC_LO = 0x30
STR_SRC_MAC_HI = 0x34
STR_DST_MAC_LO = 0x38
STR_DST_MAC_HI = 0x3C
STR_SRC_IP = 0x40
STR_DST_IP = 0x44
STR_SRC_PORT = 0x48
STR_DST_PORT_BASE = 0x4C
STR_NPORTS = 0x50
STR_SPP = 0x54                # coerced to a multiple of 16 in 16..2048
STR_SID = 0x58
STR_PKTS_LO = 0x60
STR_PKTS_HI = 0x64
STR_OVERFLOWS = 0x68
STR_STATUS = 0x6C             # [0] streaming [1] cmac rx aligned [2] cmac tx ready
STR_STATUS_STREAMING = 1 << 0  #     [3] command rejected since last clear (sticky)
STR_STATUS_RX_ALIGNED = 1 << 1
STR_STATUS_TX_READY = 1 << 2
STR_STATUS_CMD_REJECTED = 1 << 3
STR_FIFO_HWM = 0x70
STR_CMDS = 0x74               # RO, commands accepted (gray-coded CDC from adc_clk)
STR_FMT = 0x78                # RW, Protocol §10 OTW format (FMT_CODES); written idle

STREAM_MODE_CODES = {
    "stop_cont": STR_CMD_STOP,
    "start_cont": STR_CMD_CONTINUOUS,
    "num_done": STR_CMD_NUM_DONE,
    "num_more": STR_CMD_NUM_MORE,
}

# --------------------------------------------------------------------------
# eth100g/udp_player (uhd_ip/src/udp_player.v)
# --------------------------------------------------------------------------
PLY_ID = 0x00                 # RO 'ZP01'
PLY_ID_VALUE = 0x5A503031
PLY_CTRL = 0x04               # [0] enable [1] dac_src [2] clear stats [3] flush (strobe)
PLY_CTRL_ENABLE = 1 << 0
PLY_CTRL_DAC_SRC = 1 << 1     # 1 = player (always); 0 = s_axis_dma, tied idle on v49
PLY_CTRL_CLEAR_STATS = 1 << 2
PLY_CTRL_FLUSH = 1 << 3
PLY_MY_MAC_LO = 0x08
PLY_MY_MAC_HI = 0x0C
PLY_MY_IP = 0x10
PLY_TX_PORT = 0x14            # 49900
PLY_HOST_MAC_LO = 0x18
PLY_HOST_MAC_HI = 0x1C
PLY_HOST_IP = 0x20
PLY_ASYNC_PORT = 0x24         # 49826
PLY_SRC_PORT = 0x28           # 49801
PLY_FC_INTERVAL = 0x2C        # words (daemon default backend.DEFAULT_FC_INTERVAL = 512)
PLY_TX_BUF_WORDS = 0x30       # RO host credit (32752 = 2 MiB - 16 words on the v49 builds)
PLY_SID = 0x34
PLY_STATS = OrderedDict([     # RO counters
    ("rx_frames", 0x40),
    ("rx_bad_fcs", 0x44),
    ("arp_replies", 0x48),
    ("udp_accepted", 0x4C),
    ("udp_dropped_overflow", 0x50),
    ("seq_errors", 0x54),
    ("underflows", 0x58),
    ("late", 0x5C),
    ("bursts_acked", 0x60),
    ("consumed_words", 0x64),  # free-running; only a reset clears it
    ("udp_malformed", 0x6C),
    ("status_pkts", 0x70),
    ("untimed_starts_gated", 0x80),    # 0 on a bitstream without the gate
    ("untimed_gate_timeouts", 0x84),
])
PLY_CONSUMED = 0x64
PLY_STATUS = 0x68             # [0] playing [1] buffer_empty
PLY_STATUS_PLAYING = 1 << 0
PLY_STATUS_BUF_EMPTY = 1 << 1
PLY_FMT = 0x74                # RW, Protocol §10 OTW format (FMT_CODES); written idle
# §10 format codes of STR_FMT / PLY_FMT. A bitstream built before §10 has no
# FMT register: the write is ignored and it reads back 0 (sc16).
FMT_CODES = OrderedDict([("sc16", 0), ("sc8", 1), ("sc12", 2), ("fc32", 3)])
# Untimed-start gate (udp_player 0x78 / 0x7C): an untimed burst plays from its
# first word, and at full rate the host refills barely faster than the DAC
# drains, so the player holds it until USTART words are buffered, its EOB
# packet has arrived, or UTIMEOUT tx_clk cycles passed. 4096 words = 256 KiB:
# 21 us of a 96 Gb/s stream; the timeout (100 us at the CMAC's 322.27 MHz)
# bounds what a short burst without EOB waits. Ignored by a bitstream built
# before the gate (the writes go nowhere).
PLY_USTART = 0x78
PLY_UTIMEOUT = 0x7C
USTART_WORDS = 4096
UTIMEOUT_CYCLES = 32227
TX_PORT = 49900
TX_SRC_PORT = 49801

# --------------------------------------------------------------------------
# eth100g/cmac_gpio (cmac_100g/cmac_100g.v header)
# --------------------------------------------------------------------------
GPIO_DATA = 0x00              # ch1: CMAC ctl (all outputs)
GPIO2_DATA = 0x08             # ch2: CMAC status (all inputs)
CTL_SYS_RESET = 1 << 0        # GT sys_reset: hold high until the refclk is valid
CTL_RSFEC = 1 << 1            # RS-FEC both directions (must match the NIC)
CTL_RXPOL_SHIFT = 4           # [7:4] rx polarity per lane (SFP0..3)
CTL_TXPOL_SHIFT = 8           # [11:8] tx polarity per lane
CTL_LPM_SHIFT = 12            # [15:12] 1 = LPM, 0 = DFE per lane
CTL_LOOPBACK = 1 << 16        # near-end PMA loopback, all lanes
CTL_DEFAULT = 0x0000F003      # C_DOUT_DEFAULT: reset held, RS-FEC on, LPM

ST_RX_ALIGNED = 1 << 0
ST_RX_STATUS = 1 << 1
ST_RSFEC_LANE_ALIGN = 1 << 2
ST_TX_ENABLED = 1 << 27
CMAC_STATUS_FIELDS = [        # (name, lsb, width)
    ("rx_aligned", 0, 1),
    ("rx_status", 1, 1),
    ("rsfec_lane_align", 2, 1),
    ("rsfec_am_lock", 3, 4),      # per lane 0..3
    ("gt_powergood", 7, 4),
    ("rx_reset_done", 11, 4),
    ("tx_reset_done", 15, 4),
    ("usr_tx_reset", 19, 1),
    ("usr_rx_reset", 20, 1),
    ("rx_local_fault", 21, 1),
    ("rx_remote_fault", 22, 1),
    ("rx_hi_ber", 23, 1),
    ("tx_overflow_seen", 24, 1),
    ("tx_underflow_seen", 25, 1),
    ("rx_misaligned", 26, 1),
    ("tx_enabled", 27, 1),
]

# --------------------------------------------------------------------------
# eth100g/cmac_freq
# --------------------------------------------------------------------------
FREQ_REFCLK = 0x00            # ch1: measured GT refclk, kHz
FREQ_USRCLK = 0x08            # ch2: measured CMAC user clock, kHz
REFCLK_KHZ = 156250
REFCLK_TOL_KHZ = 50
USRCLK_KHZ = 322266
USRCLK_TOL_KHZ = 100


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def mac_to_int(mac: str) -> int:
    parts = mac.split(":")
    if len(parts) != 6:
        raise ValueError(f"bad MAC {mac!r}")
    v = 0
    for p in parts:
        b = int(p, 16)
        if not 0 <= b <= 0xFF:
            raise ValueError(f"bad MAC {mac!r}")
        v = (v << 8) | b
    return v


def ip_to_int(ip: str) -> int:
    parts = [int(p) for p in ip.split(".")]
    if len(parts) != 4 or any(not 0 <= p <= 255 for p in parts):
        raise ValueError(f"bad IPv4 {ip!r}")
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]


def build_ctl(rsfec: bool = True, rxpol: int = 0, txpol: int = 0,
              lpm_mask: int = 0xF, loopback: bool = False,
              sys_reset: bool = False) -> int:
    return ((CTL_SYS_RESET if sys_reset else 0) | (CTL_RSFEC if rsfec else 0)
            | ((rxpol & 0xF) << CTL_RXPOL_SHIFT) | ((txpol & 0xF) << CTL_TXPOL_SHIFT)
            | ((lpm_mask & 0xF) << CTL_LPM_SHIFT) | (CTL_LOOPBACK if loopback else 0))


def decode_ctl(ctl: int) -> "OrderedDict[str, object]":
    return OrderedDict([
        ("sys_reset", ctl & 1), ("rsfec", (ctl >> 1) & 1),
        ("rxpol", "0x%x" % ((ctl >> CTL_RXPOL_SHIFT) & 0xF)),
        ("txpol", "0x%x" % ((ctl >> CTL_TXPOL_SHIFT) & 0xF)),
        ("lpm", "0x%x" % ((ctl >> CTL_LPM_SHIFT) & 0xF)),
        ("loopback", (ctl >> 16) & 1)])


def decode_cmac_status(st: int) -> "OrderedDict[str, object]":
    out = OrderedDict()
    for name, lsb, width in CMAC_STATUS_FIELDS:
        v = (st >> lsb) & ((1 << width) - 1)
        out[name] = format(v, "04b")[::-1] if width == 4 else v   # lane0 first
    return out


def format_cmac_status(st: int) -> str:
    d = decode_cmac_status(st)
    lanes = " ".join(f"{k}[0..3]={d[k]}" for k in
                     ("rsfec_am_lock", "gt_powergood", "rx_reset_done", "tx_reset_done"))
    flags = " ".join(f"{k}={v}" for k, v in d.items() if not isinstance(v, str))
    return f"0x{st:08x} {flags} {lanes}"


def _resolve(ip_dict: dict, name: str, fallback: int) -> Tuple[str, int, int]:
    keys = [k for k in ip_dict if k == name or k.endswith("/" + name)]
    if len(keys) == 1:
        d = ip_dict[keys[0]]
        return keys[0], int(d["phys_addr"]), int(d.get("addr_range", IP_RANGE))
    if len(keys) > 1:
        raise KeyError(f"several IPs named {name}: {keys}")
    log.warning("%s not in ip_dict; using fallback address 0x%08x", name, fallback)
    return "eth100g/" + name + " (fallback)", fallback, IP_RANGE


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------

class Eth100G:
    """udp_streamer + udp_player + CMAC ctl/status + clock meters.

    The constructor only READS (ID checks), so it is safe for a status dump.
    """

    def __init__(self, ip_dict: Optional[dict] = None, mmio_factory=None,
                 check_ids: bool = True):
        if mmio_factory is None:
            from pynq import MMIO as mmio_factory  # noqa: N813
        if ip_dict is not None and hasattr(ip_dict, "ip_dict"):
            ip_dict = ip_dict.ip_dict          # an Overlay was passed
        ip_dict = ip_dict or {}
        self.names = {}
        m = {}
        for key, (name, addr) in (("s", STREAMER), ("p", PLAYER),
                                  ("g", CMAC_GPIO), ("f", CMAC_FREQ)):
            full, base, rng = _resolve(ip_dict, name, addr)
            self.names[name] = (full, base)
            m[key] = mmio_factory(base, rng)
        self.s, self.p, self.g, self.f = m["s"], m["p"], m["g"], m["f"]
        if check_ids:
            for mm, reg, want, name in ((self.s, STR_ID, STR_ID_VALUE, "udp_streamer"),
                                        (self.p, PLY_ID, PLY_ID_VALUE, "udp_player")):
                got = mm.read(reg)
                if got != want:
                    raise RuntimeError(f"{name}: ID 0x{got:08x}, expected 0x{want:08x} "
                                       f"-- is a zcu216_v49_<N>ch_qsfp build loaded?")
        log.info("eth100g: %s", ", ".join(f"{n} {f}@0x{b:08x}"
                                          for n, (f, b) in self.names.items()))
        self._ctrl = 0

    # -- small helpers --------------------------------------------------------
    def _w64(self, lo_off: int, hi_off: int, value: int) -> None:
        value = int(value) & 0xFFFFFFFFFFFFFFFF
        self.s.write(lo_off, value & 0xFFFFFFFF)
        self.s.write(hi_off, value >> 32)

    # -- streamer ---------------------------------------------------------------
    def set_addresses(self, my_mac: str, my_ip: str) -> None:
        """FPGA-side MAC/IP in both streamer and player (player answers ARP)."""
        mm = mac_to_int(my_mac)
        self.s.write(STR_SRC_MAC_LO, mm & 0xFFFFFFFF)
        self.s.write(STR_SRC_MAC_HI, mm >> 32)
        self.s.write(STR_SRC_IP, ip_to_int(my_ip))
        self.p.write(PLY_MY_MAC_LO, mm & 0xFFFFFFFF)
        self.p.write(PLY_MY_MAC_HI, mm >> 32)
        self.p.write(PLY_MY_IP, ip_to_int(my_ip))

    def player_enable(self) -> None:
        """Player enabled (ARP, TX credit) and selected as the DAC source; the
        DAC plays zeros until a burst arrives."""
        self.p.write(PLY_TX_PORT, TX_PORT)
        self.p.write(PLY_SRC_PORT, TX_SRC_PORT)
        self.p.write(PLY_CTRL, PLY_CTRL_ENABLE | PLY_CTRL_DAC_SRC)

    def probe_formats(self) -> list:
        """§10 formats both the streamer and the player implement: write each
        FMT code and read it back (an unmapped register reads 0), then 0
        (sc16). Only while idle (bring-up)."""
        have = []
        for name, code in FMT_CODES.items():
            self.s.write(STR_FMT, code)
            self.p.write(PLY_FMT, code)
            if self.s.read(STR_FMT) == code and self.p.read(PLY_FMT) == code:
                have.append(name)
        self.s.write(STR_FMT, 0)
        self.p.write(PLY_FMT, 0)
        return have

    def configure(self, src_mac: str, src_ip: str, dst_mac: str, dst_ip: str,
                  src_port: int, dst_port_base: int, nports: int, spp: int,
                  sid: int, pattern: bool, fmt: str = "sc16") -> int:
        """Header template; returns the SPP the RTL accepted. `fmt` (§10) is
        written before SPP, which the RTL coerces to the format's granule."""
        self.s.write(STR_CTRL, 0)            # disabled while the template changes
        smac, dmac = mac_to_int(src_mac), mac_to_int(dst_mac)
        self._zero_port_counter(smac, dmac, src_ip, dst_ip, src_port, sid)
        self.s.write(STR_SRC_MAC_LO, smac & 0xFFFFFFFF)
        self.s.write(STR_SRC_MAC_HI, smac >> 32)
        self.s.write(STR_DST_MAC_LO, dmac & 0xFFFFFFFF)
        self.s.write(STR_DST_MAC_HI, dmac >> 32)
        self.s.write(STR_SRC_IP, ip_to_int(src_ip))
        self.s.write(STR_DST_IP, ip_to_int(dst_ip))
        self.s.write(STR_SRC_PORT, int(src_port) & 0xFFFF)
        self.s.write(STR_DST_PORT_BASE, int(dst_port_base) & 0xFFFF)
        self.s.write(STR_NPORTS, int(nports))
        code = FMT_CODES[fmt]
        self.s.write(STR_FMT, code)
        if self.s.read(STR_FMT) != code:
            raise RuntimeError(f"udp_streamer FMT reads back {self.s.read(STR_FMT)} after "
                               f"writing {code} ({fmt}): this bitstream has no §10 converter")
        self.s.write(STR_SPP, int(spp))
        self.s.write(STR_SID, int(sid) & 0xFFFFFFFF)
        self._ctrl = STR_CTRL_ENABLE | (STR_CTRL_PATTERN if pattern else 0)
        self.s.write(STR_CTRL, self._ctrl | STR_CTRL_CLEAR_STATS)
        self.s.write(STR_CTRL, self._ctrl)
        return self.s.read(STR_SPP)

    def _zero_port_counter(self, smac: int, dmac: int, src_ip: str, dst_ip: str,
                           src_port: int, sid: int) -> None:
        """Bring udp_streamer's destination-port counter back to 0.

        The streamer sends packet i to dst_port_base + (k mod NPORTS) and
        never resets k when the template changes, so a session's first packet
        went to the previous session's next port: after a 4-port session, a
        2-port client's first packet arrived on base + 2 or base + 3 (no flow
        rule: lost to the kernel; with a rule: behind its successor on the
        same queue). k wraps to 0 after any packet sent with NPORTS = 1: send
        one 16-slot packet to the discard port (UDP 9) first.
        """
        self.s.write(STR_SRC_MAC_LO, smac & 0xFFFFFFFF)
        self.s.write(STR_SRC_MAC_HI, smac >> 32)
        self.s.write(STR_DST_MAC_LO, dmac & 0xFFFFFFFF)
        self.s.write(STR_DST_MAC_HI, dmac >> 32)
        self.s.write(STR_SRC_IP, ip_to_int(src_ip))
        self.s.write(STR_DST_IP, ip_to_int(dst_ip))
        self.s.write(STR_SRC_PORT, int(src_port) & 0xFFFF)
        self.s.write(STR_DST_PORT_BASE, 9)
        self.s.write(STR_NPORTS, 1)
        self.s.write(STR_FMT, FMT_CODES["sc16"])
        self.s.write(STR_SPP, 16)
        self.s.write(STR_SID, int(sid) & 0xFFFFFFFF)
        self.s.write(STR_CTRL, STR_CTRL_ENABLE)
        before = self.s.read(STR_PKTS_LO)
        try:
            self.stream_cmd("num_done", 16, True, 0)
        except RuntimeError as e:
            log.warning("udp_streamer port-counter reset: %s", e)
        deadline = time.monotonic() + 0.05
        while self.s.read(STR_PKTS_LO) == before and time.monotonic() < deadline:
            time.sleep(0.0005)
        if self.s.read(STR_PKTS_LO) == before:
            log.warning("udp_streamer port-counter reset: no packet went out in 50 ms")
        self.s.write(STR_CTRL, 0)

    def stream_cmd(self, mode: str, num_samps: int, now: bool, time_ticks: int,
                   timeout_s: float = 0.02) -> None:
        """Issue one command; RuntimeError if the RTL does not accept it.

        Acceptance = CMDS advances (it crosses from adc_clk, so poll briefly).
        A start while the streamer is not idle is rejected by the RTL: the
        caller stops first (HwBackend does).
        """
        code = STREAM_MODE_CODES[mode]
        before = self.s.read(STR_CMDS)
        # operands FIRST: the STREAM_CMD write snapshots them
        self._w64(STR_NUM_SAMPS_LO, STR_NUM_SAMPS_HI, num_samps)
        self._w64(STR_CMD_TIME_LO, STR_CMD_TIME_HI, time_ticks)
        self.s.write(STR_STREAM_CMD, code | (STR_CMD_NOW if now else 0))
        deadline = time.monotonic() + timeout_s
        while True:
            after = self.s.read(STR_CMDS)
            if after != before:
                return
            if time.monotonic() > deadline:
                break
            time.sleep(0.0005)
        st = self.status()
        raise RuntimeError(
            f"streamer did not accept {mode} (STATUS=0x{st:08x}"
            f"{' rejected' if st & STR_STATUS_CMD_REJECTED else ''}"
            f"{' streaming' if st & STR_STATUS_STREAMING else ''}, CMDS {before}, "
            f"CTRL=0x{self.s.read(STR_CTRL):08x})")

    def wait_idle(self, timeout_s: float = 0.1) -> bool:
        deadline = time.monotonic() + timeout_s
        while self.streaming():
            if time.monotonic() > deadline:
                return False
            time.sleep(0.001)
        return True

    def set_time(self, ticks: int) -> None:
        self._w64(STR_TIME_SET_LO, STR_TIME_SET_HI, ticks)
        self.s.write(STR_TIME_CTRL, STR_TIME_CTRL_SET_NOW)

    def get_time(self) -> int:
        lo = self.s.read(STR_TIME_NOW_LO)   # freezes HI
        hi = self.s.read(STR_TIME_NOW_HI)
        return (hi << 32) | lo

    def status(self) -> int:
        return self.s.read(STR_STATUS)

    def pkts(self) -> int:
        """Packets the streamer has emitted (64-bit, monotonic)."""
        while True:
            hi = self.s.read(STR_PKTS_HI)
            lo = self.s.read(STR_PKTS_LO)
            if self.s.read(STR_PKTS_HI) == hi:
                return (hi << 32) | lo

    def streaming(self) -> bool:
        return bool(self.status() & STR_STATUS_STREAMING)

    def streamer_stats(self) -> Dict[str, object]:
        st = self.status()
        return OrderedDict([
            ("pkts", self.s.read(STR_PKTS_LO) | (self.s.read(STR_PKTS_HI) << 32)),
            ("overflows", self.s.read(STR_OVERFLOWS)),
            ("fifo_hwm", self.s.read(STR_FIFO_HWM)),
            ("cmds", self.s.read(STR_CMDS)),
            ("streaming", int(bool(st & STR_STATUS_STREAMING))),
            ("cmac_rx_aligned", int(bool(st & STR_STATUS_RX_ALIGNED))),
            ("cmac_tx_ready", int(bool(st & STR_STATUS_TX_READY))),
            ("cmd_rejected", int(bool(st & STR_STATUS_CMD_REJECTED))),
            ("ctrl", "0x%08x" % self.s.read(STR_CTRL)),
            ("spp", self.s.read(STR_SPP)),
            ("fmt", self.s.read(STR_FMT)),
            ("time", self.get_time()),
        ])

    def stats(self) -> Dict[str, object]:
        """Everything for the `stats` command (streamer + player + CMAC)."""
        s = self.streamer_stats()
        # no MAC statistics block in this build: the streamer's packet count is
        # what the CMAC was handed
        s["cmac_tx_pkts"] = s["pkts"]
        st = self.cmac_status()
        s["cmac_status"] = "0x%08x" % st
        s["cmac_aligned"] = int(bool(st & ST_RX_ALIGNED))
        s["refclk_khz"] = self.refclk_khz()
        s["usrclk_khz"] = self.usrclk_khz()
        for k, v in self.player_stats().items():
            s["tx_" + k] = v
        return s

    # -- player (host -> DAC) --------------------------------------------------
    def tx_buf_words(self) -> int:
        return self.p.read(PLY_TX_BUF_WORDS)

    def consumed_words(self) -> int:
        return self.p.read(PLY_CONSUMED)

    def player_setup(self, my_mac: str, my_ip: str, host_mac: str,
                     host_ip: str, async_port: int, fc_interval: int,
                     sid: int, tx_port: int = TX_PORT,
                     src_port: int = TX_SRC_PORT, fmt: str = "sc16") -> int:
        """Program addresses, flush, select the player as DAC source.

        Returns the consumed-word count after the flush: it is free-running
        (only a reset clears it), so the host must use it as its baseline.
        """
        # flush with the player still enabled: a flush adds the buffered words
        # to consumed, so the host's credit stays exact
        self.p.write(PLY_CTRL, PLY_CTRL_ENABLE | PLY_CTRL_FLUSH)
        mm, hm = mac_to_int(my_mac), mac_to_int(host_mac)
        self.p.write(PLY_MY_MAC_LO, mm & 0xFFFFFFFF)
        self.p.write(PLY_MY_MAC_HI, mm >> 32)
        self.p.write(PLY_MY_IP, ip_to_int(my_ip))
        self.p.write(PLY_TX_PORT, int(tx_port) & 0xFFFF)
        self.p.write(PLY_HOST_MAC_LO, hm & 0xFFFFFFFF)
        self.p.write(PLY_HOST_MAC_HI, hm >> 32)
        self.p.write(PLY_HOST_IP, ip_to_int(host_ip))
        self.p.write(PLY_ASYNC_PORT, int(async_port) & 0xFFFF)
        self.p.write(PLY_SRC_PORT, int(src_port) & 0xFFFF)
        self.p.write(PLY_FC_INTERVAL, int(fc_interval))
        self.p.write(PLY_SID, int(sid) & 0xFFFFFFFF)
        code = FMT_CODES[fmt]           # §10, written while flushed (idle)
        self.p.write(PLY_FMT, code)
        if self.p.read(PLY_FMT) != code:
            raise RuntimeError(f"udp_player FMT reads back {self.p.read(PLY_FMT)} after "
                               f"writing {code} ({fmt}): this bitstream has no §10 converter")
        # the untimed-start gate, at most half the credit (quasi-static: idle)
        self.p.write(PLY_USTART, min(USTART_WORDS, self.tx_buf_words() // 2))
        self.p.write(PLY_UTIMEOUT, UTIMEOUT_CYCLES)
        ctrl = PLY_CTRL_ENABLE | PLY_CTRL_DAC_SRC
        self.p.write(PLY_CTRL, ctrl | PLY_CTRL_CLEAR_STATS)
        self.p.write(PLY_CTRL, ctrl)
        return self.consumed_words()

    def player_stop(self) -> None:
        """Flush the TX buffer; the DAC gets zeros (an idle player outputs
        zeros; it stays the DAC source). The player stays enabled so ARP keeps
        working."""
        ctrl = PLY_CTRL_ENABLE | PLY_CTRL_DAC_SRC
        self.p.write(PLY_CTRL, ctrl | PLY_CTRL_FLUSH)
        self.p.write(PLY_CTRL, ctrl)

    def player_stats(self) -> Dict[str, object]:
        out = OrderedDict((k, self.p.read(off)) for k, off in PLY_STATS.items())
        st = self.p.read(PLY_STATUS)
        out["playing"] = int(bool(st & PLY_STATUS_PLAYING))
        out["buffer_empty"] = int(bool(st & PLY_STATUS_BUF_EMPTY))
        out["ctrl"] = "0x%08x" % self.p.read(PLY_CTRL)
        out["buf_words"] = self.p.read(PLY_TX_BUF_WORDS)
        out["fmt"] = self.p.read(PLY_FMT)
        return out

    # -- CMAC (AXI GPIO) ----------------------------------------------------------
    def cmac_ctl(self) -> int:
        return self.g.read(GPIO_DATA)

    def cmac_set_ctl(self, ctl: int) -> None:
        self.g.write(GPIO_DATA, int(ctl) & 0xFFFFFFFF)

    def cmac_status(self) -> int:
        return self.g.read(GPIO2_DATA)

    def cmac_aligned(self) -> bool:
        return bool(self.cmac_status() & ST_RX_ALIGNED)

    def cmac_reset_pulse(self, ctl: Optional[int] = None, hold_s: float = 0.01) -> int:
        """GT sys_reset: bit0 = 1, then 0, other ctl bits kept (or set to `ctl`)."""
        base = (self.cmac_ctl() if ctl is None else int(ctl)) & ~CTL_SYS_RESET
        self.cmac_set_ctl(base | CTL_SYS_RESET)
        time.sleep(hold_s)
        self.cmac_set_ctl(base)
        return base

    def cmac_wait_aligned(self, timeout_s: float = 5.0, poll_s: float = 0.5,
                          report: Optional[Callable[[float, int], None]] = None) -> bool:
        t0 = time.monotonic()
        next_report = t0
        while True:
            st = self.cmac_status()
            now = time.monotonic()
            if report is not None and (now >= next_report or st & ST_RX_ALIGNED):
                report(now - t0, st)
                next_report = now + poll_s
            if st & ST_RX_ALIGNED:
                return True
            if now - t0 > timeout_s:
                return False
            time.sleep(min(0.05, poll_s))

    # -- clock meters ---------------------------------------------------------------
    def refclk_khz(self) -> int:
        return self.f.read(FREQ_REFCLK)

    def usrclk_khz(self) -> int:
        return self.f.read(FREQ_USRCLK)
