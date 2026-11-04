"""The London projector wake script: `scripts/london-projector/wake-projector.sh`.

When the projector does not wake, the script asks the London LAN whether the
set still answers at layer 2, because that separates "asleep" from "radio off
or no power". The question only has an answer on a box that sits on the
projector's own segment, and that box is the London Flint 2 router
(root@10.3.2.6), which holds .1 on both London subnets.

The projector's address moves between 192.168.8.0/24 and 192.168.9.0/24, so
the script looks the name up and takes the router's address on the same /24.

These tests run the real script with stand-ins for `getent`, `ping`, `ssh`,
`adb`, `sleep`, `python3` and `homelab` on PATH, so nothing reaches the network
and nothing is sent to the projector.
"""

from __future__ import annotations

import os
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent / "wake-projector.sh"
HOST = "192.168.9.100"
MAC_COLONS = "f4:9d:8a:26:0b:18"


@dataclass
class Run:
    code: int
    stderr: str
    ssh_calls: list[str]
    ping_calls: list[str]
    homelab_calls: list[str]


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _getent(bin_dir: Path, address: str | None = HOST) -> None:
    """Stand in for DNS: the projector's name resolves to `address`, or not at all."""
    if address is None:
        _stub(bin_dir, "getent", "exit 2\n")
    else:
        _stub(bin_dir, "getent", f'echo "{address}       $2"\n')


