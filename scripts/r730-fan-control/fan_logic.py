"""Pure fan-control logic for the R730 (no I/O — unit-tested).

Ported from infra/scripts/fan-control.sh (the power-tuned 2026-06-05 curves).
The CronJob controller (controller.py) composes these with IPMI / HA / Pushgateway I/O.
"""
from __future__ import annotations

# "min_temp -> pct" descending; first whose min_temp <= temp wins.
# COOL power-tuned to the ~60% cooling-per-watt knee; 80/100% are a high-load
# safety ramp before the 83 C iDRAC ceiling. QUIET hugs the silent floor.
# Continuous LINEAR ramp per mode: fan% interpolates between (t_lo,p_lo) and
# (t_hi,p_hi), clamped flat outside. Mirrors infra/scripts/fan-control.sh.
#   cool  (garage empty):  30% @50C .. 100% @83C  (~2.1%/C)
#   quiet (someone there): 20% @68C .. 100% @83C
COOL_ANCHORS = (50, 30, 83, 100)   # (t_lo, p_lo, t_hi, p_hi)
QUIET_ANCHORS = (68, 20, 83, 100)

# Measured fan%/RPM calibration (2026-06-05 sweep) for stateless hysteresis.
PCT_RPM = [(20, 4800), (30, 6360), (40, 7920), (50, 9360),
           (60, 11040), (70, 12720), (80, 14800), (100, 16920)]


def curve(mode: str, temp: int) -> int:
    t_lo, p_lo, t_hi, p_hi = QUIET_ANCHORS if mode == "quiet" else COOL_ANCHORS
    if temp <= t_lo:
        return p_lo
    if temp >= t_hi:
        return p_hi
    return p_lo + ((temp - t_lo) * (p_hi - p_lo) + (t_hi - t_lo) // 2) // (t_hi - t_lo)


def decide(mode: str, temp: int, current: int, deadband: int = 3) -> int:
    """Hysteresis: ramp up immediately; step down only once the curve still
    wants a lower percent `deadband` degrees hotter."""
    target = curve(mode, temp)
    if current < 0 or target >= current:
        return target
    return target if curve(mode, temp + deadband) < current else current


def presence_mode(state: str, last_changed: float, now: float,
                  hold_secs: int, open_state: str) -> str:
    """Garage door -> QUIET (someone there) or COOL (empty)."""
    if state == open_state or (now - last_changed) < hold_secs:
        return "quiet"
    return "cool"


def resolve_target(mode: str, temp: int, manual_pct: int, presence: str) -> int:
    """Combine HA-desired mode + temp + presence into a target fan %."""
    if mode == "manual":
        return manual_pct
    if mode in ("cool", "quiet"):
        return curve(mode, temp)
    return curve(presence, temp)  # mode == "auto" -> presence-driven


def clamp_pct(pct: int) -> int:
    return max(0, min(100, pct))


def plan_fan(mode: str, temp: int, manual_pct: int, presence: str,
             current_pct: int, deadband: int = 3, ceiling: int = 83):
    """The full per-run decision. Returns ("auto", 0) to hand fans back to the
    iDRAC, or ("set", pct) to drive a manual percent.

    Precedence: hard ceiling > manual override > curve (with hysteresis)."""
    if temp >= ceiling:
        return ("auto", 0)
    if mode == "manual":
        return ("set", clamp_pct(manual_pct))
    eff_curve = presence if mode == "auto" else mode  # "cool" | "quiet"
    return ("set", decide(eff_curve, temp, current_pct, deadband))


def rpm_to_pct(rpm: int) -> int:
    """Nearest set-point for a read-back RPM (stateless hysteresis input)."""
    return min(PCT_RPM, key=lambda pr: abs(pr[1] - rpm))[0]


def pct_to_ipmi_hex(pct: int) -> str:
    return f"0x{pct:02x}"


def fan_watts(rpm: int) -> int:
    """Estimated TOTAL fan power (W). The iDRAC exposes only total DCMI watts +
    RPM (no per-fan power), so this is a cube-law model (fan power ∝ RPM³)
    calibrated to the 2026-06-05 sweep — fits within ~3W (~2W@4800 · ~17W@9360 ·
    ~42W@12720 · ~99W@16920). Mirrors fc_fan_watts in fan-control.sh."""
    return rpm ** 3 * 205 // 10_000_000_000_000
