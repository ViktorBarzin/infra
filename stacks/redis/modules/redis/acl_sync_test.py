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


# --- Cloud Key Value tenants (B27) ----------------------------------------------


def tenant_entry(project: str = "shop", service: str = "cache", password: str = "t" * 32, max_bytes: int = 16 * 1048576) -> dict[str, object]:
    readable = f"{project}_{service}".replace("-", "_")
    digest = hashlib.sha256(f"{project}/{service}".encode()).hexdigest()[:10]
    return {
        "user": f"p_{readable}_{digest}",
        "passwordSha256": hashlib.sha256(password.encode()).hexdigest(),
        "prefix": f"p:{project}:{service}:",
        "maxBytes": max_bytes,
        "project": project,
        "service": service,
    }


def answer(*tenants: dict[str, object], purge: list[dict[str, str]] | None = None) -> dict[str, object]:
    return {"version": 1, "tenants": list(tenants), "purge": purge or []}


def test_parse_tenant_answer_accepts_the_contract_shape():
    t = tenant_entry()
    parsed = acl_sync.parse_tenant_answer(answer(t, purge=[{"prefix": "p:old:cache:", "project": "old", "service": "cache"}]))
    (tenant,) = parsed.tenants
    assert tenant.name == t["user"] and tenant.prefix == "p:shop:cache:" and tenant.max_bytes == 16 * 1048576
    assert (tenant.project, tenant.service) == ("shop", "cache")
    assert parsed.purge == ["p:old:cache:"]


@pytest.mark.parametrize(
    "mutate, message",
    [
        (lambda a, t: t.update({"user": "P_shop"}), "bad tenant user"),
        (lambda a, t: t.update({"user": "p_shop cache"}), "bad tenant user"),
        (lambda a, t: t.update({"user": "immich"}), "bad tenant user"),
        (lambda a, t: t.update({"passwordSha256": "x" * 64}), "bad password hash"),
        (lambda a, t: t.update({"prefix": "p:shop:*"}), "bad prefix"),
        (lambda a, t: t.update({"prefix": "p:other:cache:"}), "does not match its project and service"),
        (lambda a, t: t.update({"maxBytes": True}), "bad maxBytes"),
        (lambda a, t: t.update({"maxBytes": 0}), "bad maxBytes"),
        (lambda a, t: t.update({"maxBytes": "16"}), "bad maxBytes"),
        (lambda a, t: a.update({"version": 2}), "version"),
        (lambda a, t: a.update({"tenants": "x"}), "tenants"),
        (lambda a, t: a["tenants"].append(dict(t)), "twice"),
        (lambda a, t: a["tenants"].append({**tenant_entry("shop", "other"), "prefix": t["prefix"], "service": "cache"}), "twice"),
    ],
)
def test_parse_tenant_answer_rejects_a_bad_answer(mutate, message):
    a = answer(tenant_entry())
    mutate(a, a["tenants"][0])
    with pytest.raises(SyncError, match=message):
        acl_sync.parse_tenant_answer(a)


def test_parse_tenant_answer_drops_a_purge_entry_for_a_live_prefix():
    t = tenant_entry()
    parsed = acl_sync.parse_tenant_answer(answer(t, purge=[{"prefix": "p:shop:cache:", "project": "shop", "service": "cache"}]))
    assert parsed.purge == []
    assert parsed.warnings and "live tenant" in parsed.warnings[0]


def test_tenant_lines_follow_the_template_and_redis_normal_form():
    tenant = acl_sync.parse_tenant_answer(answer(tenant_entry())).tenants[0]
    normal = acl_sync.tenant_user(tenant, full=False)
    digest = tenant.password_sha256
    assert normal.line == (
        f"user {tenant.name} on sanitize-payload #{digest} ~p:shop:cache:* resetchannels &p:shop:cache:* "
        "-@all +@read +@write +@keyspace +@hash +@list +@set +@sortedset +@stream +@string +@pubsub "
        "+@transaction +@scripting +@connection -@dangerous -select -scan -randomkey -function -script|flush "
        "-move -copy -script|kill -dbsize -pubsub|channels -pubsub|shardchannels -pubsub|numsub "
        "-pubsub|shardnumsub -pubsub|numpat"
    )
    assert normal.setuser_args[:7] == ["reset", "on", f"#{digest}", "resetkeys", "~p:shop:cache:*", "resetchannels", "&p:shop:cache:*"]
    full = acl_sync.tenant_user(tenant, full=True)
    assert "+@write" not in full.line and "+del" in full.line and "+unlink" in full.line
    assert normal.password is None and full.password is None


