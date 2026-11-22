"""The London Flint's role agent: `scripts/london-flint/london-roles.sh`.

The agent keeps London device roles (docs/plans/2026-11-22-london-network-roles-design.md)
in ipsets keyed by MAC. It long-polls the wifi app for the role list, saves the
list on the router, swaps fresh ipsets in, and sends the DHCP lease table when
the app asks for it.

These tests run the real script under busybox sh, the shell the router has,
with stand-ins for `curl`, `ipset`, `iptables`, `conntrack` and `logger` on
PATH. Each stand-in appends its arguments to a log file, so nothing touches
the network or the firewall.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent / "london-roles.sh"
BUSYBOX = shutil.which("busybox")

LEASES = (
    "43200 aa:aa:aa:aa:aa:01 192.168.8.126 mbp-london 01:aa\n"
    "43200 AA:AA:AA:AA:AA:02 192.168.8.118 * *\n"
)
LEASE_BODY = "aa:aa:aa:aa:aa:01 192.168.8.126 mbp-london\naa:aa:aa:aa:aa:02 192.168.8.118 *\n"


@dataclass
class Env:
    root: Path
    log: Path
    list_file: Path
    env: dict[str, str]

    def calls(self, tool: str) -> list[str]:
        if not self.log.exists():
            return []
        prefix = tool + " "
        return [line[len(prefix):] for line in self.log.read_text().splitlines() if line.startswith(prefix)]

    def run(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        assert BUSYBOX is not None
        return subprocess.run(
            [BUSYBOX, "sh", str(SCRIPT), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=check,
            timeout=20,
        )


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
    for tool in ("ipset", "conntrack", "logger"):
        _stub(bin_dir, tool, f'echo "{tool} $*" >> "{log}"\n')
    # iptables: -C (check) finds nothing, so the hooks get inserted.
    _stub(bin_dir, "iptables", f'echo "iptables $*" >> "{log}"\n[ "$1" = -C ] && exit 1\nexit 0\n')
    # curl: record the call; answer from $CURL_REPLY (body) with $CURL_CODE.
    _stub(
        bin_dir,
        "curl",
        f'echo "curl $*" >> "{log}"\n'
        'for a in "$@"; do case "$a" in @*) cp "${a#@}" "$CURL_SENT";; esac; done\n'
        '[ -n "$CURL_REPLY" ] && cat "$CURL_REPLY"\n'
        'printf "\\n%s" "${CURL_CODE:-200}"\n',
    )
    for tool in ("sha256sum", "sort", "awk", "cat", "mv", "mkdir", "rm", "cut", "date", "tr", "grep", "sed", "printf", "cmp", "sleep"):
        target = bin_dir / tool
        if not target.exists():
            target.symlink_to(BUSYBOX)
    leases = tmp_path / "dhcp.leases"
    leases.write_text(LEASES)
    token = tmp_path / "token"
    token.write_text("secret-token\n")
    conf = tmp_path / "conf"
    conf.write_text("LR_URL=https://wifi.example\nLR_MODE=log\n")
    list_file = tmp_path / "roles.list"
    run_dir = tmp_path / "run"
    e = {
        "PATH": str(bin_dir),
        "LR_CONF": str(conf),
        "LR_TOKEN_FILE": str(token),
        "LR_LIST": str(list_file),
        "LR_LEASES": str(leases),
        "LR_RUN": str(run_dir),
        "CURL_SENT": str(tmp_path / "sent"),
    }
    return Env(root=tmp_path, log=log, list_file=list_file, env=e)


def reply(env: Env, body: str, code: int = 200) -> None:
    path = env.root / "reply"
    path.write_text(body)
    env.env["CURL_REPLY"] = str(path)
    env.env["CURL_CODE"] = str(code)


def test_lease_hash_is_sha256_of_the_lease_body(env: Env) -> None:
    out = env.run("leases-body").stdout
    assert out == LEASE_BODY
    assert env.run("leases-hash").stdout.strip() == hashlib.sha256(LEASE_BODY.encode()).hexdigest()


def test_new_version_is_saved_and_swapped_into_the_ipsets(env: Env) -> None:
    reply(env, "version 7\nleases ok\naa:aa:aa:aa:aa:01 admin\naa:aa:aa:aa:aa:02 iot\n")
    env.run("once")
    assert env.list_file.read_text() == "version 7\naa:aa:aa:aa:aa:01 admin\naa:aa:aa:aa:aa:02 iot\n"
    ipset = env.calls("ipset")
    assert "add lr_admin_new aa:aa:aa:aa:aa:01 -exist" in ipset
    assert "add lr_iot_new aa:aa:aa:aa:aa:02 -exist" in ipset
    assert "swap lr_admin_new lr_admin" in ipset
    assert "swap lr_storage_new lr_storage" in ipset
    assert "destroy lr_admin_new" in ipset


def test_poll_sends_version_and_lease_hash(env: Env) -> None:
    env.list_file.write_text("version 3\naa:aa:aa:aa:aa:01 admin\n")
    reply(env, "unchanged 3\nleases ok\n")
    env.run("once")
    (call,) = [c for c in env.calls("curl") if "/api/router/roles" in c]
    digest = hashlib.sha256(LEASE_BODY.encode()).hexdigest()
    assert f"https://wifi.example/api/router/roles?since=3&leases={digest}" in call
    assert "Authorization: Bearer secret-token" in call


def test_unchanged_writes_nothing_and_touches_no_ipset(env: Env) -> None:
    env.list_file.write_text("version 3\naa:aa:aa:aa:aa:01 admin\n")
    before = env.list_file.stat().st_mtime_ns
    reply(env, "unchanged 3\nleases ok\n")
    env.run("once")
    assert env.list_file.stat().st_mtime_ns == before
    assert env.calls("ipset") == []
    assert (env.root / "run" / "lastsync").exists()


def test_leases_needed_puts_the_lease_body(env: Env) -> None:
    reply(env, "unchanged 0\nleases needed\n")
    env.run("once")
    puts = [c for c in env.calls("curl") if "/api/router/leases" in c]
    assert len(puts) == 1
    assert "-X PUT" in puts[0]
    assert (env.root / "sent").read_text() == LEASE_BODY


def test_a_device_that_loses_its_role_loses_its_sofia_connections(env: Env) -> None:
    env.list_file.write_text("version 3\naa:aa:aa:aa:aa:01 admin\naa:aa:aa:aa:aa:02 iot\n")
    reply(env, "version 4\nleases ok\naa:aa:aa:aa:aa:02 iot\n")
    env.run("once")
    deletes = env.calls("conntrack")
    assert "-D -s 192.168.8.126 -d 10.0.0.0/8" in deletes
    assert not any("192.168.8.118" in d for d in deletes)


def test_an_error_reply_changes_nothing_and_fails(env: Env) -> None:
    env.list_file.write_text("version 3\naa:aa:aa:aa:aa:01 admin\n")
    reply(env, "nope", code=401)
    result = env.run("once", check=False)
    assert result.returncode != 0
    assert env.list_file.read_text() == "version 3\naa:aa:aa:aa:aa:01 admin\n"
    assert env.calls("ipset") == []
    assert not (env.root / "run" / "lastsync").exists()


def test_a_malformed_role_line_is_refused(env: Env) -> None:
    env.list_file.write_text("version 3\naa:aa:aa:aa:aa:01 admin\n")
    reply(env, "version 4\nleases ok\nnot-a-mac admin\n")
    assert env.run("once", check=False).returncode != 0
    assert env.list_file.read_text() == "version 3\naa:aa:aa:aa:aa:01 admin\n"


def test_apply_at_boot_loads_the_saved_list(env: Env) -> None:
    env.list_file.write_text("version 9\naa:aa:aa:aa:aa:01 storage\n")
    env.run("apply")
    assert "add lr_storage_new aa:aa:aa:aa:aa:01 -exist" in env.calls("ipset")


def rules(env: Env) -> list[str]:
    return [c for c in env.calls("iptables") if c.startswith("-A london_roles")]


def test_log_mode_logs_and_lets_everything_through(env: Env) -> None:
    env.run("firewall")
    r = rules(env)
    assert "-A london_roles -m set --match-set lr_admin src -j RETURN" in r
    assert "-A london_roles -m set --match-set lr_storage src -d 192.168.1.13 -p tcp --dport 445 -j RETURN" in r
    assert "-A london_roles -d 10.0.20.215 -p tcp --dport 443 -j RETURN" in r
    assert any("LOG --log-prefix london-roles-would-block:" in x for x in r)
    assert not any("REJECT" in x for x in r)


def test_enforce_mode_rejects_after_logging(env: Env) -> None:
    (env.root / "conf").write_text("LR_URL=https://wifi.example\nLR_MODE=enforce\n")
    env.run("firewall")
    r = rules(env)
    assert any("LOG --log-prefix london-roles-blocked:" in x for x in r)
    assert r[-1] == "-A london_roles -j REJECT --reject-with icmp-admin-prohibited"


def test_firewall_hooks_lan_and_guest_traffic_to_the_tunnel(env: Env) -> None:
    env.run("firewall")
    calls = env.calls("iptables")
    assert "-I forwarding_lan_rule -o wgclient1 -j london_roles" in calls
    assert "-I forwarding_guest_rule -o wgclient1 -j london_roles" in calls
