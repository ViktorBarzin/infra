"""Tests for the pure logic in ios_rig_wifi. Run: uv run --with pytest --with cryptography pytest cli/ios_assets/wifi"""

import plistlib
from datetime import UTC, datetime, timedelta

import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from ios_rig_wifi import (
    DEFAULT_PAIRING_PORT,
    candidate_ports,
    connect_failure_reason,
    launch_failure_reason,
    matching_certificate,
    needs_resign,
    profile_plist,
    runner_for_attempt,
    should_scan,
    summarise_battery,
    wda_failure_reason,
    wda_runners,
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
        ("Failed to launch process with bundle identifier 'me.viktorbarzin.wda.xctrunner'.", "may have expired"),
        ("0xe8008011 This provisioning profile has expired", "signature expired"),
        ("The application could not be launched because the Developer App Certificate is not trusted", "Trust"),
        ("No such service: com.apple.dt.testmanagerd.remote", "disk image"),
        ("something new", "something new"),
    ],
)
def test_wda_failure_reason_names_the_fix(message, needle):
    assert needle in wda_failure_reason(message)


def test_launch_failure_reason_points_at_the_signature():
    msg = "The request to open \"x\" failed. : Failed to launch process with bundle identifier 'x'."
    assert "signature has most likely expired" in launch_failure_reason("x", msg)
    assert launch_failure_reason("x", "something else") == "something else"


def test_resolve_phone_falls_back_to_the_pinned_address():
    import socket

    from ios_rig_wifi import resolve_phone

    def broken(_host):
        raise socket.gaierror("no such name")

    assert resolve_phone("iphone-london.viktorbarzin.lan", "192.168.9.205", broken) == "192.168.9.205"
    assert resolve_phone("iphone-london.viktorbarzin.lan", "192.168.9.205", lambda h: "10.1.2.3") == "10.1.2.3"


def test_connect_failure_reason_names_a_locked_phone():
    assert "phone is locked" in connect_failure_reason("The device has not been unlocked recently")
    assert connect_failure_reason("timed out") == "timed out"


def test_only_connection_errors_mean_try_another_port():
    import asyncio

    from ios_rig_wifi import means_port_moved

    assert means_port_moved(ConnectionRefusedError())
    assert means_port_moved(TimeoutError())
    assert means_port_moved(asyncio.IncompleteReadError(b"", 4))
    ConnectionTerminatedError = type("ConnectionTerminatedError", (Exception,), {})
    assert means_port_moved(ConnectionTerminatedError())
    # The phone answered: scanning other ports would only hide its reason.
    assert not means_port_moved(RuntimeError("The device has not been unlocked recently"))


@pytest.mark.parametrize(
    "explicit,legacy,want",
    [
        (None, None, ["com.facebook.WebDriverAgentRunner.xctrunner.26NB4W97WL", "me.viktorbarzin.wda.xctrunner"]),
        ("a.xctrunner, b.xctrunner", None, ["a.xctrunner", "b.xctrunner"]),
        (None, "com.example.wda", ["com.facebook.WebDriverAgentRunner.xctrunner.26NB4W97WL", "com.example.wda.xctrunner"]),
        ("  ", None, ["com.facebook.WebDriverAgentRunner.xctrunner.26NB4W97WL", "me.viktorbarzin.wda.xctrunner"]),
    ],
)
def test_wda_runners_prefers_the_linux_signed_build(explicit, legacy, want):
    assert wda_runners(explicit, legacy) == want


@pytest.mark.parametrize("attempts,want", [(0, "a"), (1, "a"), (2, "b"), (3, "a"), (4, "b")])
def test_runner_for_attempt_tries_each_build_in_turn(attempts, want):
    assert runner_for_attempt(["a", "b"], attempts) == want


NOW = datetime(2026, 10, 15, tzinfo=UTC)


@pytest.mark.parametrize(
    "expires,want",
    [
        (None, True),
        (NOW + timedelta(days=7), False),
        (NOW + timedelta(days=3, minutes=1), False),
        (NOW + timedelta(days=3), True),
        (NOW - timedelta(hours=1), True),
    ],
)
def test_needs_resign_three_days_before_the_profile_lapses(expires, want):
    assert needs_resign(expires, NOW) is want


def test_profile_plist_reads_the_xml_inside_the_cms_envelope():
    body = plistlib.dumps({"ExpirationDate": NOW, "Entitlements": {"get-task-allow": True}}, fmt=plistlib.FMT_XML)
    wrapped = b"0\x82\x10\x00junk" + body + b"\x00trailing-signature"
    assert profile_plist(wrapped) == {"ExpirationDate": NOW.replace(tzinfo=None), "Entitlements": {"get-task-allow": True}}


def _self_signed(key):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.x509.oid import NameOID

    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "t")])
    return (
        x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(1).not_valid_before(NOW).not_valid_after(NOW + timedelta(days=1))
        .sign(key, hashes.SHA256())
    )


def test_matching_certificate_picks_the_leaf_for_our_key():
    ours, other = ec.generate_private_key(ec.SECP256R1()), ec.generate_private_key(ec.SECP256R1())
    leaf, ca = _self_signed(ours), _self_signed(other)
    assert matching_certificate([ca, leaf], ours) is leaf
    assert matching_certificate([ca], ours) is None
