"""Tests for physical-node-tether, run against fake system commands.

    python3 -m pytest playbooks/files/physical-node/test_physical_node_tether.py

Every command the script calls (curl, cryptsetup, clevis, mount, umount,
mountpoint, systemctl, crictl, pkill, fuser, date, sleep) is a fake on PATH.
The fakes keep a tiny "world" in files and append each call to calls.log, so a
test sets the world up, runs the script once, and reads what it did.
"""

import os
import subprocess
import textwrap
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent / "physical-node-tether"

BINDS = ["/etc/kubernetes", "/var/lib/kubelet", "/var/lib/containerd"]

FAKES = {
    # Tang answers when world/tang-up exists.
    "curl": '[ -e "$W/tang-up" ]',
    "date": 'cat "$W/now"',
    "sleep": "true",
    "crictl": "true",
    "pkill": "true",
    "fuser": "true",
    # cryptsetup status <name> -> 0 when open; close <name> -> closed.
    "cryptsetup": textwrap.dedent("""\
        case "$1" in
          status) [ -e "$W/open" ] ;;
          close) rm -f "$W/open" ;;
        esac"""),
    # clevis luks unlock -d DEV -n NAME -> open, unless world/unlock-fails.
    "clevis": '[ -e "$W/unlock-fails" ] && exit 1; touch "$W/open"',
    "mountpoint": 'grep -qxF "${@: -1}" "$W/mounted"',
    "mount": 'echo "$1" >> "$W/mounted"',
    "umount": textwrap.dedent("""\
        t="${@: -1}"
        grep -vxF "$t" "$W/mounted" > "$W/mounted.new"; mv "$W/mounted.new" "$W/mounted\""""),
    # systemctl show -p ActiveState --value UNIT -> world/unit-state.UNIT or inactive.
    "systemctl": textwrap.dedent("""\
        if [ "$1" = show ]; then
          f="$W/unit-state.${@: -1}"
          [ -e "$f" ] && cat "$f" || echo inactive
        elif [ "$1" = stop ] && [ "$2" = systemd-cryptsetup@state.service ]; then
          rm -f "$W/open"
        fi"""),
}