def test_tenants_from_acl_keeps_template_users_and_their_mode():
    t = acl_sync.parse_tenant_answer(answer(tenant_entry())).tenants[0]
    other = acl_sync.parse_tenant_answer(answer(tenant_entry("b", "kv"))).tenants[0]
    current = {
        t.name: acl_sync.tenant_user(t, full=False).line,
        other.name: acl_sync.tenant_user(other, full=True).line,
        "p_rogue": "user p_rogue on sanitize-payload #" + "0" * 64 + " ~* &* +@all",
        "immich": "user immich on sanitize-payload #" + "0" * 64 + " ~* &* +@all",
    }
    kept = acl_sync.tenants_from_acl(current)
    assert {k.name: (k.prefix, k.project, k.service, k.password_sha256) for k in kept} == {
        t.name: ("p:shop:cache:", "shop", "cache", t.password_sha256),
        other.name: ("p:b:kv:", "b", "kv", other.password_sha256),
    }
    assert acl_sync.full_users(current) == {other.name}


def test_foreign_users_are_neither_infra_nor_tenants():
    t = acl_sync.parse_tenant_answer(answer(tenant_entry())).tenants[0]
    # A tenant Cloud dropped still matches the template: not foreign; the
    # run deletes it like any user nobody wants.
    stale = acl_sync.parse_tenant_answer(answer(tenant_entry("stale", "kv"))).tenants[0]
    current = {
        "default": DEFAULT_USER_LINE,
        "immich": "user immich ...",
        t.name: acl_sync.tenant_user(t, full=False).line,
        stale.name: acl_sync.tenant_user(stale, full=False).line,
        "p_rogue": "user p_rogue on sanitize-payload #" + "0" * 64 + " ~* &* +@all",
        "mallory": "user mallory on nopass ~* &* +@all",
    }
    assert acl_sync.foreign_users(current, set(USERS), {t.name}) == ["mallory", "p_rogue"]


def test_key_prefix():
    assert acl_sync.key_prefix("p:shop:cache:a:b") == "p:shop:cache:"
    assert acl_sync.key_prefix("p:shop:cache:") == "p:shop:cache:"
    assert acl_sync.key_prefix("p:shop") is None
    assert acl_sync.key_prefix("x:shop:cache:a") is None


def test_measure_due_every_five_minutes():
    assert acl_sync.measure_due(1_800_000_000 - 1_800_000_000 % 300)
    assert not acl_sync.measure_due(1_800_000_000 - 1_800_000_000 % 300 + 60)


def test_fetch_tenant_answer_sends_the_bearer_and_fails_closed(tmp_path):
    import http.server
    import threading

    seen: list[str] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            seen.append(self.headers.get("Authorization", ""))
            if self.headers.get("Authorization") != "Bearer good":
                self.send_response(401)
                self.end_headers()
                return
            body = json.dumps(answer(tenant_entry())).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args: object) -> None:
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/internal/redis-tenants"
    try:
        assert acl_sync.fetch_tenant_answer(url, "good")["version"] == 1
        with pytest.raises(SyncError, match="401"):
            acl_sync.fetch_tenant_answer(url, "bad")
        with pytest.raises(SyncError, match="no token"):
            acl_sync.fetch_tenant_answer(url, "")
    finally:
        server.shutdown()
    assert seen == ["Bearer good", "Bearer bad"]


def test_kv_metrics_text_labels_project_and_service():
    body = acl_sync.kv_metrics_text(
        {"cloud_kv_tenants_fetch_ok": 1.0},
        {"cloud_kv_ready": {("shop", "cache"): 1.0}},
    )
    assert body == (
        "# TYPE cloud_kv_tenants_fetch_ok gauge\ncloud_kv_tenants_fetch_ok 1.0\n"
        "# TYPE cloud_kv_ready gauge\n"
        'cloud_kv_ready{project="shop",service="cache"} 1.0\n'
    )


# --- tenants against a real redis:8.10.3 -----------------------------------------


def tenant_sync(box: RedisBox, pw: dict[str, str], fetch, measure: bool = False) -> acl_sync.Result:
    return acl_sync.run(USERS, lambda: dict(pw), box.connect, set, fetch_tenants=fetch, measure=measure)


def tenant_conn(box: RedisBox, entry: dict[str, object], password: str = "t" * 32) -> Redis:
    c = box.connect()
    c.call("AUTH", str(entry["user"]), password)
    return c


def refused(conn: Redis, *command: str) -> str:
    with pytest.raises(acl_sync.RedisError) as info:
        conn.call(*command)
    return str(info.value)