def run_script(tmp_path: Path, router_reply: str | None, pings_up: tuple[str, ...]) -> Run:
    """Run the script with the projector down and `router_reply` from the router.

    `router_reply` is what the Flint 2 prints for the probe, or None for an ssh
    that fails to connect.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _getent(bin_dir)
    log = tmp_path / "log"
    log.mkdir()
    _stub(
        bin_dir,
        "ping",
        f'echo "$*" >> {log}/ping\n'
        'host="${@: -1}"\n'
        f'for up in {" ".join(pings_up)}; do [ "$host" = "$up" ] && exit 0; done\n'
        "exit 1\n",
    )
    if router_reply is None:
        ssh_body = f'echo "$*" >> {log}/ssh\necho "ssh: connect timed out" >&2\nexit 255\n'
    else:
        (tmp_path / "reply").write_text(router_reply)
        ssh_body = f'echo "$*" >> {log}/ssh\ncat {tmp_path}/reply\n'
    _stub(bin_dir, "ssh", ssh_body)
    _stub(bin_dir, "homelab", f'echo "$*" >> {log}/homelab\nexit 0\n')
    _stub(bin_dir, "sleep", "exit 0\n")
    _stub(bin_dir, "python3", "cat >/dev/null\nexit 0\n")
    _stub(bin_dir, "adb", "exit 0\n")
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "HOME": str(tmp_path),
    }
    result = subprocess.run(
        ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60
    )

    def lines(name: str) -> list[str]:
        path = log / name
        return path.read_text().splitlines() if path.exists() else []

    return Run(result.returncode, result.stderr, lines("ssh"), lines("ping"), lines("homelab"))


FAILED_NOT_ASSOCIATED = f"neigh {HOST} dev br-guest FAILED \nassoc no\n"
REACHABLE_ASSOCIATED = f"neigh {HOST} dev br-guest lladdr {MAC_COLONS} REACHABLE \nassoc yes\n"


def test_the_layer_2_probe_runs_on_the_router_and_not_the_home_assistant_box(tmp_path):
    run = run_script(tmp_path, FAILED_NOT_ASSOCIATED, pings_up=("192.168.9.1",))
    assert run.homelab_calls == []
    command = "\n".join(run.ssh_calls)
    assert command.count("root@10.3.2.6") == 1
    assert f"ip -4 neigh show {HOST}" in command
    assert MAC_COLONS in command


def test_the_path_check_pings_the_router_on_the_projectors_own_segment(tmp_path):
    run = run_script(tmp_path, FAILED_NOT_ASSOCIATED, pings_up=("192.168.9.1",))
    assert any(call.endswith(" 192.168.9.1") for call in run.ping_calls)
    assert not any("192.168.8." in call for call in run.ping_calls)


def test_no_arp_and_no_association_means_off_or_radio_down(tmp_path):
    run = run_script(tmp_path, FAILED_NOT_ASSOCIATED, pings_up=("192.168.9.1",))
    assert run.code == 2
    assert "does NOT answer ARP" in run.stderr
    assert "not associated" in run.stderr
    assert "Its Wi-Fi is off while the set is wide awake" in run.stderr


def test_an_associated_set_that_answers_arp_is_reported_as_such(tmp_path):
    run = run_script(tmp_path, REACHABLE_ASSOCIATED, pings_up=("192.168.9.1",))
    assert run.code == 2
    assert "DOES answer ARP" in run.stderr
    assert "is associated" in run.stderr
    assert "does NOT answer ARP" not in run.stderr


@pytest.mark.parametrize("state", ["REACHABLE", "DELAY", "STALE", "PROBE", "PERMANENT"])
def test_an_entry_with_a_resolved_mac_answers_arp_whatever_its_state(tmp_path, state):
    """The router prints `lladdr` before the state word, as `ip -4 neigh` does on
    the Flint 2: '192.168.9.205 dev br-guest lladdr 6e:b1:68:39:7b:22 REACHABLE'.
    An entry that carries a MAC has answered ARP, so STALE and PROBE count too."""
    reply = f"neigh {HOST} dev br-guest lladdr {MAC_COLONS} {state} \nassoc yes\n"
    run = run_script(tmp_path, reply, pings_up=("192.168.9.1",))
    assert "DOES answer ARP" in run.stderr
    assert "does NOT answer ARP" not in run.stderr


@pytest.mark.parametrize("state", ["FAILED", "INCOMPLETE"])
def test_an_entry_without_a_mac_does_not_answer_arp(tmp_path, state):
    reply = f"neigh {HOST} dev br-guest {state} \nassoc no\n"
    run = run_script(tmp_path, reply, pings_up=("192.168.9.1",))
    assert "does NOT answer ARP" in run.stderr
    assert "DOES answer ARP" not in run.stderr


def test_a_router_that_cannot_be_asked_is_not_read_as_no_arp(tmp_path):
    """The old bug: an empty answer printed the 'does NOT answer ARP' verdict."""
    run = run_script(tmp_path, None, pings_up=("192.168.9.1",))
    assert run.code == 2
    assert "does NOT answer ARP" not in run.stderr
    assert "could not ask the router" in run.stderr


@pytest.mark.parametrize("reply", ["", "neigh \n"])
def test_a_reply_without_the_association_line_is_unknown_not_no_arp(tmp_path, reply):
    run = run_script(tmp_path, reply, pings_up=("192.168.9.1",))
    assert "does NOT answer ARP" not in run.stderr
    assert "could not ask the router" in run.stderr


def test_the_router_down_is_blamed_on_the_tunnel(tmp_path):
    run = run_script(tmp_path, FAILED_NOT_ASSOCIATED, pings_up=())
    assert run.code == 2
    assert "Check the site-to-site tunnel" in run.stderr
    assert run.ssh_calls == []


def test_the_script_is_executable():
    assert os.access(SCRIPT, os.X_OK)


def run_reachable(tmp_path: Path, wakefulness: list[str]) -> tuple[Run, list[str]]:
    """Run the script with the projector answering ping and adb attached.

    In the "Increased" energy mode the set stays on the network in standby, so
    ping answering says nothing about the lamp. `wakefulness` is what each
    successive `dumpsys power` reports, one entry per call; the last repeats.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _getent(bin_dir)
    log = tmp_path / "log"
    log.mkdir()
    (tmp_path / "states").write_text("\n".join(wakefulness) + "\n")
    _stub(bin_dir, "ping", "exit 0\n")
    _stub(bin_dir, "sleep", "exit 0\n")
    _stub(
        bin_dir,
        "adb",
        f'echo "$*" >> {log}/adb\n'
        'case "$*" in\n'
        f'  devices) printf "List of devices attached\\n{HOST}:5555\\tdevice\\n" ;;\n'
        '  *"dumpsys power"*)\n'
        f'    state=$(head -1 {tmp_path}/states)\n'
        f'    [ "$(wc -l < {tmp_path}/states)" -gt 1 ] && sed -i 1d {tmp_path}/states\n'
        '    echo "  mWakefulness=$state" ;;\n'
        "esac\n"
        "exit 0\n",
    )
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path)}
    result = subprocess.run(
        ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60
    )
    adb_log = log / "adb"
    adb_calls = adb_log.read_text().splitlines() if adb_log.exists() else []
    return Run(result.returncode, result.stderr, [], [], []), adb_calls


