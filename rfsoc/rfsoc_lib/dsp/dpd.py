"""MPL-4x4 digital predistortion: the bit-exact model of the FPGA's tx_dpd,
its coefficient words, the safety gate and the indirect-learning fit.

The one reference the TX DPD's users share (Protocol §12): the RTL sims
(fpga/ip/src/uhd_ip/sim/check_dpd.py), the daemon (rfsoc/server/tx_dpd.py,
backend.py) and the host tool (host/tools/rfsoc_dpd.py). Numpy only, Python
3.8 (the board's).

Model, per channel (x = I + jQ normalised to full scale, eps = |x|^2 / 2):

    z(n)   = sum_{m=0..3} G_m(n) x(n-m)
    G_m(n) = a_m0 + sum_{j=1..3} a_mj eps(n-m)^j
             + [m<=1] sum_{j=1..2} b_mj eps(n-m-1)^j

20 complex coefficients: a_mj at index 4m + j, b_mj at 16 + 2m + (j-1),
Q6.21 in 27 bits. The identity set (a_00 = 1.0) passes x through exactly.

Fixed point (the RTL, src/dpd_mpl_core.sv), all integer:
    e1 = min((I*I + Q*Q) >> 14, 131071), e2 = (e1*e1) >> 17, e3 = (e2*e1) >> 17
    acc = (a_m0 << 17) + 2^22 + sum c*e     g_m = sat18(acc >> 23)
    z   = sum_m g_m(n-m) * x(n-m)  (exact)  y = sat16((z + 2^14) >> 15)
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

NCOEF = 20
COEF_W = 27
COEF_FRAC = 21
COEF_LIMIT = 31.0           # |re|, |im| of a coefficient must stay below
FULL_SCALE = 32768.0
RAIL_MAX_095 = 31129        # 0.95 FS: the gate's output peak limit
LATENCY = 32                # converter clock cycles, every mode
_E1_MAX = 131071

DPD_ID = 0x5A443031         # 'ZD01'
DPD_CONFIG = 0x20142244
CH_STRIDE = 0x400
REG_CTRL = 0x000
REG_STATUS = 0x004
REG_ID = 0x008
REG_CONFIG = 0x00C
REG_SAT_OUT = 0x010
REG_SAT_GAIN = 0x014
REG_PEAK = 0x018
REG_TOPO = 0x01C
REG_SHADOW = 0x100
REG_ACTIVE = 0x200
CTRL_BYPASS = 1 << 0
CTRL_COMMIT = 1 << 1
CTRL_CLR_STATS = 1 << 2
CTRL_SHADOW_IDENTITY = 1 << 3
STATUS_BYPASS = 1 << 0
STATUS_COMMIT_PENDING = 1 << 1
STATUS_MSG_PENDING = 1 << 2
STATUS_RESET = 1 << 3


# ----------------------------------------------------------------------
# Coefficients
# ----------------------------------------------------------------------
def idx_a(m: int, j: int) -> int:
    """Index of a_{m,j} (m = 0..3, j = 0..3)."""
    if not (0 <= m <= 3 and 0 <= j <= 3):
        raise ValueError(f"bad a index m={m} j={j}")
    return 4 * m + j


def idx_b(m: int, j: int) -> int:
    """Index of b_{m,j} (m = 0..1, j = 1..2)."""
    if not (0 <= m <= 1 and 1 <= j <= 2):
        raise ValueError(f"bad b index m={m} j={j}")
    return 16 + 2 * m + (j - 1)


def identity_q() -> np.ndarray:
    """The pass-through set as (20, 2) Q6.21 integers [re, im]."""
    c = np.zeros((NCOEF, 2), dtype=np.int64)
    c[0, 0] = 1 << COEF_FRAC
    return c


def quantize(c: np.ndarray) -> np.ndarray:
    """Complex float coefficients -> (20, 2) Q6.21 integers.

    Raises ValueError if a rail is >= COEF_LIMIT in magnitude."""
    c = np.asarray(c, dtype=complex)
    if c.shape != (NCOEF,):
        raise ValueError(f"expected {NCOEF} coefficients, got {c.shape}")
    if np.any(np.abs(c.real) >= COEF_LIMIT) or np.any(np.abs(c.imag) >= COEF_LIMIT):
        raise ValueError(f"coefficient rail magnitude >= {COEF_LIMIT}")
    scale = float(1 << COEF_FRAC)
    lo, hi = -(1 << (COEF_W - 1)), (1 << (COEF_W - 1)) - 1
    return np.stack([np.clip(np.rint(c.real * scale), lo, hi),
                     np.clip(np.rint(c.imag * scale), lo, hi)], axis=1).astype(np.int64)


def dequantize(cq: np.ndarray) -> np.ndarray:
    cq = np.asarray(cq, dtype=np.int64).reshape(NCOEF, 2)
    return (cq[:, 0] + 1j * cq[:, 1]) / float(1 << COEF_FRAC)


def check_q(cq) -> np.ndarray:
    """Validate a Q6.21 set: 20 x [re, im] integers, each rail below
    COEF_LIMIT (the hardware's 27 bits hold +-32). Returns it as (20, 2)."""
    a = np.asarray(cq, dtype=np.int64)
    if a.size != 2 * NCOEF:
        raise ValueError(f"expected {2 * NCOEF} integers (re0 im0 .. re19 im19), got {a.size}")
    a = a.reshape(NCOEF, 2)
    lim = int(COEF_LIMIT * (1 << COEF_FRAC))
    if np.any(np.abs(a) >= lim):
        raise ValueError(f"a coefficient rail is >= {COEF_LIMIT} (Q6.21 {lim})")
    return a


def to_words(cq: np.ndarray) -> list:
    """(20, 2) set -> the 40 SHADOW words in address order (word 2i real,
    2i+1 imaginary of coefficient i; value in [26:0])."""
    a = np.asarray(cq, dtype=np.int64).reshape(-1)
    return [int(v) & ((1 << COEF_W) - 1) for v in a]


def from_words(words) -> np.ndarray:
    """40 register words (sign-extended or not) -> (20, 2) set."""
    out = []
    for w in words:
        w = int(w) & ((1 << COEF_W) - 1)
        out.append(w - (1 << COEF_W) if w >> (COEF_W - 1) else w)
    return np.array(out, dtype=np.int64).reshape(NCOEF, 2)


def gain_bound(cq: np.ndarray, amp: float = 1.0) -> float:
    """Upper bound of |z| / amp over every input with |x| <= amp (normalised):
    sum_m max_eps |G_m|, |G_m| bounded term by term. With a bound strictly
    below 1, an input of |x| <= amp (amp <= 1) does not saturate the output;
    otherwise it may. int16 inputs reach |x| = sqrt(2) (both rails at full
    scale): the waveform gate (gate()) is the check that counts."""
    c = dequantize(cq)
    e = amp * amp / 2.0
    b = 0.0
    for m in range(4):
        g = sum(abs(c[idx_a(m, j)]) * e ** j for j in range(4))
        if m <= 1:
            g += sum(abs(c[idx_b(m, j)]) * e ** j for j in (1, 2))
        b += g
    return b


# ----------------------------------------------------------------------
# Models
# ----------------------------------------------------------------------
def _delay(a: np.ndarray, d: int) -> np.ndarray:
    """a(n-d) along axis 0, zero history."""
    if d == 0:
        return a.copy()
    out = np.zeros_like(a)
    out[d:] = a[:-d]
    return out


def basis(x: np.ndarray) -> np.ndarray:
    """(N, 20) basis of normalised complex x; column k <-> coefficient k."""
    x = np.asarray(x, dtype=complex)
    eps = np.abs(x) ** 2 / 2.0
    phi = np.zeros((x.size, NCOEF), dtype=complex)
    for m in range(4):
        xm = _delay(x, m)
        em = _delay(eps, m)
        for j in range(4):
            phi[:, idx_a(m, j)] = em ** j * xm
        if m <= 1:
            el = _delay(eps, m + 1)
            for j in (1, 2):
                phi[:, idx_b(m, j)] = el ** j * xm
    return phi


def dpd_float(x: np.ndarray, c: np.ndarray) -> np.ndarray:
    """Float model: z = basis(x) @ c (normalised complex)."""
    return basis(x) @ np.asarray(c, dtype=complex)


@dataclass(frozen=True)
class FxResult:
    i: np.ndarray           # output I per sample (int)
    q: np.ndarray
    sat_out: np.ndarray     # saturated output rails per sample (0..2)
    sat_gain: np.ndarray    # saturated gains per sample (0..8)


def dpd_fx(i, q, sets, set_idx=None, bypass=None, valid=None) -> FxResult:
    """Bit-exact model of one tx_dpd channel on a sample stream.

    i, q: int16 sample streams. sets: list of (20, 2) Q6.21 sets; set_idx[n]
    the set in effect for sample n, bypass[n] passes sample n through,
    valid[n] = False makes it zero (an idle beat). Defaults: set 0, no
    bypass, every sample valid. Latency is not modelled."""
    ii = np.asarray(i, dtype=np.int64).copy()
    qq = np.asarray(q, dtype=np.int64).copy()
    n = ii.size
    v = np.ones(n, dtype=bool) if valid is None else np.asarray(valid, dtype=bool)
    ii[~v] = 0
    qq[~v] = 0
    ss = np.zeros(n, dtype=np.int64) if set_idx is None else np.asarray(set_idx, dtype=np.int64)
    sb = np.zeros(n, dtype=bool) if bypass is None else np.asarray(bypass, dtype=bool)
    cs = np.stack([np.asarray(s, dtype=np.int64).reshape(NCOEF, 2) for s in sets])

    e1 = np.minimum((ii * ii + qq * qq) >> 14, _E1_MAX)
    e2 = (e1 * e1) >> 17
    e3 = (e2 * e1) >> 17
    e = {1: e1, 2: e2, 3: e3}
    elag = {1: _delay(e1, 1), 2: _delay(e2, 1)}

    g = np.zeros((n, 4, 2), dtype=np.int64)
    satg = np.zeros(n, dtype=np.int64)
    for rail in range(2):
        cc = cs[ss, :, rail]
        for m in range(4):
            acc = (cc[:, idx_a(m, 0)] << 17) + (1 << 22)
            for j in (1, 2, 3):
                acc = acc + cc[:, idx_a(m, j)] * e[j]
            if m <= 1:
                for j in (1, 2):
                    acc = acc + cc[:, idx_b(m, j)] * elag[j]
            sh = acc >> 23
            satg += ((sh < -(1 << 17)) | (sh > (1 << 17) - 1)).astype(np.int64)
            g[:, m, rail] = np.clip(sh, -(1 << 17), (1 << 17) - 1)

    zr = np.zeros(n, dtype=np.int64)
    zi = np.zeros(n, dtype=np.int64)
    for m in range(4):
        gr, gi = g[:, m, 0], g[:, m, 1]
        zr += _delay(gr * ii - gi * qq, m)
        zi += _delay(gr * qq + gi * ii, m)
    pr = (zr + (1 << 14)) >> 15
    pi = (zi + (1 << 14)) >> 15
    sato = (((pr < -32768) | (pr > 32767)).astype(np.int64)
            + ((pi < -32768) | (pi > 32767)).astype(np.int64))
    oi = np.where(sb, ii, np.clip(pr, -32768, 32767))
    oq = np.where(sb, qq, np.clip(pi, -32768, 32767))
    oi[~v] = 0
    oq[~v] = 0
    # the RTL counts saturation of DPD-path samples whatever bypass says
    return FxResult(i=oi, q=oq, sat_out=np.where(v, sato, 0), sat_gain=np.where(v, satg, 0))


def dpd_fx_periodic(x: np.ndarray, cq: np.ndarray) -> FxResult:
    """Steady-state output of a waveform played in a loop: the history at
    the start of a period is the end of the previous one. x complex int."""
    x = np.asarray(x)
    xi = np.rint(x.real).astype(np.int64)
    xq = np.rint(x.imag).astype(np.int64)
    r = dpd_fx(np.tile(xi, 2), np.tile(xq, 2), [cq])
    n = x.size
    return FxResult(i=r.i[n:], q=r.q[n:], sat_out=r.sat_out[n:], sat_gain=r.sat_gain[n:])


def gate(x: np.ndarray, cq: np.ndarray, rail_limit: int = RAIL_MAX_095):
    """Safety gate of one (waveform, set) pair: the DPD output of this
    looping waveform peaks at <= rail_limit with no saturation. Returns
    (ok, peak, sat_out, sat_gain)."""
    r = dpd_fx_periodic(x, cq)
    peak = int(max(np.abs(r.i).max(initial=0), np.abs(r.q).max(initial=0)))
    so, sg = int(r.sat_out.sum()), int(r.sat_gain.sum())
    return (peak <= rail_limit and so == 0 and sg == 0), peak, so, sg


# ----------------------------------------------------------------------
# Indirect-learning fit and metrics
# ----------------------------------------------------------------------
def apply_delay(x: np.ndarray, d: float) -> np.ndarray:
    """x(n - d) of a periodic x (fractional d: a linear phase)."""
    x = np.asarray(x, dtype=complex)
    f = np.fft.fftfreq(x.size)
    return np.fft.ifft(np.fft.fft(x) * np.exp(-2j * np.pi * f * d))


def estimate_delay(y: np.ndarray, ref: np.ndarray, min_rel_power: float = 1e-2) -> float:
    """Delay D of y(n) = G ref(n - D) (both one period, same length), in
    samples: the cyclic cross-correlation peak, then the slope of the
    cross-spectrum phase over the bins that carry signal (two passes)."""
    y = np.asarray(y, dtype=complex)
    ref = np.asarray(ref, dtype=complex)
    n = ref.size
    rs = np.fft.fft(ref)
    d = int(np.argmax(np.abs(np.fft.ifft(np.fft.fft(y) * np.conj(rs)))))
    if d > n // 2:
        d -= n
    pw = np.abs(rs) ** 2
    sel = pw > min_rel_power * pw.max()
    k = np.fft.fftfreq(n)[sel]
    frac = 0.0
    for _ in range(2):
        s = (np.fft.fft(apply_delay(y, -(d + frac))) * np.conj(rs))[sel]
        ph = np.angle(s * np.exp(-1j * np.angle(s.sum())))
        w = np.abs(s)
        kc = k - np.sum(w * k) / np.sum(w)
        frac += float(-np.sum(w * kc * ph) / np.sum(w * kc * kc) / (2 * np.pi))
    return d + frac


def small_signal_gain(z: np.ndarray, ya: np.ndarray, rel_amp: float = 0.3) -> complex:
    """Complex LS gain of ya on z over the samples with |z| < rel_amp x peak
    (the loop's linear gain, below compression)."""
    sel = np.abs(z) < rel_amp * np.abs(z).max()
    return complex(np.sum(np.conj(z[sel]) * ya[sel]) / np.sum(np.abs(z[sel]) ** 2))


def ila_solve(y: np.ndarray, z: np.ndarray, lam_rel: float = 1e-5) -> np.ndarray:
    """Post-inverse c with basis(y) @ c ~= z (regularised least squares).
    y: the PA output aligned and divided by the loop's small-signal gain;
    z: what the DPD gave the DAC (normalised)."""
    phi = basis(y)
    a = phi.conj().T @ phi
    lam = lam_rel * float(np.mean(np.real(np.diag(a))))
    return np.linalg.solve(a + lam * np.eye(NCOEF), phi.conj().T @ z)


@dataclass(frozen=True)
class IlaResult:
    c: np.ndarray           # the new set, float (apply quantize())
    delay: float            # loop delay of the capture, samples
    gain: complex           # loop small-signal gain used
    fit_nmse_db: float      # residual of the post-inverse fit


def ila_step(x_q: np.ndarray, cq: np.ndarray, y: np.ndarray, gain=None,
             damping: float = 0.5, lam_rel: float = 1e-5) -> IlaResult:
    """One indirect-learning iteration. x_q: the looping waveform (complex
    int, one period); cq: the set in effect while y was captured; y: one
    period of the loop output (complex, any scale and delay, e.g. the mean
    of several captured periods). gain: the loop's small-signal gain from an
    earlier iteration (None: estimate it here; fix it from the first,
    identity, capture). Returns c + damping (c_fit - c)."""
    r = dpd_fx_periodic(x_q, cq)
    z = (r.i + 1j * r.q) / FULL_SCALE
    d = estimate_delay(y, z)
    ya = apply_delay(np.asarray(y, dtype=complex), -d)
    g = small_signal_gain(z, ya) if gain is None else complex(gain)
    if not np.isfinite(g) or abs(g) < 1e-12:
        raise ValueError("zero loop gain: no signal in the capture")
    c_fit = ila_solve(ya / g, z, lam_rel)
    fit = nmse_db(basis(ya / g) @ c_fit, z)
    c_old = dequantize(cq)
    return IlaResult(c=c_old + damping * (c_fit - c_old), delay=d, gain=g, fit_nmse_db=fit)


def measure(y: np.ndarray, x_q: np.ndarray, fs: float, bw: float) -> dict:
    """Loop output y (one period) against the intended waveform x_q: aligned
    and scaled by one LS gain. nmse_db (the in-band error, linear distortion
    included), acpr_lo / acpr_hi (dBc), delay and gain."""
    ref = np.asarray(x_q, dtype=complex) / FULL_SCALE
    d = estimate_delay(y, ref)
    ya = apply_delay(np.asarray(y, dtype=complex), -d)
    g = complex(np.vdot(ref, ya) / np.vdot(ref, ref))
    lo, hi = acpr_db(ya, fs, bw)
    return {"nmse_db": nmse_db(ya / g, ref), "acpr_lo": lo, "acpr_hi": hi,
            "delay": d, "gain": g}


def nmse_db(y: np.ndarray, ref: np.ndarray) -> float:
    """10 log10 |y - ref|^2 / |ref|^2."""
    e = np.vdot(y - ref, y - ref).real
    return 10 * np.log10(max(e, 1e-300) / max(np.vdot(ref, ref).real, 1e-300))


def band_powers(y: np.ndarray, fs: float, bw: float):
    """Power in the main channel |f| <= bw/2 and in the adjacent ones
    (bw/2 .. 3bw/2 above and below) of ONE PERIOD of a periodic signal: its
    exact spectrum (the DFT of the whole period, no window, so no leakage
    across the channel edges). Returns (main, lower, upper)."""
    y = np.asarray(y, dtype=complex)
    p = np.abs(np.fft.fft(y)) ** 2
    f = np.fft.fftfreq(y.size, 1.0 / fs)
    main = p[np.abs(f) <= bw / 2].sum()
    lower = p[(f < -bw / 2) & (f >= -1.5 * bw)].sum()
    upper = p[(f > bw / 2) & (f <= 1.5 * bw)].sum()
    return main, lower, upper


def acpr_db(y: np.ndarray, fs: float, bw: float):
    """Adjacent-channel power ratios (lower, upper) in dB of one period of a
    periodic signal of occupied bandwidth bw centred at 0 Hz."""
    m, lo, up = band_powers(y, fs, bw)
    return 10 * np.log10(max(lo, 1e-300) / m), 10 * np.log10(max(up, 1e-300) / m)