@pytest.fixture
def tenant_box(box):
    pw = fake_passwords()
    box.init(pw[ADMIN_USER])
    box.start()
    return box, pw


@needs_docker
def test_tenant_rules_confine_a_tenant_to_its_prefix(tenant_box):
    box, pw = tenant_box
    a, b = tenant_entry("shop", "cache"), tenant_entry("other", "cache", password="u" * 32)
    result = tenant_sync(box, pw, lambda: answer(a, b))
    assert result.ok, result.error
    assert result.kv_ready == {("shop", "cache"): 1.0, ("other", "cache"): 1.0}
    held = tenant_conn(box, a)
    counted = tenant_sync(box, pw, lambda: answer(a, b))
    held.close()
    assert counted.kv_connections == {("shop", "cache"): 1.0, ("other", "cache"): 0.0}
    acl = {line.split()[1]: line for line in box.acl_list()}
    assert acl[str(a["user"])] == acl_sync.tenant_user(acl_sync.parse_tenant_answer(answer(a)).tenants[0], full=False).line

    c = tenant_conn(box, a)
    try:
        assert c.call("SET", "p:shop:cache:k", "1") == "OK"
        assert c.call("GET", "p:shop:cache:k") == "1"
        assert "NOPERM" in refused(c, "GET", "p:other:cache:k")
        assert "NOPERM" in refused(c, "SET", "immich-key", "x")
        for command in (["KEYS", "*"], ["SELECT", "1"], ["FLUSHALL"], ["FLUSHDB"], ["SCAN", "0"], ["RANDOMKEY"],
                        ["CONFIG", "GET", "maxmemory"], ["SCRIPT", "FLUSH"], ["FUNCTION", "FLUSH"], ["ACL", "LIST"],
                        ["MONITOR"], ["CLIENT", "KILL", "ID", "1"], ["INFO"],
                        # Out of db 0 or the prefix: never measured, purged or evicted.
                        ["MOVE", "p:shop:cache:k", "1"], ["COPY", "p:shop:cache:k", "p:shop:cache:k2", "DB", "1"],
                        ["COPY", "p:shop:cache:k", "p:shop:cache:k3"], ["SWAPDB", "0", "1"],
                        ["RESTORE", "p:shop:cache:r", "0", "x"], ["MIGRATE", "127.0.0.1", "6380", "p:shop:cache:k", "0", "100"],
                        ["SORT", "p:shop:cache:k", "STORE", "p:other:cache:s"],
                        # Other tenants' traffic and the size of db 0.
                        ["SCRIPT", "KILL"], ["DBSIZE"], ["PUBSUB", "CHANNELS"], ["PUBSUB", "SHARDCHANNELS"],
                        ["PUBSUB", "NUMSUB", "p:other:cache:chan"], ["PUBSUB", "SHARDNUMSUB", "x"], ["PUBSUB", "NUMPAT"]):
            assert "NOPERM" in refused(c, *command), command
        for command in (["LMOVE", "p:shop:cache:k", "p:other:cache:l", "LEFT", "LEFT"],
                        ["SUNIONSTORE", "p:other:cache:s", "p:shop:cache:k"],
                        ["RENAME", "p:shop:cache:k", "p:other:cache:k"]):
            assert "NOPERM" in refused(c, *command), command
        assert c.call("EXISTS", "p:shop:cache:k") == 1
        # BullMQ's way: SCRIPT LOAD, then EVALSHA on declared keys.
        sha = c.call("SCRIPT", "LOAD", "return redis.call('INCR', KEYS[1])")
        assert c.call("EVALSHA", str(sha), "1", "p:shop:cache:bull:n") == 1
        assert "NOPERM" in refused(c, "EVALSHA", str(sha), "1", "p:other:cache:n")
        assert c.call("PUBLISH", "p:shop:cache:chan", "hi") == 0
        assert "NOPERM" in refused(c, "PUBLISH", "p:other:cache:chan", "hi")
        assert c.call("MULTI") == "OK"
        c.call("SET", "p:shop:cache:m", "1")
        assert c.call("EXEC") == ["OK"]
    finally:
        c.close()
    s = tenant_conn(box, a)
    try:
        assert s.call("SUBSCRIBE", "p:shop:cache:chan") == ["subscribe", "p:shop:cache:chan", 1]
    finally:
        s.close()
    s = tenant_conn(box, a)
    try:
        assert "NOPERM" in refused(s, "SUBSCRIBE", "p:other:cache:chan")
    finally:
        s.close()


