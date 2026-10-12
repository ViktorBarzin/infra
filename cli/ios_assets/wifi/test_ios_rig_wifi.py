"""Tests for the pure logic in ios_rig_wifi. Run: uv run --with pytest pytest cli/ios_assets/wifi"""

import pytest

from ios_rig_wifi import (
    DEFAULT_PAIRING_PORT,
    candidate_ports,
    should_scan,
    summarise_battery,
    wda_failure_reason,
)


@pytest.mark.parametrize(
    "cached,scanned,want",
    [
        (None, [], [DEFAULT_PAIRING_PORT]),
        (50000, [], [50000, DEFAULT_PAIRING_PORT]),
        (DEFAULT_PAIRING_PORT, [DEFAULT_PAIRING_PORT, 60000], [DEFAULT_PAIRING_PORT, 60000]),
        (None, [60000, 61000], [DEFAULT_PAIRING_PORT, 60000, 61000]),
    ],
)
def test_candidate_ports_orders_cached_then_default_then_scan(cached, scanned, want):
    assert candidate_ports(cached, scanned) == want


@pytest.mark.parametrize(
    "last,now,cooldown,want",
    [
        (None, 1000.0, 300, True),  # never failed
        (900.0, 1000.0, 300, False),  # inside the window
        (700.0, 1000.0, 300, True),  # window over
        (1500.0, 1000.0, 300, True),  # clock went backwards: fail toward working
    ],
)
def test_should_scan_respects_the_cooldown(last, now, cooldown, want):
    assert should_scan(last, now, cooldown) is want


def test_summarise_battery_keeps_the_charger_fields():
    raw = {"CurrentCapacity": 100, "IsCharging": False, "ExternalConnected": True, "FullyCharged": True, "Voltage": 4300}
    assert summarise_battery(raw) == {"percent": 100, "charging": False, "external_power": True, "fully_charged": True}


def test_summarise_battery_handles_no_data():
    assert summarise_battery(None) is None
    assert summarise_battery({}) is None


@pytest.mark.parametrize(
    "message,needle",
    [
        ("Failed to launch process with bundle identifier 'me.viktorbarzin.wda.xctrunner'.", "signature has most likely expired"),
        ("0xe8008011 This provisioning profile has expired", "signature has most likely expired"),
        ("The application could not be launched because the Developer App Certificate is not trusted", "Trust"),
        ("No such service: com.apple.dt.testmanagerd.remote", "disk image"),
        ("something new", "something new"),
    ],
)
def test_wda_failure_reason_names_the_fix(message, needle):
    assert needle in wda_failure_reason(message)