class World:
    def __init__(self, root: Path):
        self.root = root
        self.dir = root / "world"
        self.dir.mkdir()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in FAKES.items():
            fake = bin_dir / name
            fake.write_text(
                "#!/bin/bash\n"
                f'echo "{name} $*" >> "$W/calls.log"\n'
                f"{body}\n"
            )
            fake.chmod(0o755)
        (self.dir / "mounted").write_text("")
        (self.dir / "calls.log").write_text("")
        self.state_dir = root / "run"
        self.conf = root / "tether.conf"
        self.conf.write_text(textwrap.dedent(f"""\
            TANG_URL=http://tang.test
            STATE_DEVICE=/dev/fake0p1
            STATE_NAME=state
            STATE_MOUNT=/var/lib/state
            BIND_TARGETS="{' '.join(BINDS)}"
            TETHER_UNITS="containerd.service kubelet.service"
            TETHER_GRACE_SECONDS=600
            """))
        self.env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "W": str(self.dir),
            "TETHER_CONF": str(self.conf),
            "TETHER_STATE_DIR": str(self.state_dir),
        }
        self.at(1_000_000)

    def at(self, now: int) -> None:
        (self.dir / "now").write_text(f"{now}\n")

    def tang(self, up: bool) -> None:
        flag = self.dir / "tang-up"
        flag.touch() if up else flag.unlink(missing_ok=True)

    def volume(self, open_: bool, mounted: bool) -> None:
        flag = self.dir / "open"
        flag.touch() if open_ else flag.unlink(missing_ok=True)
        lines = ["/var/lib/state", *BINDS] if mounted else []
        (self.dir / "mounted").write_text("".join(f"{m}\n" for m in lines))

    def unit_state(self, unit: str, state: str) -> None:
        (self.dir / f"unit-state.{unit}").write_text(state + "\n")

    def run(self) -> subprocess.CompletedProcess:
        (self.dir / "calls.log").write_text("")
        return subprocess.run(["bash", str(SCRIPT)], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def calls(self) -> list[str]:
        return (self.dir / "calls.log").read_text().splitlines()

    def actions(self) -> list[str]:
        """Calls that change something, in order."""
        keep = ("systemctl start", "systemctl stop", "mount ", "umount ",
                "cryptsetup close", "clevis luks unlock")
        return [c for c in self.calls() if c.startswith(keep)]

    def is_open(self) -> bool:
        return (self.dir / "open").exists()

    def mounted(self) -> list[str]:
        return (self.dir / "mounted").read_text().split()


@pytest.fixture
def world(tmp_path):
    return World(tmp_path)


def test_tang_up_and_volume_in_use_does_nothing(world):
    world.tang(True)
    world.volume(open_=True, mounted=True)
    r = world.run()
    assert r.returncode == 0, r.stderr
    assert world.actions() == []


def test_first_failure_is_recorded_and_nothing_closes(world):
    world.tang(False)
    world.volume(open_=True, mounted=True)
    r = world.run()
    assert r.returncode == 0, r.stderr
    assert world.actions() == []
    assert world.is_open()
    assert (world.state_dir / "first-failure").read_text().strip() == "1000000"


def test_nine_minutes_of_failure_keeps_the_volume_open(world):
    world.tang(False)
    world.volume(open_=True, mounted=True)
    world.run()
    world.at(1_000_000 + 540)
    world.run()
    assert world.actions() == []
    assert world.is_open()


def test_ten_minutes_of_failure_closes_the_volume_in_order(world):
    world.tang(False)
    world.volume(open_=True, mounted=True)
    world.run()
    world.at(1_000_000 + 600)
    r = world.run()
    assert r.returncode == 0, r.stderr
    actions = world.actions()
    # kubelet stops before containerd, binds unmount before the volume, close last.
    assert actions[0] == "systemctl stop kubelet.service"
    assert actions[1] == "systemctl stop containerd.service"
    umounts = [a for a in actions if a.startswith("umount")]
    assert umounts[-1].endswith("/var/lib/state")
    assert actions[-1] == "cryptsetup close state"
    assert not world.is_open()
    assert world.mounted() == []
    assert "closing" in r.stdout.lower()


def test_close_goes_through_systemd_when_systemd_opened_it(world):
    world.tang(False)
    world.volume(open_=True, mounted=True)
    world.unit_state("systemd-cryptsetup@state.service", "active")
    world.run()
    world.at(1_000_000 + 600)
    world.run()
    assert world.actions()[-1] == "systemctl stop systemd-cryptsetup@state.service"
    assert "cryptsetup close state" not in world.calls()
    assert not world.is_open()


def test_tang_down_and_volume_closed_does_nothing(world):
    world.tang(False)
    world.volume(open_=False, mounted=False)
    world.run()
    world.at(1_000_000 + 3600)
    r = world.run()
    assert r.returncode == 0, r.stderr
    assert world.actions() == []


def test_tang_back_reopens_mounts_and_starts_units_in_order(world):
    world.tang(True)
    world.volume(open_=False, mounted=False)
    (world.state_dir).mkdir()
    (world.state_dir / "first-failure").write_text("1\n")
    r = world.run()
    assert r.returncode == 0, r.stderr
    assert world.actions() == [
        "clevis luks unlock -d /dev/fake0p1 -n state",
        "mount /var/lib/state",
        *[f"mount {b}" for b in BINDS],
        "systemctl start containerd.service",
        "systemctl start kubelet.service",
    ]
    assert world.is_open()
    assert not (world.state_dir / "first-failure").exists()


def test_open_but_unmounted_volume_is_mounted_without_unlocking(world):
    # Boot: Clevis opened the volume after the mount jobs had already timed out.
    world.tang(True)
    world.volume(open_=True, mounted=False)
    r = world.run()
    assert r.returncode == 0, r.stderr
    actions = world.actions()
    assert not any(a.startswith("clevis") for a in actions)
    assert actions[0] == "mount /var/lib/state"
    assert actions[-1] == "systemctl start kubelet.service"


def test_boot_time_unlock_in_progress_is_left_alone(world):
    world.tang(True)
    world.volume(open_=False, mounted=False)
    world.unit_state("systemd-cryptsetup@state.service", "activating")
    r = world.run()
    assert r.returncode == 0, r.stderr
    assert world.actions() == []


def test_a_recovery_restarts_the_ten_minute_count(world):
    world.tang(False)
    world.volume(open_=True, mounted=True)
    world.run()                      # first failure at t=0
    world.at(1_000_000 + 300)
    world.tang(True)
    world.run()                      # Tang back at 5 min
    world.tang(False)
    world.at(1_000_000 + 360)
    world.run()                      # fails again at 6 min: new count starts
    world.at(1_000_000 + 900)
    world.run()                      # 9 min into the new count
    assert world.is_open()
    assert world.actions() == []


def test_failed_unlock_starts_nothing(world):
    world.tang(True)
    world.volume(open_=False, mounted=False)
    (world.dir / "unlock-fails").touch()
    r = world.run()
    assert r.returncode != 0
    assert not any(a.startswith(("mount", "systemctl start")) for a in world.actions())