@needs_docker
def test_full_tenant_reads_and_deletes_but_cannot_write_until_under_again(tenant_box):
    box, pw = tenant_box
    a = tenant_entry(max_bytes=64 * 1024)
    assert tenant_sync(box, pw, lambda: answer(a)).ok
    c = tenant_conn(box, a)
    for i in range(20):
        c.call("SET", f"p:shop:cache:fill{i}", "x" * 8192)
    c.close()

    measured = tenant_sync(box, pw, lambda: answer(a), measure=True)
    assert measured.ok, measured.error
    assert measured.kv_keys[("shop", "cache")] == 20.0
    assert measured.kv_bytes[("shop", "cache")] > 64 * 1024
    assert measured.kv_full == {("shop", "cache"): 1.0}

    c = tenant_conn(box, a)
    try:
        assert c.call("GET", "p:shop:cache:fill0") == "x" * 8192
        assert c.call("EXISTS", "p:shop:cache:fill1") == 1
        assert "NOPERM" in refused(c, "SET", "p:shop:cache:new", "1")
        assert "NOPERM" in refused(c, "EVAL", "return 1", "0")
        for command in (["MOVE", "p:shop:cache:fill0", "1"], ["COPY", "p:shop:cache:fill0", "p:shop:cache:c", "DB", "1"],
                        ["SCRIPT", "KILL"], ["DBSIZE"], ["PUBSUB", "NUMPAT"], ["SCRIPT", "LOAD", "return 1"]):
            assert "NOPERM" in refused(c, *command), command
        # A run between measurements keeps the full rule set.
        between = tenant_sync(box, pw, lambda: answer(a))
        assert between.ok and between.kv_full == {("shop", "cache"): 1.0}
        assert "NOPERM" in refused(c, "SET", "p:shop:cache:new", "1")
        for i in range(20):
            assert c.call("DEL", f"p:shop:cache:fill{i}") == 1
    finally:
        c.close()

    again = tenant_sync(box, pw, lambda: answer(a), measure=True)
    assert again.ok and again.kv_full == {("shop", "cache"): 0.0}
    assert again.kv_bytes[("shop", "cache")] == 0.0
    c = tenant_conn(box, a)
    try:
        assert c.call("SET", "p:shop:cache:new", "1") == "OK"
    finally:
        c.close()


@needs_docker
def test_a_failed_fetch_keeps_the_tenants_and_a_vanished_tenant_keeps_its_keys(tenant_box):
    box, pw = tenant_box
    a, b = tenant_entry("shop", "cache"), tenant_entry("b", "kv")
    assert tenant_sync(box, pw, lambda: answer(a, b)).ok
    c = tenant_conn(box, b)
    c.call("SET", "p:b:kv:k", "1")
    c.close()

    def down() -> dict[str, object]:
        raise SyncError("Cloud tenants route unreachable: URLError")

    kept = tenant_sync(box, pw, down, measure=True)
    assert kept.ok, kept.error
    assert kept.tenants_fetch_ok is False and "unreachable" in kept.tenants_error
    assert kept.kv_ready == {("shop", "cache"): 1.0, ("b", "kv"): 1.0}
    names = {line.split()[1] for line in box.acl_list()}
    assert {a["user"], b["user"]} <= names

    gone = tenant_sync(box, pw, lambda: answer(a), measure=True)
    assert gone.ok and gone.tenants_fetch_ok is True
    assert b["user"] not in {line.split()[1] for line in box.acl_list()}
    assert box.as_user("verify", pw["verify"], "EXISTS", "p:b:kv:k") == 1


@needs_docker
def test_purge_deletes_only_after_the_user_is_gone_and_never_a_live_prefix(tenant_box):
    box, pw = tenant_box
    a, b = tenant_entry("shop", "cache"), tenant_entry("b", "kv")
    assert tenant_sync(box, pw, lambda: answer(a, b)).ok
    for entry, key in ((a, "p:shop:cache:k"), (b, "p:b:kv:k")):
        c = tenant_conn(box, entry)
        c.call("SET", key, "1")
        c.close()
    purge_b = [{"prefix": "p:b:kv:", "project": "b", "service": "kv"}]
    purge_a = [{"prefix": "p:shop:cache:", "project": "shop", "service": "cache"}]

    # b still has its user in Redis at the start of this run: its keys stay,
    # the user goes.
    first = tenant_sync(box, pw, lambda: answer(a, purge=purge_b), measure=True)
    assert first.ok, first.error
    assert first.purged == 0
    assert box.as_user("verify", pw["verify"], "EXISTS", "p:b:kv:k") == 1
    # A purge entry for a's live prefix is ignored.
    second = tenant_sync(box, pw, lambda: answer(a, purge=purge_b + purge_a), measure=True)
    assert second.ok, second.error
    assert second.purged == 1
    assert box.as_user("verify", pw["verify"], "EXISTS", "p:b:kv:k") == 0
    assert box.as_user("verify", pw["verify"], "EXISTS", "p:shop:cache:k") == 1
    # A purge between measurements does nothing.
    c = tenant_conn(box, a)
    c.call("SET", "p:shop:cache:j", "1")
    c.close()