def test_a_set_in_networked_standby_gets_its_screen_woken(tmp_path):
    run, adb_calls = run_reachable(tmp_path, ["Asleep", "Awake"])
    assert run.code == 0
    assert any("input keyevent KEYCODE_WAKEUP" in call for call in adb_calls)
    assert "screen is on" in run.stderr


def test_an_awake_set_is_left_alone(tmp_path):
    run, adb_calls = run_reachable(tmp_path, ["Awake"])
    assert run.code == 0
    assert not any("KEYCODE_WAKEUP" in call for call in adb_calls)


def test_a_screen_that_will_not_wake_is_reported(tmp_path):
    run, adb_calls = run_reachable(tmp_path, ["Asleep"])
    assert run.code == 2
    assert "still Asleep" in run.stderr


# --status: the read-only check an agent runs before it says anything about
# whether the projector is available. On 2026-10-31 an agent reported the set
# "still off the network" from a measurement twelve hours old while Viktor was
# watching it, so the check has to be one call that changes nothing on the set.

HOME_ACTIVITY = "com.google.android.apps.tv.launcherx/.home.HomeActivity"


def run_status(
    tmp_path: Path,
    *,
    ping_up: bool = True,
    adb_state: str = "device",
    wakefulness: str = "Awake",
    top: str = "me.viktorbarzin.tv/.MainActivity",
    router_reply: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], list[str], list[str]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _getent(bin_dir)
    log = tmp_path / "log"
    log.mkdir()
    _stub(
        bin_dir,
        "ping",
        f'host="${{@: -1}}"\n[ "$host" = "192.168.9.1" ] && exit 0\nexit {0 if ping_up else 1}\n',
    )
    _stub(bin_dir, "sleep", "exit 0\n")
    _stub(bin_dir, "python3", f'echo wol >> {log}/python3\ncat >/dev/null\nexit 0\n')
    if router_reply is None:
        _stub(bin_dir, "ssh", 'echo "ssh: connect timed out" >&2\nexit 255\n')
    else:
        (tmp_path / "reply").write_text(router_reply)
        _stub(bin_dir, "ssh", f"cat {tmp_path}/reply\n")
    _stub(
        bin_dir,
        "adb",
        f'echo "$*" >> {log}/adb\n'
        'case "$*" in\n'
        f'  devices) printf "List of devices attached\\n{HOST}:5555\\t{adb_state}\\n" ;;\n'
        f'  *"dumpsys power"*) echo "  mWakefulness={wakefulness}" ;;\n'
        f'  *"dumpsys activity activities"*) '
        f'echo "  topResumedActivity=ActivityRecord{{1 u0 {top} t1}}" ;;\n'
        f'  *"resolve-activity"*) echo "priority=0"; echo "{HOME_ACTIVITY}" ;;\n'
        "esac\n"
        "exit 0\n",
    )
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path)}
    result = subprocess.run(
        ["bash", str(SCRIPT), "--status"], env=env, capture_output=True, text=True, timeout=60
    )

    def lines(name: str) -> list[str]:
        path = log / name
        return path.read_text().splitlines() if path.exists() else []

    return result, lines("adb"), lines("python3")


def test_status_names_the_app_on_screen_as_in_use(tmp_path):
    result, adb_calls, _ = run_status(tmp_path)
    assert result.returncode == 0
    assert result.stdout.startswith("in use: me.viktorbarzin.tv")


def test_status_reports_the_launcher_as_free(tmp_path):
    result, _, _ = run_status(tmp_path, top=HOME_ACTIVITY)
    assert result.returncode == 0
    assert result.stdout.startswith("free: on, showing the launcher")


