"""Pairwise phase search for array calibration.

Channel 0 and the channel under calibration carry the same tone, channel 0
with weight 1 and the other with weight exp(j*theta); every other channel is
off. The received power is

    P(theta) = |h0|^2 + |hk|^2 + 2 |h0| |hk| cos(theta + arg(hk / h0))

so it peaks where the two paths add in phase and has a sharp null 180 deg
away -- at the same theta whatever the two amplitudes are. Searching for the
null (method "MIN") pins the phase down more tightly than the broad peak.

Used by ArrayCalibTask (PYNQ, v47 beamforming designs) and by
rfsoc_lib/uhd/benchmark/phase_cal.py (the same search through UHD).
"""
import numpy as np


def phase_search(measure, coarse_step=15, fine_step=1, fine_span=30,
                 method="MIN", should_stop=None, on_point=None):
    """Coarse sweep over 0..360 deg, then a fine sweep around the extremum.

    measure(theta_deg) -> received power (any monotonic unit, e.g. dB).
    method: "MIN" refines around the null, "MAX" around the peak.
    should_stop(): optional, polled before every measurement.
    on_point(theta_deg, power): optional, called after every measurement.

    Returns (angles, powers), sorted by angle, angles in [0, 360). A theta
    already measured (mod 360) is not measured again. Stops early, returning
    what it has, when should_stop() turns true.
    """
    if method not in ("MIN", "MAX"):
        raise ValueError(f"method {method!r}: expected MIN or MAX")
    measurements = []
    visited = set()

    def do_measure(a):
        norm_a = a % 360
        key = round(norm_a, 6)
        if key in visited:
            return
        p = measure(norm_a)
        measurements.append((norm_a, p))
        visited.add(key)
        if on_point is not None:
            on_point(norm_a, p)

    stop = should_stop or (lambda: False)
    # --- coarse search: 0..360 in coarse_step
    for angle in np.arange(0, 360, coarse_step):
        if stop():
            break
        do_measure(_num(angle))
    if not measurements:
        return [], []
    pick = min if method == "MIN" else max
    target = pick(measurements, key=lambda x: x[1])[0]
    # --- fine search: target +/- fine_span in fine_step
    for angle in np.arange(target - fine_span, target + fine_span + fine_step / 2, fine_step):
        if stop():
            break
        do_measure(_num(angle))
    measurements.sort(key=lambda x: x[0])
    return [m[0] for m in measurements], [m[1] for m in measurements]


def calib_phase(angles, powers, method="MIN", fit=False, power_db=True):
    """Calibration phase c (deg, wrapped to [-180, 180)) from a search.

    Weight exp(j*c) on the channel brings it in phase with channel 0: the
    peak angle (MAX), or the null angle + 180 (MIN) -- the convention
    CharmBeamformer applies to bf_calib_max.txt / bf_calib_min.txt.

    fit=False takes the single extreme point. fit=True instead fits the exact
    model P(theta) = A + B cos(theta - theta0) to every point (linear power;
    power_db says the powers are in dB) and returns theta0, which is the
    same for MIN and MAX. The single point is fragile when the two paths
    differ in level: the null is then shallow and flat-bottomed, and a few
    percent of power noise moves the argmin by 10 deg or more. Measured over
    the air on zcu216-0 at 950 MHz: argmin up to 14.7 deg off the
    complex-sample offset where the null was 6-13 dB deep, the fit within
    1.6 deg on every channel.
    """
    if fit:
        th = np.radians(np.asarray(angles, dtype=float))
        p = np.asarray(powers, dtype=float)
        if power_db:
            p = 10 ** (p / 10)
        X = np.c_[np.ones_like(th), np.cos(th), np.sin(th)]
        _, bc, bs = np.linalg.lstsq(X, p, rcond=None)[0]
        c = np.degrees(np.arctan2(bs, bc))
    else:
        i = int(np.argmin(powers)) if method == "MIN" else int(np.argmax(powers))
        c = angles[i] + (180.0 if method == "MIN" else 0.0)
    return float((c + 180.0) % 360.0 - 180.0)


def _num(x):
    """numpy scalar -> int when integral (so integer steps stay integers)."""
    x = float(x)
    return int(x) if x.is_integer() else x
