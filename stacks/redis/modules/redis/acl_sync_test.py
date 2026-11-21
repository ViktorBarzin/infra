"""Tests for redis-acl-sync and the redis-v2 ACL init container (B40 R1).

Run: python3 -m pytest stacks/redis/modules/redis/acl_sync_test.py -q

The unit tests need nothing. The integration tests start their own
redis:8.10.3-alpine container (the production image) and are skipped when
docker is not available.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from typing import cast

import pytest

import acl_sync
from acl_sync import ADMIN_USER, DEFAULT_USER_LINE, Redis, SyncError

HERE = Path(__file__).parent
USERS = json.loads((HERE / "acl_users.json").read_text())
IMAGE = "docker.io/library/redis:8.10.3-alpine"


def fake_passwords(users: dict[str, str] = USERS, salt: str = "a") -> dict[str, str]:
    # Vault also holds default's password (for R4, and for rybbit, which can
    # send only a password), which is not a users.json user.
    return {u: hashlib.sha256(f"{salt}:{u}".encode()).hexdigest()[:40] for u in [*users, "default"]}


# --- unit ----------------------------------------------------------------------


def test_render_has_default_and_every_user_with_hashes_only():
    pw = fake_passwords()
    desired = acl_sync.render(USERS, pw)
    assert set(desired) == {"default", *USERS}
    assert desired["default"].line == DEFAULT_USER_LINE
    for name, user in desired.items():
        if name == "default":
            continue
        digest = hashlib.sha256(pw[name].encode()).hexdigest()
        assert user.line == f"user {name} on sanitize-payload #{digest} {USERS[name]}"
        assert pw[name] not in user.line
        assert pw[name] not in " ".join(user.setuser_args)


def test_render_keeps_default_open_while_vault_holds_its_password():
    # Until R4 the default line stays nopass; its Vault password is only
    # carried (rybbit sends it, and Redis ignores it for a nopass default).
    pw = fake_passwords()
    desired = acl_sync.render(USERS, pw)
    assert desired["default"].line == DEFAULT_USER_LINE
    assert desired["default"].password is None
    for user in desired.values():
        assert pw["default"] not in user.line
        assert pw["default"] not in " ".join(user.setuser_args)


CLIENTS = (
    "id=3 addr=10.0.0.1:1 laddr=10.0.0.9:6379 fd=8 name= user=default lib-name=\n"
    "id=4 addr=10.0.0.2:1 laddr=10.0.0.1:6379 fd=9 name=x user=immich\n"
    "id=5 addr=10.0.0.3:1 laddr=10.0.0.1:6379 fd=10 name=y user=default\n"
    "id=6 addr=10.0.0.1:2 laddr=10.0.0.9:6379 fd=11 name= user=default\n"
)


def test_count_default_outside_ignores_allowed_pods_and_laddr():
    # 10.0.0.1 is a rybbit pod. laddr= is Redis's own side and must not match.
    assert acl_sync.count_default_outside(CLIENTS, {"10.0.0.1"}) == 1
    assert acl_sync.count_default_outside(CLIENTS, set()) == 3


def test_default_outside_describes_each_unexpected_client():
    clients = (
        "id=3 addr=10.0.0.1:1 laddr=10.0.0.9:6379 fd=8 name= age=9 idle=0 flags=N db=0 cmd=get user=default lib-name=\n"
        "id=5 addr=10.0.0.3:41000 laddr=10.0.0.1:6379 fd=10 name=worker age=120 idle=7 flags=N db=0 "
        "sub=0 psub=0 qbuf=0 argv-mem=0 tot-mem=1 cmd=hgetall user=default redir=-1 resp=2 lib-name=redis-py lib-ver=5.0\n"
        "id=6 addr=[fd00::7]:2 laddr=10.0.0.9:6379 fd=11 age=1 idle=1 cmd=ping user=default\n"
        "id=7 addr=10.0.0.4:1 laddr=10.0.0.1:6379 fd=12 name=x age=1 idle=1 cmd=get user=immich\n"
    )
    found = acl_sync.default_outside(clients, {"10.0.0.1"})
    assert [c.ip for c in found] == ["10.0.0.3", "fd00::7"]
    assert found[0].fields == {
        "addr": "10.0.0.3:41000", "name": "worker", "age": "120", "idle": "7",
        "cmd": "hgetall", "lib-name": "redis-py", "lib-ver": "5.0",
    }
    # Missing fields print as empty, never fall back to laddr= or other keys.
    assert found[1].fields["addr"] == "[fd00::7]:2"
    assert found[1].fields["name"] == ""
    assert acl_sync.count_default_outside(clients, {"10.0.0.1"}) == 2


def test_default_outside_line_is_bounded_and_has_only_the_named_fields():
    long_name = "n" * 300
    clients = f"id=5 addr=10.0.0.3:1 laddr=x fd=1 name={long_name} age=1 idle=1 cmd=get user=default qbuf=99\n"
    (client,) = acl_sync.default_outside(clients, set())
    line = acl_sync.describe_unexpected(client)
    assert line == "unexpected default client: addr=10.0.0.3:1 name=" + "n" * 64 + " age=1 idle=1 cmd=get lib-name= lib-ver="
    assert "qbuf" not in line and "laddr" not in line and "n" * 65 not in line


def test_pod_ips_from_a_pod_list():
    doc = {"items": [
        {"status": {"podIP": "10.0.0.1", "podIPs": [{"ip": "10.0.0.1"}, {"ip": "fd00::1"}]}},
        {"status": {"podIP": "10.0.0.7"}},
        {"status": {}},
    ]}
    assert acl_sync.pod_ips_from_list(doc) == {"10.0.0.1", "fd00::1", "10.0.0.7"}


class ClientListRedis:
    """Answers AUTH and CLIENT LIST; the run stops at ACL LIST."""

    def call(self, *args: str) -> object:
        if args[:2] == ("CLIENT", "LIST"):
            return CLIENTS
        if args[:2] == ("ACL", "LIST"):
            raise acl_sync.RedisError("NOPERM fake")
        return "OK"

    def close(self) -> None:
        pass


def test_run_counts_default_clients_outside_the_allowed_namespaces():
    result = acl_sync.run(USERS, fake_passwords, lambda: cast(Redis, ClientListRedis()), lambda: {"10.0.0.1"})
    assert result.counts["default"] == 3
    assert result.default_unexpected == 1
    assert result.default_lookup_error == ""


def test_run_counts_every_default_client_when_the_pod_lookup_fails():
    # Fail towards a red R3 gate: without the pod list no default client is
    # known to be rybbit's.
    def broken() -> set[str]:
        raise SyncError("Kubernetes API refused: HTTPError 403")

    result = acl_sync.run(USERS, fake_passwords, lambda: cast(Redis, ClientListRedis()), broken)
    assert result.default_unexpected == 3
    assert "403" in result.default_lookup_error


@pytest.mark.parametrize(
    "mutate, message",
    [
        (lambda u, p: p.pop("immich"), "no key for: immich"),
        (lambda u, p: p.pop("default"), "no key for: default"),
        (lambda u, p: p.update({"default": "short"}), "default is empty or malformed"),
        (lambda u, p: p.update({"stranger": "x" * 40}), "does not name: stranger"),
        (lambda u, p: p.update({"tv": ""}), "tv is empty or malformed"),
        (lambda u, p: p.update({"tv": "short"}), "tv is empty or malformed"),
        (lambda u, p: p.update({"tv": "has spaces and symbols !!!!!!!!!!!!!!!!!!"}), "malformed"),
        (lambda u, p: (u.pop(ADMIN_USER), p.pop(ADMIN_USER)), "no acl-admin"),
        (lambda u, p: u.update({ADMIN_USER: "resetchannels -@all +ping"}), r"must keep \+acl"),
        (lambda u, p: (u.update({"default": "~* +@all"}), p.update({"default": "y" * 40})), "must not name default"),
        (lambda u, p: (u.update({"Bad_Name": "~* +@all"}), p.update({"Bad_Name": "y" * 40})), "bad user name"),
        (lambda u, p: u.update({"tv": "~* +@all >password"}), "not allowed"),
        (lambda u, p: u.update({"tv": "~* +@all nopass"}), "not allowed"),
        (lambda u, p: u.update({"tv": ""}), "has no rules"),
    ],
)
def test_render_fails_closed_on_broken_input(mutate, message):
    users, pw = dict(USERS), fake_passwords()
    mutate(users, pw)
    with pytest.raises(SyncError, match=message):
        acl_sync.render(users, pw)


def test_render_refuses_a_render_without_the_default_line(monkeypatch):
    monkeypatch.setattr(acl_sync, "default_user", lambda: acl_sync.User("default", ["reset", "off"], "user default off"))
    with pytest.raises(SyncError, match="lacks the default user line"):
        acl_sync.render(USERS, fake_passwords())


def test_plan_is_empty_when_redis_matches():
    desired = acl_sync.render(USERS, fake_passwords())
    current = {n: u.line for n, u in desired.items()}
    assert acl_sync.plan(current, desired) == []


def test_plan_sets_changed_users_and_deletes_strays_but_never_default_or_admin():
    desired = acl_sync.render(USERS, fake_passwords())
    current = {n: u.line for n, u in desired.items()}
    current["immich"] = "user immich on sanitize-payload #00 ~* &* +@all"
    current["stray"] = "user stray on nopass ~* +@all"
    del current["tv"]
    commands = acl_sync.plan(current, desired)
    assert ["ACL", "SETUSER", "immich", *desired["immich"].setuser_args] in commands
    assert ["ACL", "SETUSER", "tv", *desired["tv"].setuser_args] in commands
    assert commands[-1] == ["ACL", "DELUSER", "stray"]
    assert len(commands) == 3
    assert acl_sync.plan({"default": "x", ADMIN_USER: "y"}, {}) == []


def test_count_clients_by_user():
    text = (
        "id=3 addr=10.0.0.1:1 laddr=10.0.0.9:6379 fd=8 name= user=default lib-name=\n"
        "id=4 addr=10.0.0.2:1 laddr=10.0.0.9:6379 fd=9 name=x user=immich\n"
        "id=5 addr=10.0.0.3:1 laddr=10.0.0.9:6379 fd=10 name=y user=default\n"
    )
    assert acl_sync.count_clients(text) == {"default": 2, "immich": 1}


def test_metrics_text():
    body = acl_sync.metrics_text({"a_seconds": 1.5}, {"redis_clients_by_user": {"tv": 2.0, "default": 1.0}})
    assert body == (
        "# TYPE a_seconds gauge\na_seconds 1.5\n"
        "# TYPE redis_clients_by_user gauge\n"
        'redis_clients_by_user{user="default"} 1.0\n'
        'redis_clients_by_user{user="tv"} 2.0\n'
    )


def test_vault_unreachable_touches_nothing():
    def fail() -> dict[str, str]:
        raise SyncError("Vault unreachable or refused: URLError")

    def no_redis() -> Redis:
        raise AssertionError("must not connect")

    result = acl_sync.run(USERS, fail, no_redis)
    assert not result.ok
    assert "Vault unreachable" in result.error


def test_vault_passwords_unreachable_raises_sync_error(tmp_path):
    jwt = tmp_path / "token"
    jwt.write_text("x")
    with pytest.raises(SyncError, match="Vault unreachable"):
        acl_sync.vault_passwords("http://127.0.0.1:9", "r", "secret/data/redis/users", str(jwt), timeout=2)


# --- integration: a real redis:8.10.3 ------------------------------------------


def docker_ok() -> bool:
    if shutil.which("docker") is None:
        return False
    return subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True).returncode == 0


needs_docker = pytest.mark.skipif(not docker_ok(), reason=f"docker or {IMAGE} not available")


def seed_text(admin_password: str) -> str:
    """What acl.tf writes into the redis-acl-seed Secret."""
    digest = hashlib.sha256(admin_password.encode()).hexdigest()
    return f"user default on nopass ~* &* +@all\nuser {ADMIN_USER} on #{digest} {USERS[ADMIN_USER]}\n"


class RedisBox:
    """One Redis container shaped like redis-v2: aclfile on the data volume,
    the init script run before each start, root-less for a clean tmp_path."""

    def __init__(self, tmp: Path) -> None:
        self.tmp = tmp
        self.data = tmp / "data"
        self.data.mkdir()
        (tmp / "seed").mkdir()
        (tmp / "redis.conf").write_text("port 6379\ndir /data\naclfile /data/acl/users.acl\nappendonly no\nsave \"\"\n")
        self.name = f"b40-acl-test-{uuid.uuid4().hex[:8]}"
        self.port = 0

    def docker(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["docker", *args], capture_output=True, text=True, check=check)

    def user(self) -> str:
        return f"{os.getuid()}:{os.getgid()}"

    def init(self, admin_password: str) -> str:
        (self.tmp / "seed" / "users.acl").write_text(seed_text(admin_password))
        out = self.docker(
            "run", "--rm", "--user", self.user(), "--entrypoint", "sh",
            "-v", f"{self.data}:/data", "-v", f"{self.tmp / 'seed'}:/seed:ro",
            "-v", f"{HERE / 'acl_init.sh'}:/init.sh:ro", IMAGE, "/init.sh",
        )
        return out.stdout

    def start(self) -> None:
        self.docker(
            "run", "-d", "--name", self.name, "--user", self.user(), "--entrypoint", "redis-server",
            "-v", f"{self.data}:/data", "-v", f"{self.tmp / 'redis.conf'}:/etc/redis/redis.conf:ro",
            "-p", "127.0.0.1::6379", IMAGE, "/etc/redis/redis.conf",
        )
        mapping = self.docker("port", self.name, "6379/tcp").stdout.split()[0]
        self.port = int(mapping.rsplit(":", 1)[1])
        for _ in range(50):
            try:
                c = self.connect()
                c.call("PING")
                c.close()
                return
            except (OSError, ConnectionError, acl_sync.RedisError):
                time.sleep(0.1)
        raise RuntimeError(self.docker("logs", self.name, check=False).stdout)

    def stop(self) -> None:
        self.docker("rm", "-f", self.name, check=False)

    def connect(self) -> Redis:
        return Redis("127.0.0.1", self.port, timeout=5)

    def acl_list(self) -> list[str]:
        c = self.connect()
        try:
            reply = c.call("ACL", "LIST")
            assert isinstance(reply, list)
            return [str(x) for x in reply]
        finally:
            c.close()

    def as_user(self, name: str, password: str, *command: str) -> object:
        c = self.connect()
        try:
            c.call("AUTH", name, password)
            return c.call(*command)
        finally:
            c.close()


@pytest.fixture
def box(tmp_path):
    b = RedisBox(tmp_path)
    yield b
    b.stop()


def sync(box: RedisBox, passwords: dict[str, str], users: dict[str, str] = USERS) -> acl_sync.Result:
    return acl_sync.run(users, lambda: dict(passwords), box.connect)


@needs_docker
def test_redis_will_not_start_without_its_aclfile(box):
    # Depending on timing, docker port fails (CalledProcessError, IndexError)
    # or the PING loop gives up (RuntimeError); each means it did not start.
    with pytest.raises((subprocess.CalledProcessError, RuntimeError, IndexError)):
        box.start()
        time.sleep(0.5)
        box.docker("exec", box.name, "true")
    logs = box.docker("logs", box.name, check=False)
    assert "Error loading ACLs" in logs.stdout + logs.stderr


@needs_docker
def test_seed_then_sync_creates_every_user_without_disturbing_default(box):
    pw = fake_passwords()
    assert "seeded" in box.init(pw[ADMIN_USER])
    box.start()
    assert box.acl_list()[-1] == DEFAULT_USER_LINE

    held = box.connect()  # a client on the default user, like every consumer today
    assert held.call("PING") == "PONG"

    result = sync(box, pw)
    assert result.ok, result.error
    assert result.changes == len(USERS) - 1  # acl-admin already came from the seed
    assert result.auth == {u: 1.0 for u in USERS}
    assert result.counts.get(ADMIN_USER) == 1
    assert result.counts.get("default", 0) >= 1

    desired = acl_sync.render(USERS, pw)
    assert sorted(box.acl_list()) == sorted(u.line for u in desired.values())
    assert held.call("PING") == "PONG"
    held.close()

    saved = (box.data / "acl" / "users.acl").read_text()
    assert sorted(saved.splitlines()) == sorted(u.line for u in desired.values())
    assert not any(p in saved for p in pw.values())

    again = sync(box, pw)
    assert again.ok and again.changes == 0


@needs_docker
def test_restricted_users_get_only_their_commands(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok

    def denied(name: str, *command: str) -> None:
        with pytest.raises(acl_sync.RedisError, match="NOPERM"):
            box.as_user(name, pw[name], *command)

    assert box.as_user("probe", pw["probe"], "PING") == "PONG"
    denied("probe", "GET", "k")
    denied("probe", "INFO")
    assert "redis_version" in str(box.as_user("exporter", pw["exporter"], "INFO", "server"))
    assert box.as_user("exporter", pw["exporter"], "CONFIG", "GET", "maxmemory")
    denied("exporter", "GET", "k")
    denied("exporter", "CONFIG", "SET", "maxmemory", "1")
    denied("exporter", "CLIENT", "KILL", "ID", "1")
    assert "started" in str(box.as_user("backup", pw["backup"], "BGSAVE"))
    denied("backup", "GET", "k")
    denied(ADMIN_USER, "GET", "k")
    denied(ADMIN_USER, "FLUSHALL")
    assert box.as_user("immich", pw["immich"], "SET", "k", "v") == "OK"
    assert box.as_user("tv", pw["tv"], "GET", "k") == "v"
    assert box.as_user("verify", pw["verify"], "SELECT", "15") == "OK"
    with pytest.raises(acl_sync.RedisError, match="WRONGPASS"):
        box.as_user("immich", pw["tv"], "PING")


@needs_docker
def test_backup_user_runs_the_backup_jobs_commands(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok
    out = box.docker(
        "run", "--rm", "--network", "host", "-e", f"REDISCLI_AUTH={pw['backup']}", "--entrypoint", "sh", IMAGE, "-c",
        f"redis-cli -p {box.port} --user backup BGSAVE; sleep 1; redis-cli -p {box.port} --user backup --rdb /tmp/x.rdb",
    )
    assert "Transfer finished with success" in out.stdout + out.stderr
    log = box.as_user(ADMIN_USER, pw[ADMIN_USER], "ACL", "LOG")
    assert log == []


@needs_docker
def test_a_refused_login_falls_back_to_default_and_the_backup_check_sees_it(box):
    # redis-cli carries on as default after a refused AUTH and exits 0, so
    # the redis-backup job compares the PING output with "PONG" (main.tf).
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok
    check = f'login=$(redis-cli -p {box.port} --no-auth-warning --user backup PING 2>&1); [ "$login" = PONG ]; echo "rc=$?"'
    good = box.docker("run", "--rm", "--network", "host", "-e", f"REDISCLI_AUTH={pw['backup']}", "--entrypoint", "sh", IMAGE, "-c", check)
    bad = box.docker("run", "--rm", "--network", "host", "-e", "REDISCLI_AUTH=wrong", "--entrypoint", "sh", IMAGE, "-c", check)
    whoami = box.docker("run", "--rm", "--network", "host", "-e", "REDISCLI_AUTH=wrong", "--entrypoint", "sh", IMAGE, "-c",
                        f"redis-cli -p {box.port} --no-auth-warning --user verify ACL WHOAMI; echo rc=$?")
    assert good.stdout.strip().endswith("rc=0")
    assert bad.stdout.strip().endswith("rc=1")
    assert "default" in whoami.stdout and "rc=0" in whoami.stdout


@needs_docker
def test_probe_script_pings_as_the_probe_user(box):
    # probe.sh is the liveness and readiness command of the redis container
    # (main.tf). It must answer PONG as `probe`, not as `default`, so the R3
    # count sees no default client from the kubelet.
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok
    out = box.docker(
        "run", "--rm", "--network", "host", "-e", f"REDIS_PROBE_PASSWORD={pw['probe']}",
        "-e", f"REDISCLI_PORT={box.port}",
        "-v", f"{HERE / 'probe.sh'}:/probe.sh:ro", "--entrypoint", "sh", IMAGE, "-c",
        # The production probe talks to localhost:6379; here only the port differs.
        "sed \"s/redis-cli /redis-cli -p $REDISCLI_PORT /\" /probe.sh > /tmp/p.sh && sh /tmp/p.sh",
    )
    assert out.stdout.strip() == "PONG"
    assert pw["probe"] not in out.stdout + out.stderr
    assert box.as_user(ADMIN_USER, pw[ADMIN_USER], "ACL", "LOG") == []


@needs_docker
@pytest.mark.parametrize(
    "broken",
    [
        lambda p: p.pop("tv"),
        lambda p: p.update({"extra": "z" * 40}),
        lambda p: p.update({"immich": ""}),
    ],
)
def test_broken_vault_document_changes_nothing(box, broken):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    before = box.acl_list()
    bad = dict(pw)
    broken(bad)
    result = sync(box, bad)
    assert not result.ok
    assert box.acl_list() == before
    assert result.counts  # the counter still reported


@needs_docker
def test_unknown_user_is_removed_and_changed_password_is_applied(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok
    box.as_user(ADMIN_USER, pw[ADMIN_USER], "ACL", "SETUSER", "stray", "on", "nopass", "~*", "+@all")
    rotated = dict(pw, immich="N" * 40)
    result = sync(box, rotated)
    assert result.ok, result.error
    assert result.changes == 2
    assert not any(line.startswith("user stray ") for line in box.acl_list())
    assert box.as_user("immich", "N" * 40, "PING") == "PONG"


@needs_docker
def test_restart_keeps_users_and_init_refreshes_acl_admin(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok
    box.stop()

    new_admin = "M" * 40
    assert "kept" in box.init(new_admin)
    box.start()
    assert box.as_user("tv", pw["tv"], "PING") == "PONG"  # survived the restart
    assert box.as_user(ADMIN_USER, new_admin, "PING") == "PONG"
    lines = box.acl_list()
    assert sum(line.startswith(f"user {ADMIN_USER} ") for line in lines) == 1
    assert DEFAULT_USER_LINE in lines
    result = sync(box, dict(pw, **{ADMIN_USER: new_admin}))
    assert result.ok and result.changes == 0


@needs_docker
def test_seed_matches_redis_normal_form(box):
    """The seed's acl-admin line, once loaded, prints as the render's line."""
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    desired = acl_sync.render(USERS, pw)
    assert desired[ADMIN_USER].line in box.acl_list()



@needs_docker
def test_every_run_saves_so_a_lost_save_heals(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    assert sync(box, pw).ok
    acl_file = box.data / "acl" / "users.acl"
    acl_file.write_text("user default on nopass ~* &* +@all\n")  # as if SAVE never ran
    result = sync(box, pw)
    assert result.ok and result.changes == 0
    desired = acl_sync.render(USERS, pw)
    assert sorted(acl_file.read_text().splitlines()) == sorted(u.line for u in desired.values())


@needs_docker
def test_partial_exec_is_reported_and_saved(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    users = dict(USERS, tv="~* &* +@all +nosuchcommand")
    result = sync(box, pw, users)
    assert not result.ok
    assert "partial" in result.error
    # The users Redis accepted are applied and saved; the next good run heals the rest.
    saved = (box.data / "acl" / "users.acl").read_text()
    assert "user immich " in saved
    assert sync(box, pw).ok


@needs_docker
def test_unexpected_default_client_line_from_a_real_client_list_holds_no_secret(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    stranger = box.connect()  # a client on default from an address no rybbit pod has
    stranger.call("CLIENT", "SETNAME", "stranger")
    stranger.call("SET", "k", pw["immich"])  # a secret in a command's arguments
    result = acl_sync.run(USERS, lambda: dict(pw), box.connect, set)
    stranger.close()
    found = [c for c in result.default_unexpected_clients if c.fields["name"] == "stranger"]
    assert len(found) == 1
    line = acl_sync.describe_unexpected(found[0])
    assert " cmd=set " in line
    assert found[0].fields["age"].isdigit() and found[0].fields["idle"].isdigit()
    assert not any(p in line for p in pw.values())


@needs_docker
def test_counts_report_zero_for_idle_users(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    result = sync(box, pw)
    assert set(result.counts) >= {"default", *USERS}
    assert result.counts["immich"] == 0
    assert result.counts[ADMIN_USER] == 1


def test_counts_report_zero_even_when_the_render_fails():
    class FakeRedis:
        def call(self, *args: str) -> object:
            if args[:2] == ("CLIENT", "LIST"):
                return "id=1 addr=1.2.3.4:5 user=default\n"
            return "OK"

        def close(self) -> None:
            pass

    bad = fake_passwords()
    bad.pop("tv")
    result = acl_sync.run(USERS, lambda: bad, lambda: cast(Redis, FakeRedis()))
    assert not result.ok
    assert result.counts["default"] == 1
    assert result.counts["tv"] == 0
