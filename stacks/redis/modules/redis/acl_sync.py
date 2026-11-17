"""redis-acl-sync: keep the shared Redis's ACL users equal to the desired set.

Runs every minute as the CronJob redis-acl-sync in namespace redis
(stacks/redis/modules/redis/acl.tf). One run:

  1. connects to Redis as acl-admin and counts CLIENT LIST by user=
     (the B40 R3 counter, redis_clients_by_user{user});
  2. reads the users' passwords from Vault secret/redis/users, and the fixed
     rule of each user from users.json (written by Terraform from
     acl_users.json); renders the desired users with #<sha256> password
     hashes, never the passwords;
  3. fails closed: a missing or extra Vault key, a malformed password or
     name, a missing default or infra user, or an unreachable Vault or Redis
     changes nothing and exits non-zero;
  4. compares the render with ACL LIST and, only when they differ, sends
     the difference in one MULTI/EXEC (ACL SETUSER for each changed user,
     ACL DELUSER for each user nobody wants). EXEC does not roll back, so a
     refused command leaves the others applied; the run then fails and the
     next one retries. Every run ends with ACL SAVE: Redis writes the
     aclfile itself (a temporary file and a rename), so no second pod
     mounts the Redis volume, which is ReadWriteOnce;
  5. checks that ACL LIST now equals the render, and that every infra user
     can AUTH with its password and PING;
  6. pushes its metrics to the pushgateway the backup job uses.

Neither ACL SETUSER nor ACL LOAD disconnects clients of a user that still
exists; only ACL DELUSER does (measured on redis:8.10.3, 2026-11-17).

Standard library only, so the stock python image runs it from a ConfigMap.
Tests: python3 -m pytest stacks/redis/modules/redis/acl_sync_test.py -q
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable

ADMIN_USER = "acl-admin"

# The default user until B40 R4. ACL LIST prints exactly this line for it.
# R4 changes it to `user default off ...` (or a strong password) and must
# keep a `default` entry: a file without one leaves default on, nopass,
# +@all.
DEFAULT_USER_ARGS = ["reset", "on", "nopass", "~*", "&*", "+@all"]
DEFAULT_USER_LINE = "user default on nopass sanitize-payload ~* &* +@all"

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
PASSWORD_RE = re.compile(r"^[A-Za-z0-9]{32,128}$")
# Rule tokens Terraform may hand over. No passwords (>, <, #), no `nopass`,
# no `on`/`off`/`reset`: the sync sets those itself.
RULE_TOKEN_RE = re.compile(r"^(~\S+|%R~\S+|%W~\S+|%RW~\S+|&\S+|resetchannels|allkeys|allchannels|allcommands|nocommands|[+-]@?[a-z0-9_.|-]+)$", re.IGNORECASE)


class SyncError(Exception):
    """A reason to change nothing and exit non-zero."""


@dataclass(frozen=True)
class User:
    """One desired ACL user. `line` is what ACL LIST prints for it."""

    name: str
    setuser_args: list[str]
    line: str
    password: str | None = field(default=None, repr=False)


def sha256_hex(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()


def infra_user(name: str, rules: str, password: str) -> User:
    digest = sha256_hex(password)
    return User(
        name=name,
        setuser_args=["reset", "on", f"#{digest}", *rules.split()],
        line=f"user {name} on sanitize-payload #{digest} {rules}",
        password=password,
    )


def default_user() -> User:
    return User(name="default", setuser_args=list(DEFAULT_USER_ARGS), line=DEFAULT_USER_LINE)


def validate_rules(users_rules: dict[str, str]) -> None:
    if not isinstance(users_rules, dict) or not users_rules:
        raise SyncError("users.json is empty or not an object")
    if "default" in users_rules:
        raise SyncError("users.json must not name default; the sync owns its rule")
    if ADMIN_USER not in users_rules:
        raise SyncError(f"users.json has no {ADMIN_USER}")
    for name, rules in users_rules.items():
        if not NAME_RE.match(name):
            raise SyncError(f"bad user name in users.json: {name!r}")
        if not isinstance(rules, str) or not rules.split():
            raise SyncError(f"user {name} has no rules")
        for token in rules.split():
            if not RULE_TOKEN_RE.match(token):
                raise SyncError(f"user {name}: rule token {token!r} is not allowed")
    if "+acl" not in users_rules[ADMIN_USER].split():
        raise SyncError(f"{ADMIN_USER} must keep +acl, or the sync locks itself out")


def render_tenant_users() -> list[User]:
    """Cloud Key Value tenants, B27. None until then.

    B27 fills this from Cloud's read-only internal route (name, password
    hash, Size): reject any name that does not match ^p_[a-z0-9_]+$, and
    write each tenant's rules from the fixed template in the B40 design
    (checklist-and-backlog.md, "Cloud tenants"), never from Cloud's input.
    """
    return []


def render(users_rules: dict[str, str], passwords: dict[str, str]) -> dict[str, User]:
    """The desired users by name. Raises SyncError on any broken input."""
    validate_rules(users_rules)
    if not isinstance(passwords, dict):
        raise SyncError("Vault secret/redis/users is not an object")
    missing = sorted(set(users_rules) - set(passwords))
    if missing:
        raise SyncError(f"Vault secret/redis/users has no key for: {', '.join(missing)}")
    extra = sorted(set(passwords) - set(users_rules))
    if extra:
        raise SyncError(f"Vault secret/redis/users has keys users.json does not name: {', '.join(extra)}")
    for name, password in passwords.items():
        if not isinstance(password, str) or not PASSWORD_RE.match(password):
            raise SyncError(f"Vault password for {name} is empty or malformed")

    desired: dict[str, User] = {"default": default_user()}
    for name in sorted(users_rules):
        desired[name] = infra_user(name, users_rules[name], passwords[name])
    for tenant in render_tenant_users():
        if tenant.name in desired:
            raise SyncError(f"tenant user {tenant.name} collides with an infra user")
        desired[tenant.name] = tenant
    check_complete(desired, users_rules)
    return desired


def check_complete(desired: dict[str, User], users_rules: dict[str, str]) -> None:
    """The render must hold the default line and every infra user."""
    if desired.get("default") is None or desired["default"].line != DEFAULT_USER_LINE:
        raise SyncError("render lacks the default user line")
    lacking = sorted(n for n in users_rules if n not in desired)
    if lacking:
        raise SyncError(f"render lacks infra users: {', '.join(lacking)}")


def parse_acl_list(lines: list[str]) -> dict[str, str]:
    current: dict[str, str] = {}
    for line in lines:
        parts = line.split(" ", 2)
        if len(parts) < 2 or parts[0] != "user":
            raise SyncError(f"unexpected ACL LIST line: {line[:40]!r}")
        current[parts[1]] = line
    return current


def plan(current: dict[str, str], desired: dict[str, User]) -> list[list[str]]:
    """ACL commands that turn `current` into `desired`; [] when they match."""
    commands: list[list[str]] = []
    for name, user in desired.items():
        if current.get(name) != user.line:
            commands.append(["ACL", "SETUSER", name, *user.setuser_args])
    for name in sorted(current):
        if name not in desired and name not in ("default", ADMIN_USER):
            commands.append(["ACL", "DELUSER", name])
    return commands


def count_clients(client_list: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in client_list.splitlines():
        match = re.search(r"(?:^| )user=(\S+)", line)
        if match:
            counts[match.group(1)] = counts.get(match.group(1), 0) + 1
    return counts


# --- Redis (RESP2, one connection) -------------------------------------------


class RedisError(Exception):
    """An error reply from Redis."""


class Redis:
    def __init__(self, host: str, port: int, timeout: float = 10.0) -> None:
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.file = self.sock.makefile("rb")

    def close(self) -> None:
        try:
            self.file.close()
        finally:
            self.sock.close()

    def send(self, *args: str) -> None:
        out = [f"*{len(args)}\r\n".encode()]
        for arg in args:
            data = arg.encode()
            out.append(b"$%d\r\n%s\r\n" % (len(data), data))
        self.sock.sendall(b"".join(out))

    def read(self) -> object:
        line = self.file.readline()
        if not line:
            raise ConnectionError("Redis closed the connection")
        kind, rest = line[:1], line[1:].rstrip(b"\r\n")
        if kind == b"+":
            return rest.decode()
        if kind == b"-":
            return RedisError(rest.decode())
        if kind == b":":
            return int(rest)
        if kind == b"$":
            size = int(rest)
            if size < 0:
                return None
            data = self.file.read(size + 2)
            return data[:-2].decode()
        if kind == b"*":
            size = int(rest)
            if size < 0:
                return None
            return [self.read() for _ in range(size)]
        raise ConnectionError(f"unexpected reply type {kind!r}")

    def call(self, *args: str) -> object:
        self.send(*args)
        reply = self.read()
        if isinstance(reply, RedisError):
            raise reply
        return reply

    def transaction(self, commands: list[list[str]]) -> list[object]:
        self.call("MULTI")
        for command in commands:
            self.call(*command)  # +QUEUED, or an error that aborts EXEC
        replies = self.call("EXEC")
        if not isinstance(replies, list):
            raise SyncError("EXEC was aborted")
        return replies


RedisFactory = Callable[[], Redis]


def auth_ok(connect: RedisFactory, user: User) -> bool:
    try:
        conn = connect()
    except OSError:
        return False
    try:
        conn.call("AUTH", user.name, user.password or "")
        return conn.call("PING") == "PONG"
    except (RedisError, OSError, ConnectionError):
        return False
    finally:
        conn.close()


# --- Vault ---------------------------------------------------------------------


def vault_passwords(addr: str, role: str, path: str, jwt_file: str, timeout: float = 10.0) -> dict[str, str]:
    try:
        with open(jwt_file) as fh:
            jwt = fh.read().strip()
        login = urllib.request.Request(
            f"{addr}/v1/auth/kubernetes/login",
            data=json.dumps({"role": role, "jwt": jwt}).encode(),
            method="POST",
        )
        with urllib.request.urlopen(login, timeout=timeout) as resp:
            token = json.load(resp)["auth"]["client_token"]
        read = urllib.request.Request(f"{addr}/v1/{path}", headers={"X-Vault-Token": token})
        with urllib.request.urlopen(read, timeout=timeout) as resp:
            data = json.load(resp)["data"]["data"]
    except (OSError, urllib.error.URLError, KeyError, TypeError, ValueError) as exc:
        raise SyncError(f"Vault unreachable or refused: {type(exc).__name__}: {exc}") from None
    if not isinstance(data, dict):
        raise SyncError("Vault secret is not an object")
    return data


# --- metrics -------------------------------------------------------------------


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def metrics_text(gauges: dict[str, float], labelled: dict[str, dict[str, float]]) -> str:
    out: list[str] = []
    for name, value in gauges.items():
        out += [f"# TYPE {name} gauge", f"{name} {value}"]
    for name, series in labelled.items():
        out.append(f"# TYPE {name} gauge")
        out += [f'{name}{{user="{escape_label(user)}"}} {value}' for user, value in sorted(series.items())]
    return "\n".join(out) + "\n"


def push_metrics(url: str, body: str, timeout: float = 10.0) -> None:
    # POST replaces only the metric names sent, so a failed run that sends
    # no last_success keeps the previous one.
    req = urllib.request.Request(url, data=body.encode(), method="POST", headers={"Content-Type": "text/plain"})
    with urllib.request.urlopen(req, timeout=timeout):
        pass


# --- one run -------------------------------------------------------------------


@dataclass
class Result:
    ok: bool
    changes: int = 0
    counts: dict[str, int] = field(default_factory=dict)
    auth: dict[str, float] = field(default_factory=dict)
    error: str = ""


def run(
    users_rules: dict[str, str],
    fetch_passwords: Callable[[], dict[str, str]],
    connect: RedisFactory,
) -> Result:
    result = Result(ok=False)
    try:
        passwords = fetch_passwords()
    except SyncError as exc:
        # acl-admin's password comes from Vault, so without Vault the counter
        # cannot log in either. Nothing is changed.
        result.error = str(exc)
        return result

    try:
        admin = connect()
    except OSError as exc:
        result.error = f"Redis unreachable: {exc}"
        return result
    try:
        admin.call("AUTH", ADMIN_USER, str(passwords.get(ADMIN_USER, "")))
        # The R3 counter runs before the render, so a broken input still
        # reports who is connected.
        client_list = admin.call("CLIENT", "LIST")
        result.counts = count_clients(client_list if isinstance(client_list, str) else "")
        # Every known user gets a series, 0 when idle, so the R3 gate can
        # tell "no clients" from "no data".
        known = ["default", *(users_rules if isinstance(users_rules, dict) else {})]
        for name in known:
            result.counts.setdefault(name, 0)

        desired = render(users_rules, passwords)

        acl_list = admin.call("ACL", "LIST")
        current = parse_acl_list(acl_list if isinstance(acl_list, list) else [])
        commands = plan(current, desired)
        errors: list[str] = []
        if commands:
            # MULTI keeps other clients from running between the commands,
            # but EXEC does not roll back: a command Redis refuses leaves the
            # others applied.
            replies = admin.transaction(commands)
            errors = [str(r) for r in replies if isinstance(r, RedisError)]
        # Saved on every run, so a failed SAVE, a run killed after EXEC or a
        # partial EXEC is on disk by the next minute.
        admin.call("ACL", "SAVE")
        if errors:
            raise SyncError(
                f"partial change: Redis refused {len(errors)} of {len(commands)} commands, "
                f"the rest are applied and saved; first refusal: {errors[0]}"
            )
        result.changes = len(commands)

        after_list = admin.call("ACL", "LIST")
        after = parse_acl_list(after_list if isinstance(after_list, list) else [])
        drift = sorted(n for n, u in desired.items() if after.get(n) != u.line)
        strays = sorted(n for n in after if n not in desired)
        if drift or strays:
            raise SyncError(f"ACL LIST differs from the render after sync: drift={drift} strays={strays}")

        for name, user in desired.items():
            if user.password is not None:
                result.auth[name] = 1.0 if auth_ok(connect, user) else 0.0
        failed = sorted(n for n, v in result.auth.items() if v != 1.0)
        if failed:
            raise SyncError(f"AUTH and PING failed for: {', '.join(failed)}")
        result.ok = True
        return result
    except (SyncError, RedisError, OSError, ConnectionError) as exc:
        result.error = f"{type(exc).__name__}: {exc}"
        return result
    finally:
        admin.close()


def main() -> int:
    env = os.environ
    with open(env.get("USERS_FILE", "/config/users.json")) as fh:
        users_rules = json.load(fh)
    host = env.get("REDIS_HOST", "redis-master.redis.svc.cluster.local")
    port = int(env.get("REDIS_PORT", "6379"))
    result = run(
        users_rules,
        fetch_passwords=lambda: vault_passwords(
            env.get("VAULT_ADDR", "http://vault-active.vault.svc.cluster.local:8200"),
            env.get("VAULT_ROLE", "redis-acl-sync"),
            env.get("VAULT_SECRET_PATH", "secret/data/redis/users"),
            env.get("SA_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token"),
        ),
        connect=lambda: Redis(host, port),
    )
    now = time.time()
    gauges: dict[str, float] = {
        "redis_acl_sync_last_run_timestamp_seconds": now,
        "redis_acl_sync_last_run_ok": 1.0 if result.ok else 0.0,
    }
    labelled: dict[str, dict[str, float]] = {}
    if result.counts:
        labelled["redis_clients_by_user"] = {u: float(c) for u, c in result.counts.items()}
    if result.auth:
        labelled["redis_acl_user_auth_ok"] = result.auth
    if result.ok:
        gauges["redis_acl_sync_last_success_timestamp_seconds"] = now
        gauges["redis_acl_sync_changes"] = float(result.changes)
        gauges["redis_acl_sync_users"] = float(len(result.auth) + 1)

    if result.ok:
        print(f"ok: {result.changes} change(s), {len(result.auth)} users AUTH and PING, clients by user {result.counts}")
    else:
        print(f"FAILED, nothing more changed: {result.error}", file=sys.stderr)
    try:
        push_metrics(env.get("PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/redis-acl-sync"), metrics_text(gauges, labelled))
    except (OSError, urllib.error.URLError) as exc:
        print(f"pushgateway push failed: {exc}", file=sys.stderr)
        return 1
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
