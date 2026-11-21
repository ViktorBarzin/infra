"""redis-acl-sync: keep the shared Redis's ACL users equal to the desired set.

Runs every minute as the CronJob redis-acl-sync in namespace redis
(stacks/redis/modules/redis/acl.tf). One run:

  1. connects to Redis as acl-admin and counts CLIENT LIST by user=
     (the B40 R3 counter, redis_clients_by_user{user}), and counts the
     default clients whose address is not a pod of DEFAULT_USER_NAMESPACES
     (redis_default_clients_unexpected, the R3 gate; rybbit stays on
     default because it can send only a password), and prints one stderr
     line for each such client: its CLIENT LIST addr, name, age, idle,
     cmd and library;
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
import ssl
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
# Vault holds a password for default too: rybbit, which can send only a
# password, logs in with it (Redis ignores a password for a nopass default),
# and R4 sets it as default's password instead of turning default off. The
# render does not use it until R4.
DEFAULT_PASSWORD_KEY = "default"
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
    # The Vault document also holds default's password (DEFAULT_PASSWORD_KEY),
    # which users.json does not name.
    missing = sorted({*users_rules, DEFAULT_PASSWORD_KEY} - set(passwords))
    if missing:
        raise SyncError(f"Vault secret/redis/users has no key for: {', '.join(missing)}")
    extra = sorted(set(passwords) - set(users_rules) - {DEFAULT_PASSWORD_KEY})
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


ADDR_RE = re.compile(r" addr=(\S+):\d+(?: |$)")

# The CLIENT LIST fields printed for an unexpected default client. None of
# them holds a secret: cmd is the command name only, never its arguments.
UNEXPECTED_FIELDS = ("addr", "name", "age", "idle", "cmd", "lib-name", "lib-ver")
FIELD_MAX = 64


@dataclass
class UnexpectedClient:
    """A default client outside the allowed namespaces, as one log line."""

    ip: str
    fields: dict[str, str]


def client_fields(line: str) -> dict[str, str]:
    """CLIENT LIST's key=value pairs. Split on spaces; Redis escapes none."""
    out: dict[str, str] = {}
    for pair in line.split(" "):
        key, sep, value = pair.partition("=")
        if sep and key not in out:
            out[key] = value
    return out


def default_outside(client_list: str, allowed_ips: set[str]) -> list[UnexpectedClient]:
    """Clients on default whose address is not a pod of an allowed namespace.

    Matches " addr=" with the space: laddr= is Redis's own address.
    """
    found: list[UnexpectedClient] = []
    for line in client_list.splitlines():
        if not re.search(r"(?:^| )user=default(?: |$)", line):
            continue
        match = ADDR_RE.search(line)
        ip = match.group(1).strip("[]") if match else ""
        if ip and ip in allowed_ips:
            continue
        pairs = client_fields(line)
        found.append(UnexpectedClient(ip=ip, fields={k: pairs.get(k, "")[:FIELD_MAX] for k in UNEXPECTED_FIELDS}))
    return found


def count_default_outside(client_list: str, allowed_ips: set[str]) -> int:
    return len(default_outside(client_list, allowed_ips))


def describe_unexpected(client: UnexpectedClient) -> str:
    """One stderr line per unexpected default client, for the R3 gate. The
    pod behind the address is found in the Kubernetes audit log."""
    fields = " ".join(f"{k}={v}" for k, v in client.fields.items())
    return f"unexpected default client: {fields}"


def pod_ips_from_list(doc: object) -> set[str]:
    ips: set[str] = set()
    items = doc.get("items", []) if isinstance(doc, dict) else []
    for pod in items if isinstance(items, list) else []:
        status = pod.get("status", {}) if isinstance(pod, dict) else {}
        if not isinstance(status, dict):
            continue
        if isinstance(status.get("podIP"), str):
            ips.add(status["podIP"])
        for entry in status.get("podIPs", []) or []:
            if isinstance(entry, dict) and isinstance(entry.get("ip"), str):
                ips.add(entry["ip"])
    return ips


def namespace_pod_ips(namespaces: list[str], api: str, token_file: str, ca_file: str, timeout: float = 10.0) -> set[str]:
    """Pod IPs of the namespaces allowed to stay on default (Role in acl.tf)."""
    ips: set[str] = set()
    try:
        with open(token_file) as fh:
            token = fh.read().strip()
        ctx = ssl.create_default_context(cafile=ca_file)
        for ns in namespaces:
            req = urllib.request.Request(f"{api}/api/v1/namespaces/{ns}/pods", headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                ips |= pod_ips_from_list(json.load(resp))
    except (OSError, urllib.error.URLError, ValueError) as exc:
        raise SyncError(f"Kubernetes API unreachable or refused: {type(exc).__name__}: {exc}") from None
    return ips


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
    # Default clients outside the namespaces allowed on default (R3 gate).
    default_unexpected: int | None = None
    default_unexpected_clients: list[UnexpectedClient] = field(default_factory=list)
    default_lookup_error: str = ""
    auth: dict[str, float] = field(default_factory=dict)
    error: str = ""


def run(
    users_rules: dict[str, str],
    fetch_passwords: Callable[[], dict[str, str]],
    connect: RedisFactory,
    default_ips: Callable[[], set[str]] = set,
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
        clients = client_list if isinstance(client_list, str) else ""
        result.counts = count_clients(clients)
        # A failed pod lookup counts every default client as unexpected, so
        # the R3 gate stays red rather than passing on missing data.
        try:
            allowed = default_ips()
        except SyncError as exc:
            allowed = set()
            result.default_lookup_error = str(exc)
        result.default_unexpected_clients = default_outside(clients, allowed)
        result.default_unexpected = len(result.default_unexpected_clients)
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
    kube_api = f"https://{env.get('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc')}:{env.get('KUBERNETES_SERVICE_PORT', '443')}"
    result = run(
        users_rules,
        fetch_passwords=lambda: vault_passwords(
            env.get("VAULT_ADDR", "http://vault-active.vault.svc.cluster.local:8200"),
            env.get("VAULT_ROLE", "redis-acl-sync"),
            env.get("VAULT_SECRET_PATH", "secret/data/redis/users"),
            env.get("SA_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token"),
        ),
        connect=lambda: Redis(host, port),
        default_ips=lambda: namespace_pod_ips(
            [n for n in env.get("DEFAULT_USER_NAMESPACES", "").split(",") if n],
            kube_api,
            env.get("SA_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token"),
            env.get("SA_CA_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"),
        ),
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
    if result.default_unexpected is not None:
        gauges["redis_default_clients_unexpected"] = float(result.default_unexpected)
    if result.default_lookup_error:
        print(f"warning: counting every default client as unexpected: {result.default_lookup_error}", file=sys.stderr)
    for client in result.default_unexpected_clients:
        print(describe_unexpected(client), file=sys.stderr)
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
