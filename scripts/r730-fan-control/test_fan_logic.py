"""Unit tests for the pure fan-control logic (ported from infra/scripts/test-fan-control.sh).

Same power-tuned curves and hysteresis as the bash daemon; adds rpm_to_pct
(stateless hysteresis input for the CronJob) and the mode resolver.
"""
import pytest

import fan_logic as fl


# --- COOL curve (continuous linear: 30% @50C .. 100% @83C) ---
@pytest.mark.parametrize("temp,expected", [
    (40, 30), (50, 30), (55, 41), (60, 51), (64, 60),
    (70, 72), (75, 83), (83, 100), (90, 100),
])
def test_cool_curve(temp, expected):
    assert fl.curve("cool", temp) == expected


# --- QUIET curve (continuous linear: 20% @68C .. 100% @83C) ---
@pytest.mark.parametrize("temp,expected", [
    (60, 20), (68, 20), (70, 31), (75, 57), (80, 84), (83, 100),
])
def test_quiet_curve(temp, expected):
    assert fl.curve("quiet", temp) == expected


# --- hysteresis: ramp up now, step down only past the deadband ---
@pytest.mark.parametrize("temp,current,expected", [
    (68, -1, 68),    # uninitialised -> target
    (68, 25, 68),    # ramp up immediately
    (65, 62, 62),    # equal holds
    (68, 72, 72),    # curve(68)=68<72 but curve(71)=75 !<72 -> hold
    (64, 72, 60),    # curve(64)=60, curve(67)=66<72 -> drop
])
def test_decide_hysteresis(temp, current, expected):
    assert fl.decide("cool", temp, current, deadband=3) == expected


# --- presence resolver ---
NOW = 1_000_000
@pytest.mark.parametrize("state,last_changed,expected", [
    ("Отворена", 0, "quiet"),               # open now
    ("Затворена", NOW - 100, "quiet"),       # closed but recent activity
    ("Затворена", NOW - 1000, "cool"),       # closed, stale
    ("Затворена", NOW - 900, "cool"),        # exactly at hold boundary -> cool
])
def test_presence_mode(state, last_changed, expected):
    assert fl.presence_mode(state, last_changed, NOW, hold_secs=900,
                            open_state="Отворена") == expected


# --- resolve_target: combine HA-desired mode + temp + presence into a target % ---
def test_resolve_manual_uses_slider():
    assert fl.resolve_target("manual", temp=64, manual_pct=42, presence="cool") == 42

def test_resolve_cool_uses_cool_curve():
    assert fl.resolve_target("cool", temp=64, manual_pct=42, presence="cool") == 60

def test_resolve_quiet_uses_quiet_curve():
    assert fl.resolve_target("quiet", temp=80, manual_pct=42, presence="cool") == 84

@pytest.mark.parametrize("presence,temp,expected", [
    ("cool", 64, 60),   # auto + garage empty -> cool curve
    ("quiet", 64, 20),  # auto + someone in garage -> quiet curve
])
def test_resolve_auto_follows_presence(presence, temp, expected):
    assert fl.resolve_target("auto", temp=temp, manual_pct=0, presence=presence) == expected


# --- rpm_to_pct: map a read-back fan RPM to the nearest set-point (stateless hysteresis) ---
@pytest.mark.parametrize("rpm,expected", [
    (4800, 20), (6360, 30), (7920, 40), (9360, 50),
    (11040, 60), (12720, 70), (16920, 100),
    (9000, 50),   # nearest 9360
    (14000, 80),  # nearest 14800 (interpolated 80% point)
    (16500, 100), # nearest 16920
])
def test_rpm_to_pct(rpm, expected):
    assert fl.rpm_to_pct(rpm) == expected


# --- plan_fan: the full decision the controller makes each run ---
def test_plan_ceiling_forces_auto():
    assert fl.plan_fan("cool", temp=90, manual_pct=0, presence="cool", current_pct=60) == ("auto", 0)

def test_plan_ceiling_beats_manual():
    assert fl.plan_fan("manual", temp=85, manual_pct=20, presence="cool", current_pct=60) == ("auto", 0)

def test_plan_manual_sets_slider():
    assert fl.plan_fan("manual", temp=64, manual_pct=42, presence="cool", current_pct=-1) == ("set", 42)

def test_plan_manual_clamped():
    assert fl.plan_fan("manual", temp=64, manual_pct=150, presence="cool", current_pct=-1) == ("set", 100)
    assert fl.plan_fan("manual", temp=64, manual_pct=-5, presence="cool", current_pct=-1) == ("set", 0)

def test_plan_cool_uses_curve_with_hysteresis():
    assert fl.plan_fan("cool", temp=64, manual_pct=0, presence="cool", current_pct=-1) == ("set", 60)
    assert fl.plan_fan("cool", temp=69, manual_pct=0, presence="cool", current_pct=80) == ("set", 70)

@pytest.mark.parametrize("presence,expected", [("cool", 60), ("quiet", 20)])
def test_plan_auto_follows_presence(presence, expected):
    assert fl.plan_fan("auto", temp=64, manual_pct=0, presence=presence, current_pct=-1) == ("set", expected)


# --- pct_to_ipmi_hex ---
@pytest.mark.parametrize("pct,expected", [
    (20, "0x14"), (45, "0x2d"), (60, "0x3c"), (100, "0x64"), (5, "0x05"),
])
def test_pct_to_ipmi_hex(pct, expected):
    assert fl.pct_to_ipmi_hex(pct) == expected


# --- fan_watts: estimated fan power from RPM (cube-law, calibrated to the sweep) ---
@pytest.mark.parametrize("rpm,expected", [
    (0, 0), (4800, 2), (9360, 16), (12720, 42), (16920, 99),
])
def test_fan_watts(rpm, expected):
    assert fl.fan_watts(rpm) == expected