def test_status_reports_standby_as_free(tmp_path):
    result, _, _ = run_status(tmp_path, wakefulness="Asleep")
    assert result.returncode == 0
    assert result.stdout.startswith("free: asleep")


@pytest.mark.parametrize("wakefulness", ["Awake", "Asleep"])
def test_status_never_wakes_or_presses_anything(tmp_path, wakefulness):
    _, adb_calls, wol = run_status(tmp_path, wakefulness=wakefulness)
    assert wol == []
    assert not any("input" in call for call in adb_calls)


def test_status_off_the_network_says_what_the_router_saw(tmp_path):
    result, _, wol = run_status(
        tmp_path,
        ping_up=False,
        router_reply=f"neigh {HOST} dev br-guest FAILED \nassoc no\nlease no\n",
    )
    assert result.returncode == 2
    assert result.stdout.startswith("off the network:")
    assert "not associated" in result.stdout
    assert "no DHCP lease" in result.stdout
    assert wol == []


def test_status_reachable_without_adb_is_not_called_off(tmp_path):
    result, _, _ = run_status(tmp_path, adb_state="unauthorized")
    assert result.returncode == 3
    assert result.stdout.startswith("on the network, adb unauthorized")


def test_status_stamps_the_time_it_measured(tmp_path):
    result, _, _ = run_status(tmp_path)
    assert "measured " in result.stdout


# Where the projector is. Its address has moved three times (192.168.8.100,
# 192.168.9.100 on 2026-09-13, 192.168.8.100 again by 2026-11-04), and each move
# broke a default written into the script. So the script resolves the name, and
# takes the router's address on whichever /24 the projector is on.


def run_moved(tmp_path: Path, resolved: str | None, extra_env: dict[str, str] | None = None):
    """Run the script with the projector off the network and the router up."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _getent(bin_dir, resolved)
    log = tmp_path / "log"
    log.mkdir()
    _stub(
        bin_dir,
        "ping",
        f'echo "$*" >> {log}/ping\nhost="${{@: -1}}"\n'
        '[ "$host" = "192.168.8.1" ] || [ "$host" = "192.168.9.1" ] && exit 0\nexit 1\n',
    )
    _stub(bin_dir, "ssh", f'echo "$*" >> {log}/ssh\nprintf "neigh \\nassoc no\\n"\n')
    _stub(bin_dir, "sleep", "exit 0\n")
    _stub(bin_dir, "python3", f'echo "$*" >> {log}/python3\ncat >/dev/null\nexit 0\n')
    _stub(bin_dir, "adb", f'echo "$*" >> {log}/adb\nexit 0\n')
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), **(extra_env or {})}
    result = subprocess.run(
        ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60
    )

    def lines(name: str) -> list[str]:
        path = log / name
        return path.read_text().splitlines() if path.exists() else []

    return result, lines("ping"), lines("ssh"), lines("adb")


def test_the_address_comes_from_dns_and_the_router_from_the_same_subnet(tmp_path):
    result, pings, ssh_calls, adb_calls = run_moved(tmp_path, "192.168.8.100")
    assert any(call.endswith(" 192.168.8.100") for call in pings)
    assert any(call.endswith(" 192.168.8.1") for call in pings)
    assert not any("192.168.9." in call for call in pings + ssh_calls + adb_calls)
    assert "ip -4 neigh show 192.168.8.100" in "\n".join(ssh_calls)


def test_a_name_that_does_not_resolve_stops_before_touching_anything(tmp_path):
    result, pings, ssh_calls, adb_calls = run_moved(tmp_path, None)
    assert result.returncode == 2
    assert "projector-london.viktorbarzin.lan does not resolve" in result.stderr
    assert pings == ssh_calls == adb_calls == []


def test_an_explicit_host_skips_dns(tmp_path):
    result, pings, _, _ = run_moved(tmp_path, None, {"PROJECTOR_HOST": "192.168.9.100"})
    assert any(call.endswith(" 192.168.9.100") for call in pings)
    assert any(call.endswith(" 192.168.9.1") for call in pings)
    assert "does not resolve" not in result.stderr