@needs_docker
def test_foreign_user_is_counted_and_removed(tenant_box):
    box, pw = tenant_box
    assert tenant_sync(box, pw, lambda: answer()).ok
    box.as_user(ADMIN_USER, pw[ADMIN_USER], "ACL", "SETUSER", "mallory", "on", "nopass", "~*", "+@all")
    result = tenant_sync(box, pw, lambda: answer())
    assert result.ok, result.error
    assert result.foreign_users == ["mallory"]
    assert "mallory" not in {line.split()[1] for line in box.acl_list()}
    assert tenant_sync(box, pw, lambda: answer()).foreign_users == []


@needs_docker
def test_measurement_cost_stays_bounded_per_tenant(tenant_box, monkeypatch):
    box, pw = tenant_box
    monkeypatch.setattr(acl_sync, "MEMORY_SAMPLE_PER_TENANT", 50)
    a = tenant_entry(max_bytes=1 << 30)
    assert tenant_sync(box, pw, lambda: answer(a)).ok
    c = tenant_conn(box, a)
    for i in range(0, 400, 100):
        c.call("MSET", *[x for j in range(i, i + 100) for x in (f"p:shop:cache:{j}", "v" * 100)])
    c.close()
    result = tenant_sync(box, pw, lambda: answer(a), measure=True)
    assert result.ok, result.error
    assert result.kv_keys[("shop", "cache")] == 400.0
    assert result.memory_usage_calls == 50
    # Extrapolated from 50 equal keys: within 10% of 8 x the sample.
    assert 300 * 100 < result.kv_bytes[("shop", "cache")] < 400 * 400


@needs_docker
def test_a_list_cannot_hide_its_size_from_the_measurement(tenant_box):
    # MEMORY USAGE samples 5 elements of a list by default; SAMPLES 0 reads
    # them all, so small first elements hide nothing.
    box, pw = tenant_box
    a = tenant_entry(max_bytes=256 * 1024)
    assert tenant_sync(box, pw, lambda: answer(a)).ok
    c = tenant_conn(box, a)
    c.call("RPUSH", "p:shop:cache:l", *["a"] * 10)
    for _ in range(4):
        c.call("RPUSH", "p:shop:cache:l", *["x" * 4096] * 25)
    c.close()
    measured = tenant_sync(box, pw, lambda: answer(a), measure=True)
    assert measured.ok, measured.error
    assert measured.kv_bytes[("shop", "cache")] > 400 * 1024
    assert measured.kv_full == {("shop", "cache"): 1.0}


@needs_docker
def test_measurement_runs_after_the_acl_and_its_fault_fails_nothing(tenant_box, monkeypatch):
    box, pw = tenant_box
    a = tenant_entry()

    def broken(*args: object) -> acl_sync.Usage:
        raise OSError("connection reset during SCAN")

    monkeypatch.setattr(acl_sync, "measure", broken)
    result = tenant_sync(box, pw, lambda: answer(a), measure=True)
    assert result.ok, result.error
    assert "connection reset" in result.measure_error
    assert result.auth == {u: 1.0 for u in USERS}
    assert result.kv_ready == {("shop", "cache"): 1.0}
    assert not result.measured


@needs_docker
def test_memory_usage_calls_are_capped_per_run(tenant_box, monkeypatch):
    box, pw = tenant_box
    monkeypatch.setattr(acl_sync, "MEMORY_USAGE_PER_RUN", 30)
    a, b = tenant_entry("shop", "cache"), tenant_entry("b", "kv")
    assert tenant_sync(box, pw, lambda: answer(a, b)).ok
    for entry, prefix in ((a, "p:shop:cache:"), (b, "p:b:kv:")):
        c = tenant_conn(box, entry)
        c.call("MSET", *[x for j in range(40) for x in (f"{prefix}{j}", "v")])
        c.close()
    result = tenant_sync(box, pw, lambda: answer(a, b), measure=True)
    assert result.ok, result.error
    assert result.memory_usage_calls == 30
    assert result.kv_keys == {("shop", "cache"): 40.0, ("b", "kv"): 40.0}
