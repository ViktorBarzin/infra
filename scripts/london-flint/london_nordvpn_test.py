"""The London Flint's NordVPN tunnel for media players: `scripts/london-flint/london-nordvpn.sh`.

The projector (role `media`) sends all its internet traffic through a NordVPN
WireGuard tunnel, so BitTorrent never leaves through the Flint's WAN in the
clear. The script keeps the kill switch in the firewall and renews the tunnel
when its handshake goes stale.

These tests run the real script under busybox sh, the shell the router has,
with stand-ins for `curl`, `wg`, `uci`, `ifup`, `jsonfilter`, `ipset`,
`iptables`, `ip6tables` and `logger` on PATH. Each stand-in appends its
arguments to a log file, so nothing touches the network or the firewall.
"""

from __future__ import annotations

import shutil
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent / "london-nordvpn.sh"
BUSYBOX = shutil.which("busybox")
NOW = 1_800_000_000

CREDENTIALS = '{"nordlynx_private_key": "PRIVKEY="}'
SERVERS = "uk1808.nordvpn.com|194.35.233.217|PUBKEY="


@dataclass
class Env:
    root: Path
    log: Path
    run_dir: Path
    env: dict[str, str]

    def calls(self, tool: str) -> list[str]:
        if not self.log.exists():
            return []
        prefix = tool + " "
        return [line[len(prefix):] for line in self.log.read_text().splitlines() if line.startswith(prefix)]

    def run(self, *args: str, now: int = NOW, check: bool = True) -> subprocess.CompletedProcess[str]:
        assert BUSYBOX is not None
        return subprocess.run(
            [BUSYBOX, "sh", str(SCRIPT), *args],
            env={**self.env, "NV_NOW": str(now)},
            capture_output=True,
            text=True,
            check=check,
            timeout=20,
        )

    def handshake(self, value: str | None) -> None:
        """What `wg show nordvpn latest-handshakes` prints; None means no interface."""
        path = self.root / "handshake"
        if value is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(f"PUBKEY=\t{value}\n")

    def refreshed(self, at: int) -> None:
        self.run_dir.mkdir(exist_ok=True)
        (self.run_dir / "refreshed").write_text(f"{at}\n")


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text("#!" + str(BUSYBOX) + " sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.fixture
def env(tmp_path: Path) -> Env:
    if BUSYBOX is None:
        pytest.skip("busybox is not installed")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "calls.log"
    for tool in ("ipset", "logger", "ifup", "uci"):
        _stub(bin_dir, tool, f'echo "{tool} $*" >> "{log}"\n')
    # iptables/ip6tables: -C (check) finds nothing, so every hook gets added.
    for tool in ("iptables", "ip6tables"):
        _stub(bin_dir, tool, f'echo "{tool} $*" >> "{log}"\nfor a in "$@"; do [ "$a" = -C ] && exit 1; done\nexit 0\n')
    handshake = tmp_path / "handshake"
    _stub(bin_dir, "wg", f'[ -f "{handshake}" ] || exit 1\ncat "{handshake}"\n')
    # curl: credentials and server list answer from files, with a status code
    # from $CURL_CODE (default 200), the way `-w '\\n%{{http_code}}'` prints it.
    _stub(
        bin_dir,
        "curl",
        f'echo "curl $*" >> "{log}"\n'
        'case "$*" in\n'
        f'  *credentials*) cat "{tmp_path}/credentials" ;;\n'
        f'  *recommendations*) cat "{tmp_path}/servers" ;;\n'
        "esac\n"
        'printf "\\n%s" "${CURL_CODE:-200}"\n',
    )
    # jsonfilter: the router's JSON tool. The stand-in answers the three
    # expressions the script uses from a "host|station|key" line.
    _stub(
        bin_dir,
        "jsonfilter",
        'in=$(cat)\n'
        'case "$2" in\n'
        "  @.nordlynx_private_key) echo \"$in\" | sed -n 's/.*\"nordlynx_private_key\": \"\\([^\"]*\\)\".*/\\1/p' ;;\n"
        "  '@[0].hostname') echo \"$in\" | cut -d'|' -f1 ;;\n"
        "  '@[0].station') echo \"$in\" | cut -d'|' -f2 ;;\n"
        "  *public_key*) echo \"$in\" | cut -d'|' -f3 ;;\n"
        "esac\n",
    )
    for tool in ("awk", "cat", "mkdir", "rm", "cut", "date", "grep", "sed", "printf", "head", "tail"):
        target = bin_dir / tool
        if not target.exists():
            target.symlink_to(BUSYBOX)
    (tmp_path / "credentials").write_text(CREDENTIALS)
    (tmp_path / "servers").write_text(SERVERS)
    token = tmp_path / "token"
    token.write_text("nord-token\n")
    run_dir = tmp_path / "run"
    e = {
        "PATH": str(bin_dir),
        "NV_TOKEN_FILE": str(token),
        "NV_RUN": str(run_dir),
        "NV_IFUP": str(bin_dir / "ifup"),
        "NV_LOGGER": str(bin_dir / "logger"),
    }
    return Env(root=tmp_path, log=log, run_dir=run_dir, env=e)


# ---------------------------------------------------------------- refresh


def test_refresh_writes_the_key_and_server_then_brings_the_tunnel_up(env: Env) -> None:
    env.run("refresh")
    uci = env.calls("uci")
    assert "set network.nordvpn.private_key=PRIVKEY=" in uci
    assert "set network.nordvpn_server.public_key=PUBKEY=" in uci
    assert "set network.nordvpn_server.endpoint_host=194.35.233.217" in uci
    assert "commit network" in uci
    assert env.calls("ifup") == ["nordvpn"]
    assert (env.run_dir / "refreshed").read_text().strip() == str(NOW)
    assert any("uk1808.nordvpn.com" in line for line in env.calls("logger"))


def test_refresh_asks_for_a_bulgarian_wireguard_server(env: Env) -> None:
    env.run("refresh")
    server_call = [c for c in env.calls("curl") if "recommendations" in c][0]
    assert "filters[country_id]=33" in server_call
    assert "wireguard_udp" in server_call
    assert "-g" in server_call.split()  # brackets in the URL are not curl globs


@pytest.mark.parametrize("code", ["401", "403", "429"])
def test_a_refusal_stops_the_refresh_and_backs_off_for_an_hour(env: Env, code: str) -> None:
    env.env["CURL_CODE"] = code
    assert env.run("refresh", check=False).returncode != 0
    assert len(env.calls("curl")) == 1  # stops at the first refusal
    assert env.calls("ifup") == []
    assert (env.run_dir / "backoff").read_text().strip() == str(NOW + 3600)
    # Within the hour nothing calls NordVPN again.
    env.env["CURL_CODE"] = "200"
    env.run("refresh", now=NOW + 1800, check=False)
    assert len(env.calls("curl")) == 1


def test_an_empty_answer_changes_nothing(env: Env) -> None:
    (env.root / "servers").write_text("")
    assert env.run("refresh", check=False).returncode != 0
    assert not any(c.startswith("set ") for c in env.calls("uci"))
    assert env.calls("ifup") == []


# ---------------------------------------------------------------- watchdog


def test_a_fresh_handshake_needs_nothing(env: Env) -> None:
    env.refreshed(NOW - 3600)
    env.handshake(str(NOW - 60))
    env.run("watchdog")
    assert env.calls("curl") == []


def test_a_stale_handshake_renews_the_tunnel(env: Env) -> None:
    env.refreshed(NOW - 3600)
    env.handshake(str(NOW - 301))
    env.run("watchdog")
    assert env.calls("ifup") == ["nordvpn"]


def test_no_handshake_after_three_minutes_renews_the_tunnel(env: Env) -> None:
    env.refreshed(NOW - 3600)
    env.handshake("0")
    env.run("watchdog")
    assert env.calls("ifup") == ["nordvpn"]


def test_a_missing_interface_renews_the_tunnel(env: Env) -> None:
    env.refreshed(NOW - 3600)
    env.handshake(None)
    env.run("watchdog")
    assert env.calls("ifup") == ["nordvpn"]


def test_no_renewal_within_ten_minutes_of_the_last_one(env: Env) -> None:
    # NordVPN refuses an over-limit reconnect for about ten minutes.
    env.refreshed(NOW - 599)
    env.handshake("0")
    env.run("watchdog")
    assert env.calls("curl") == []


def test_after_a_reboot_the_first_run_only_starts_the_clock(env: Env) -> None:
    # /tmp is empty after a reboot while the tunnel is still coming up.
    env.handshake("0")
    env.run("watchdog")
    assert env.calls("curl") == []
    assert (env.run_dir / "refreshed").read_text().strip() == str(NOW)


# ---------------------------------------------------------------- firewall


def test_apply_marks_media_players_for_the_tunnel(env: Env) -> None:
    env.run("apply")
    assert "create lr_media hash:mac -exist" in env.calls("ipset")
    assert any(
        c.startswith("-t mangle -I PREROUTING") and "lr_media" in c and "--set-xmark 0x10000/0x10000" in c
        for c in env.calls("iptables")
    )


@pytest.mark.parametrize("tool", ["iptables", "ip6tables"])
def test_the_kill_switch_lets_media_players_out_only_through_the_tunnel(env: Env, tool: str) -> None:
    env.run("apply")
    rules = [c for c in env.calls(tool) if c.startswith("-A london_nordvpn")]
    assert rules[:4] == [f"-A london_nordvpn -o {dev} -j RETURN" for dev in ("nordvpn", "wgclient1", "br-lan", "br-guest")]
    assert rules[-1] == "-A london_nordvpn -j REJECT"
    assert "-A forwarding_lan_rule -m set --match-set lr_media src -j london_nordvpn" in env.calls(tool)


@pytest.mark.parametrize("tool", ["iptables", "ip6tables"])
def test_bittorrent_flagged_by_dpi_never_leaves_through_the_wan(env: Env, tool: str) -> None:
    # netifyd marks BitTorrent flows with connmark bit 0x1000000 (action
    # london-bittorrent). From any London device they may go only into a tunnel
    # or the LANs; out of the WAN they are rejected.
    env.run("apply")
    calls = env.calls(tool)
    rules = [c for c in calls if c.startswith("-A london_bittorrent")]
    assert rules[:4] == [f"-A london_bittorrent -o {dev} -j RETURN" for dev in ("nordvpn", "wgclient1", "br-lan", "br-guest")]
    assert rules[-1] == "-A london_bittorrent -j REJECT"
    # Hooked first in FORWARD, before the ESTABLISHED accept: a flow is only
    # recognised a few packets in, when it is already established.
    assert "-I FORWARD 1 -m connmark --mark 0x1000000/0x1000000 -j london_bittorrent" in calls
