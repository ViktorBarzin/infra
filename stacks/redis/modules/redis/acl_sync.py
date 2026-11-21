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


# --- Cloud Key Value tenants (B27) --------------------------------------------
#
# Cloud publishes the Key Values it wants at a read-only internal route
# (the cloud repo's reconciler, GET /internal/redis-tenants with a bearer
# token from Vault secret/redis/cloud-tenants): user name, password hash,
# key prefix and Size in bytes, and a `purge` list of prefixes whose data
# must go. Cloud has no Redis right of its own. The sync checks every field
# and writes each tenant's rules itself from the fixed template below
# (B40 design, "Cloud tenants"), so a stolen Cloud credential can make only
# prefix-confined users. Redis 8.10.3 prints a tenant as
#   user <name> on sanitize-payload #<sha256> ~<prefix>* resetchannels &<prefix>* <rules>
# (resetkeys is dropped), which is the line the plan compares.

TENANT_NAME_RE = re.compile(r"^p_[a-z0-9_]{1,120}$")
TENANT_PART_RE = re.compile(r"^[a-z0-9-]{1,63}$")
TENANT_PREFIX_RE = re.compile(r"^p:([a-z0-9-]{1,63}):([a-z0-9-]{1,63}):$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
# Refused on top of the design's template (review of B27, measured on
# redis:8.10.3): MOVE and COPY ... DB n put keys in another db, where they
# are never measured, purged or evicted; SCRIPT KILL stops another client's
# script; DBSIZE and the PUBSUB introspection subcommands show other
# tenants' keys and channels. Second review: SCRIPT DEBUG SYNC with EVAL
# blocks the whole server; the search module's commands (FT._DROPIFX has no
# key spec and dropped another user's index); CLIENT TRACKING ... BCAST
# sends the names of every key written by anyone; TS.MGET, TS.MRANGE,
# TS.MREVRANGE, TS.QUERYINDEX and TS.QUERYLABELS search every time series
# by label; the keyless HIMPORT session subcommands hold memory outside any
# key; LOLWUT burns CPU on demand. SWAPDB, RESTORE, MIGRATE and SORT ...
# STORE are already refused by -@dangerous; LMOVE, SUNIONSTORE and RENAME
# to another prefix by the key pattern. acl_sync_test.py walks COMMAND and
# fails on any keyless command a tenant may run that its reviewed
# allowlist does not name.
TENANT_DENIED = (
    "-move -copy -script|kill -dbsize -pubsub|channels -pubsub|shardchannels -pubsub|numsub "
    "-pubsub|shardnumsub -pubsub|numpat "
    "-script|debug -client|tracking -himport|prepare -himport|discard -himport|discardall -lolwut"
)
# Module commands. redis:8.10.3-alpine ships the search, timeseries, bloom
# and json modules, but redis-v2 runs redis-server directly (main.tf), which
# skips the image's entrypoint that loads them: today none is loaded, and
# ACL SETUSER refuses a rule that names an unknown category or command. So
# the sync reads ACL CAT every run and adds these only for a loaded module.
# Bloom's keyless commands and json's are refused or have key specs already
# (acl_sync_test.py walks both configurations).
MODULE_DENIALS: tuple[tuple[str, str], ...] = (
    ("search", "-@search"),
    ("timeseries", "-ts.mget -ts.mrange -ts.mrevrange -ts.queryindex -ts.querylabels"),
)
TENANT_RULES = (
    "-@all +@read +@write +@keyspace +@hash +@list +@set +@sortedset +@stream +@string +@pubsub "
    "+@transaction +@scripting +@connection -@dangerous -select -scan -randomkey -function -script|flush "
    + TENANT_DENIED
)
def module_denials(categories: set[str]) -> str:
    """The module part of the tenant rules for the categories ACL CAT lists."""
    return " ".join(rule for category, rule in MODULE_DENIALS if category in categories)


def _known_module_denials() -> list[str]:
    found = [""]
    for _, rule in MODULE_DENIALS:
        found += [f"{f} {rule}".strip() for f in found]
    return found


def tenant_rules(full: bool, extra: str = "") -> str:
    base = TENANT_FULL_RULES if full else TENANT_RULES
    return f"{base} {extra}" if extra else base


# Over its Size: read and delete only. No scripts and no PUBLISH, which
# would write or cost memory; MULTI/EXEC/WATCH stay so a client's
# transaction of reads and deletes still runs.
TENANT_FULL_RULES = (
    "-@all +@read +@connection +del +unlink +multi +exec +discard +watch +unwatch "
    "-@dangerous -select -scan -randomkey " + TENANT_DENIED
)
TENANT_LINE_RE = re.compile(
    r"^user (p_[a-z0-9_]+) on sanitize-payload #([0-9a-f]{64}) "
    r"~(p:[a-z0-9-]+:[a-z0-9-]+:)\* resetchannels &(p:[a-z0-9-]+:[a-z0-9-]+:)\* (.+)$"
)
TENANT_KEYS_RE = re.compile(r" ~(p:[a-z0-9-]+:[a-z0-9-]+:)\* ")
MAX_TENANTS = 10000
MAX_TENANT_BYTES = 1 << 40
ANSWER_MAX_BYTES = 8 * 1024 * 1024

# Measurement, every MEASURE_EVERY_SECONDS, in two passes over db 0.
#  1. Count: one SCAN MATCH p:* pass (COUNT SCAN_COUNT a call) counts each
#     tenant's keys exactly and UNLINKs the keys of purged prefixes. SCAN
#     visits every key of db 0 whatever the MATCH (5,828 keys on
#     2026-11-21): about 6 calls today.
#  2. Size: a second SCAN that goes on from the cursor the last run left,
#     sending MEMORY USAGE <key> SAMPLES 0 (every element, so small first
#     elements cannot hide a big list) for every tenant key it meets,
#     pipelined, until MEMORY_USAGE_PER_RUN calls; it may finish the SCAN
#     page it is on, so a run sends at most the cap plus one page. When the
#     SCAN comes back to 0 the cycle is complete and every tenant key
#     present for the whole cycle was sized once.
# The cursor and each tenant's running total live in Redis itself, in the
# string key STATE_KEY: acl-admin may GET and SET it (its rule names
# ~redis-acl-sync:*), no tenant can (they hold p:<project>:<service>:*
# only), it has no TTL so volatile-lru never evicts it, and the AOF keeps it
# across restarts. A missing or unreadable value starts a new cycle, which
# only costs time. The pushgateway is not state; the ACL list holds no
# numbers.
# The estimate: a tenant's bytes are its running total plus every key not
# sized yet in this cycle counted at the largest key sized for it (this
# cycle or the last). Keys a complete cycle has sized are never undercounted;
# a key written during a cycle that is bigger than any sized so far counts
# low until the cycle reaches it, at most one cycle later. A complete cycle
# within one run (up to MEMORY_USAGE_PER_RUN tenant keys in all) makes the
# figure exact. A cycle over K
# tenant keys takes ceil(K / MEMORY_USAGE_PER_RUN) measuring runs; a tenant
# with more than MAX_KEYS_PER_TENANT keys, which alone would fill a run, is
# treated as over its Size. Cost at 10,000 tenant keys: about 16 + 16 SCAN
# calls and 10 batches of 1,000 MEMORY USAGE, about 10 ms of Redis CPU for
# small strings.
MEASURE_EVERY_SECONDS = 300
SCAN_COUNT = 1000
PIPELINE_BATCH = 1000
MEMORY_USAGE_PER_RUN = 100000
MAX_KEYS_PER_TENANT = 100000
# Configurable, like the Redis address, Vault paths, tenant route and
# Pushgateway groups (main() reads those), so a second Redis for Cloud
# tenants can run this job unchanged.
STATE_KEY = os.environ.get("KV_STATE_KEY", "redis-acl-sync:kv-measure")


@dataclass(frozen=True)
class Tenant:
    """One Key Value. max_bytes is None for a tenant kept from ACL LIST
    while Cloud's route is down: its mode then stays as it is."""

    name: str
    password_sha256: str
    prefix: str
    project: str
    service: str
    max_bytes: int | None = None


@dataclass
class TenantAnswer:
    tenants: list[Tenant]
    purge: list[str]
    warnings: list[str] = field(default_factory=list)


def _tenant_prefix(entry: dict[str, object], what: str) -> tuple[str, str, str]:
    prefix, project, service = entry.get("prefix"), entry.get("project"), entry.get("service")
    if not isinstance(prefix, str) or not TENANT_PREFIX_RE.match(prefix):
        raise SyncError(f"{what}: bad prefix {str(prefix)[:80]!r}")
    if not isinstance(project, str) or not isinstance(service, str) or prefix != f"p:{project}:{service}:":
        raise SyncError(f"{what}: prefix {prefix!r} does not match its project and service")
    return prefix, project, service


def parse_tenant_answer(doc: object) -> TenantAnswer:
    """Check Cloud's answer field by field. Any bad tenant rejects the whole
    answer, so the run keeps the last good set instead of dropping one."""
    if not isinstance(doc, dict) or doc.get("version") != 1:
        raise SyncError("Cloud tenants answer is not version 1")
    raw_tenants, raw_purge = doc.get("tenants"), doc.get("purge", [])
    if not isinstance(raw_tenants, list) or len(raw_tenants) > MAX_TENANTS:
        raise SyncError("Cloud tenants answer: tenants is not a list of at most 10000")
    if not isinstance(raw_purge, list) or len(raw_purge) > MAX_TENANTS:
        raise SyncError("Cloud tenants answer: purge is not a list of at most 10000")
    tenants: list[Tenant] = []
    names: set[str] = set()
    prefixes: set[str] = set()
    for entry in raw_tenants:
        if not isinstance(entry, dict):
            raise SyncError("Cloud tenants answer: a tenant is not an object")
        name, digest, max_bytes = entry.get("user"), entry.get("passwordSha256"), entry.get("maxBytes")
        if not isinstance(name, str) or not TENANT_NAME_RE.match(name):
            raise SyncError(f"Cloud tenants answer: bad tenant user {str(name)[:80]!r}")
        if not isinstance(digest, str) or not SHA256_RE.match(digest):
            raise SyncError(f"tenant {name}: bad password hash")
        if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or not 0 < max_bytes <= MAX_TENANT_BYTES:
            raise SyncError(f"tenant {name}: bad maxBytes")
        prefix, project, service = _tenant_prefix(entry, f"tenant {name}")
        if name in names or prefix in prefixes:
            raise SyncError(f"Cloud tenants answer names {name} or {prefix} twice")
        names.add(name)
        prefixes.add(prefix)
        tenants.append(Tenant(name, digest, prefix, project, service, max_bytes))
    purge: list[str] = []
    warnings: list[str] = []
    for entry in raw_purge:
        if not isinstance(entry, dict):
            raise SyncError("Cloud tenants answer: a purge entry is not an object")
        prefix, _, _ = _tenant_prefix(entry, "purge entry")
        if prefix in prefixes:
            # Cloud should never ask this; deleting nothing is the safe side.
            warnings.append(f"ignored purge of {prefix}: a live tenant has that prefix")
            continue
        if prefix not in purge:
            purge.append(prefix)
    return TenantAnswer(tenants, purge, warnings)


def tenant_user(tenant: Tenant, full: bool, extra: str = "") -> User:
    rules = tenant_rules(full, extra)
    p = tenant.prefix
    return User(
        name=tenant.name,
        setuser_args=["reset", "on", f"#{tenant.password_sha256}", "resetkeys", f"~{p}*", "resetchannels", f"&{p}*", *rules.split()],
        line=f"user {tenant.name} on sanitize-payload #{tenant.password_sha256} ~{p}* resetchannels &{p}* {rules}",
    )


def parse_tenant_line(line: str) -> tuple[Tenant, bool] | None:
    """A tenant and whether it is full, when an ACL LIST line is exactly the
    template (normal or full); else None."""
    m = TENANT_LINE_RE.match(line)
    if m is None or m.group(3) != m.group(4) or not TENANT_NAME_RE.match(m.group(1)):
        return None
    # Any module part, so a line written before a module came or went is
    # still a tenant: the plan rewrites it, and it is never "foreign".
    shapes = {tenant_rules(f, e): f for f in (False, True) for e in _known_module_denials()}
    if m.group(5) not in shapes:
        return None
    prefix_match = TENANT_PREFIX_RE.match(m.group(3))
    if prefix_match is None:
        return None
    tenant = Tenant(m.group(1), m.group(2), m.group(3), prefix_match.group(1), prefix_match.group(2))
    return tenant, shapes[m.group(5)]


def tenants_from_acl(current: dict[str, str]) -> list[Tenant]:
    """The tenants Redis holds now: the last good set while the route is down."""
    found = [parse_tenant_line(line) for line in current.values()]
    return [t for t, _ in (f for f in found if f is not None)]


def full_users(current: dict[str, str]) -> set[str]:
    found = [parse_tenant_line(line) for line in current.values()]
    return {t.name for t, full in (f for f in found if f is not None) if full}


def foreign_users(current: dict[str, str], infra_names: set[str], tenant_names: set[str]) -> list[str]:
    """Users that are not default, not infra, not a tenant Cloud asked for
    and not shaped like the tenant template (RedisForeignUser)."""
    known = {"default", ADMIN_USER, *infra_names, *tenant_names}
    return sorted(n for n, line in current.items() if n not in known and parse_tenant_line(line) is None)


def key_prefix(key: str) -> str | None:
    parts = key.split(":", 3)
    if len(parts) < 4 or parts[0] != "p" or not TENANT_PART_RE.match(parts[1]) or not TENANT_PART_RE.match(parts[2]):
        return None
    return f"p:{parts[1]}:{parts[2]}:"


def measure_due(now: float, every_seconds: int = MEASURE_EVERY_SECONDS) -> bool:
    return int(now) // 60 % max(every_seconds // 60, 1) == 0


def fetch_tenant_answer(url: str, token: str, timeout: float = 10.0) -> object:
    if not token:
        raise SyncError("no token for the Cloud tenants route (Vault secret/redis/cloud-tenants)")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(ANSWER_MAX_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise SyncError(f"Cloud tenants route answered {exc.code}") from None
    except (OSError, urllib.error.URLError) as exc:
        raise SyncError(f"Cloud tenants route unreachable: {type(exc).__name__}: {exc}") from None
    if len(body) > ANSWER_MAX_BYTES:
        raise SyncError("Cloud tenants answer is larger than 8 MiB")
    try:
        return json.loads(body)
    except ValueError:
        raise SyncError("Cloud tenants answer is not JSON") from None


@dataclass
class Usage:
    keys: dict[str, int]
    bytes: dict[str, float]
    purged: int = 0
    memory_usage_calls: int = 0
    cycle_complete: bool = False
    too_many_keys: set[str] = field(default_factory=set)


@dataclass
class MeasureState:
    """The size pass's progress, kept in STATE_KEY between runs."""

    cursor: str = "0"
    # prefix -> [bytes sized this cycle, keys sized, largest key]
    partial: dict[str, list[int]] = field(default_factory=dict)
    # prefix -> largest key of the last complete cycle
    largest: dict[str, int] = field(default_factory=dict)


def parse_state(raw: object) -> MeasureState:
    """STATE_KEY's value, or a fresh state when it is missing or broken."""
    if not isinstance(raw, str):
        return MeasureState()
    try:
        doc = json.loads(raw)
    except ValueError:
        return MeasureState()
    if not isinstance(doc, dict) or doc.get("v") != 1:
        return MeasureState()
    cursor, partial, largest = doc.get("cursor"), doc.get("partial"), doc.get("largest")
    if not isinstance(cursor, str) or not cursor.isdigit() or not isinstance(partial, dict) or not isinstance(largest, dict):
        return MeasureState()
    st = MeasureState(cursor=cursor)
    for prefix, v in partial.items():
        if TENANT_PREFIX_RE.match(str(prefix)) and isinstance(v, list) and len(v) == 3 and all(isinstance(x, int) and not isinstance(x, bool) and x >= 0 for x in v):
            st.partial[str(prefix)] = [int(x) for x in v]
    for prefix, v in largest.items():
        if TENANT_PREFIX_RE.match(str(prefix)) and isinstance(v, int) and not isinstance(v, bool) and v >= 0:
            st.largest[str(prefix)] = v
    return st


def dump_state(st: MeasureState) -> str:
    return json.dumps({"v": 1, "cursor": st.cursor, "partial": st.partial, "largest": st.largest}, sort_keys=True)


def render(users_rules: dict[str, str], passwords: dict[str, str], tenants: list[User] | None = None) -> dict[str, User]:
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
    for tenant in tenants or []:
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
            # Tenants choose their key names: surrogateescape carries any
            # byte through a decode and back.
            data = arg.encode(errors="surrogateescape")
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
            return data[:-2].decode(errors="surrogateescape")
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

    def pipeline(self, commands: list[list[str]]) -> list[object]:
        """Send every command, then read every reply; errors come back as
        RedisError values, not raised."""
        for command in commands:
            self.send(*command)
        return [self.read() for _ in commands]

    def transaction(self, commands: list[list[str]]) -> list[object]:
        self.call("MULTI")
        for command in commands:
            self.call(*command)  # +QUEUED, or an error that aborts EXEC
        replies = self.call("EXEC")
        if not isinstance(replies, list):
            raise SyncError("EXEC was aborted")
        return replies


RedisFactory = Callable[[], Redis]


def _scan_page(admin: Redis, cursor: str) -> tuple[str, list[str]]:
    reply = admin.call("SCAN", cursor, "MATCH", "p:*", "COUNT", str(SCAN_COUNT))
    if not isinstance(reply, list) or len(reply) != 2 or not isinstance(reply[1], list):
        raise SyncError("unexpected SCAN reply")
    return str(reply[0]), [str(k) for k in reply[1]]


def measure(admin: Redis, prefixes: set[str], purge: set[str]) -> Usage:
    """Count every tenant's keys, UNLINK purged prefixes, size the next
    slice of tenant keys and estimate each tenant's bytes (see
    MEASURE_EVERY_SECONDS). The caller checked that no user holds a purge
    prefix."""
    keys = {p: 0 for p in prefixes}
    usage = Usage(keys=keys, bytes={})
    cursor = "0"
    while True:  # 1. count and purge
        cursor, page = _scan_page(admin, cursor)
        to_unlink: list[str] = []
        for key in page:
            prefix = key_prefix(key)
            if prefix in keys:
                keys[prefix] += 1
            elif prefix in purge:
                to_unlink.append(key)
        for i in range(0, len(to_unlink), PIPELINE_BATCH):
            removed = admin.call("UNLINK", *to_unlink[i : i + PIPELINE_BATCH])
            usage.purged += removed if isinstance(removed, int) else 0
        if cursor == "0":
            break

    st = parse_state(admin.call("GET", STATE_KEY))
    st.partial = {p: v for p, v in st.partial.items() if p in prefixes}
    st.largest = {p: v for p, v in st.largest.items() if p in prefixes}
    cursor = st.cursor
    while usage.memory_usage_calls < MEMORY_USAGE_PER_RUN:  # 2. size
        cursor, page = _scan_page(admin, cursor)
        to_size = [(key_prefix(k), k) for k in page]
        sized = [(p, k) for p, k in to_size if p is not None and p in keys]
        for i in range(0, len(sized), PIPELINE_BATCH):
            batch = sized[i : i + PIPELINE_BATCH]
            replies = admin.pipeline([["MEMORY", "USAGE", k, "SAMPLES", "0"] for _, k in batch])
            usage.memory_usage_calls += len(batch)
            for (prefix, _), size in zip(batch, replies):
                if isinstance(size, RedisError):
                    raise SyncError(f"MEMORY USAGE refused: {size}")
                entry = st.partial.setdefault(str(prefix), [0, 0, 0])
                if isinstance(size, int):  # None: the key went away meanwhile
                    entry[0] += size
                    entry[1] += 1
                    entry[2] = max(entry[2], size)
        if cursor == "0":
            usage.cycle_complete = True
            break
    st.cursor = cursor

    for p in prefixes:
        sized_bytes, sized_keys, big = st.partial.get(p, [0, 0, 0])
        largest = max(big, st.largest.get(p, 0))
        unsized = max(keys[p] - sized_keys, 0)
        if keys[p] > MAX_KEYS_PER_TENANT:
            usage.too_many_keys.add(p)
        if unsized and not largest:
            continue  # nothing sized yet for it: no estimate this run
        usage.bytes[p] = float(sized_bytes + unsized * largest)
    if usage.cycle_complete:
        st.largest = {p: v[2] for p, v in st.partial.items()}
        st.partial = {}
    admin.call("SET", STATE_KEY, dump_state(st))
    return usage


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


def vault_login(addr: str, role: str, jwt_file: str, timeout: float = 10.0) -> str:
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
    except (OSError, urllib.error.URLError, KeyError, TypeError, ValueError) as exc:
        raise SyncError(f"Vault unreachable or refused: {type(exc).__name__}: {exc}") from None
    if not isinstance(token, str):
        raise SyncError("Vault login gave no token")
    return token


def vault_read(addr: str, token: str, path: str, timeout: float = 10.0) -> dict[str, object]:
    try:
        read = urllib.request.Request(f"{addr}/v1/{path}", headers={"X-Vault-Token": token})
        with urllib.request.urlopen(read, timeout=timeout) as resp:
            data = json.load(resp)["data"]["data"]
    except (OSError, urllib.error.URLError, KeyError, TypeError, ValueError) as exc:
        raise SyncError(f"Vault unreachable or refused: {type(exc).__name__}: {exc}") from None
    if not isinstance(data, dict):
        raise SyncError("Vault secret is not an object")
    return data


def vault_passwords(addr: str, role: str, path: str, jwt_file: str, timeout: float = 10.0) -> dict[str, str]:
    data = vault_read(addr, vault_login(addr, role, jwt_file, timeout), path, timeout)
    # A value that is not a string becomes "", which render() refuses as
    # malformed, as before.
    return {k: v if isinstance(v, str) else "" for k, v in data.items()}


# --- metrics -------------------------------------------------------------------


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def kv_metrics_text(gauges: dict[str, float], labelled: dict[str, dict[tuple[str, str], float]]) -> str:
    """Key Value series, labelled with Cloud's own project and service names."""
    out: list[str] = []
    for name, value in gauges.items():
        out += [f"# TYPE {name} gauge", f"{name} {value}"]
    for name, series in labelled.items():
        out.append(f"# TYPE {name} gauge")
        out += [
            f'{name}{{project="{escape_label(p)}",service="{escape_label(svc)}"}} {value}'
            for (p, svc), value in sorted(series.items())
        ]
    return "\n".join(out) + "\n"


def metrics_text(gauges: dict[str, float], labelled: dict[str, dict[str, float]]) -> str:
    out: list[str] = []
    for name, value in gauges.items():
        out += [f"# TYPE {name} gauge", f"{name} {value}"]
    for name, series in labelled.items():
        out.append(f"# TYPE {name} gauge")
        out += [f'{name}{{user="{escape_label(user)}"}} {value}' for user, value in sorted(series.items())]
    return "\n".join(out) + "\n"


def push_metrics(url: str, body: str, timeout: float = 10.0, method: str = "POST") -> None:
    # POST replaces only the metric names sent, so a failed run that sends
    # no last_success keeps the previous one. PUT replaces the whole group:
    # the Key Value groups use it, so a vanished tenant's series go.
    req = urllib.request.Request(url, data=body.encode(), method=method, headers={"Content-Type": "text/plain"})
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
    # Key Value tenants (B27). tenants_fetch_ok is None when the run had no
    # tenant route to ask.
    tenants_fetch_ok: bool | None = None
    tenants_error: str = ""
    tenants_warnings: list[str] = field(default_factory=list)
    foreign_users: list[str] | None = None
    kv_ready: dict[tuple[str, str], float] = field(default_factory=dict)
    kv_full: dict[tuple[str, str], float] = field(default_factory=dict)
    # Each tenant's clients from this run's CLIENT LIST, 0 for none.
    kv_connections: dict[tuple[str, str], float] = field(default_factory=dict)
    measured: bool = False
    measure_cycle_complete: bool = False
    measure_error: str = ""
    kv_bytes: dict[tuple[str, str], float] = field(default_factory=dict)
    kv_keys: dict[tuple[str, str], float] = field(default_factory=dict)
    purged: int = 0
    memory_usage_calls: int = 0


def plan_tenants(
    result: "Result",
    current: dict[str, str],
    users_rules: dict[str, str],
    fetch_tenants: Callable[[], object] | None,
) -> tuple[list[Tenant], set[str], TenantAnswer | None]:
    """The tenants this run wants, which of them are full, and the answer.

    The route's answer when it is good; otherwise the tenants Redis already
    holds, unchanged, so a Cloud outage drops nobody. Full or normal comes
    from ACL LIST: the ACL is the only state kept between runs, and only a
    measurement (measure_tenants, after the ACL is applied) changes it."""
    answer: TenantAnswer | None = None
    if fetch_tenants is not None:
        try:
            answer = parse_tenant_answer(fetch_tenants())
            result.tenants_fetch_ok = True
            result.tenants_warnings = answer.warnings
        except SyncError as exc:
            result.tenants_fetch_ok = False
            result.tenants_error = str(exc)
    tenants = answer.tenants if answer is not None else tenants_from_acl(current)
    names = {t.name for t in tenants}
    result.foreign_users = foreign_users(current, set(users_rules) if isinstance(users_rules, dict) else set(), names)
    return tenants, full_users(current) & names, answer


def measure_tenants(
    result: "Result",
    admin: Redis,
    before: dict[str, str],
    tenants: list[Tenant],
    full: set[str],
    answer: TenantAnswer | None,
    extra: str = "",
) -> set[str]:
    """Measure, purge, and switch tenants between normal and full. Runs after
    the infra users are applied and checked; any fault here is recorded in
    result.measure_error and leaves the run ok, with the modes as they were.
    Returns the full set in force afterwards."""
    # Purge only on a fresh answer, never a live tenant's prefix, and only
    # once no tenant user held that prefix at the start of this run (the
    # user goes first, in an earlier run).
    held = {m.group(1) for line in before.values() for m in [TENANT_KEYS_RE.search(line)] if m}
    live = {t.prefix for t in tenants}
    purge = {p for p in (answer.purge if answer is not None else []) if p not in live and p not in held}
    try:
        usage = measure(admin, live, purge)
        result.measured = True
        result.purged = usage.purged
        result.memory_usage_calls = usage.memory_usage_calls
        result.measure_cycle_complete = usage.cycle_complete
        wanted = set(full)
        for t in tenants:
            key = (t.project, t.service)
            result.kv_keys[key] = float(usage.keys.get(t.prefix, 0))
            if t.prefix in usage.too_many_keys:
                wanted.add(t.name)
            if t.prefix not in usage.bytes:
                continue
            result.kv_bytes[key] = float(usage.bytes[t.prefix])
            if t.prefix in usage.too_many_keys:
                continue
            if t.max_bytes is not None:
                if result.kv_bytes[key] > t.max_bytes:
                    wanted.add(t.name)
                else:
                    wanted.discard(t.name)
        changed = [t for t in tenants if (t.name in wanted) != (t.name in full)]
        if changed:
            users = [tenant_user(t, t.name in wanted, extra) for t in changed]
            replies = admin.transaction([["ACL", "SETUSER", u.name, *u.setuser_args] for u in users])
            admin.call("ACL", "SAVE")
            refused = [str(r) for r in replies if isinstance(r, RedisError)]
            if refused:
                raise SyncError(f"Redis refused a Key Value mode change: {refused[0]}")
        return wanted
    except (SyncError, RedisError, OSError, ConnectionError) as exc:
        result.measure_error = f"{type(exc).__name__}: {exc}"
        return full


def run(
    users_rules: dict[str, str],
    fetch_passwords: Callable[[], dict[str, str]],
    connect: RedisFactory,
    default_ips: Callable[[], set[str]] = set,
    fetch_tenants: Callable[[], object] | None = None,
    measure: bool = False,
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

        acl_list = admin.call("ACL", "LIST")
        current = parse_acl_list(acl_list if isinstance(acl_list, list) else [])
        categories = admin.call("ACL", "CAT")
        if not isinstance(categories, list) or not categories:
            # An empty module part would drop the module denials: fail
            # before writing anything.
            raise SyncError(f"unexpected ACL CAT reply: {str(categories)[:80]!r}")
        extra = module_denials({str(c) for c in categories})
        tenants, full, answer = plan_tenants(result, current, users_rules, fetch_tenants)
        tenant_users = [tenant_user(t, t.name in full, extra) for t in tenants]

        desired = render(users_rules, passwords, tenant_users)
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
        for t in tenants:
            # Ready: the user is in Redis with this password and prefix,
            # normal or full (a mode change below keeps it ready).
            found = parse_tenant_line(after.get(t.name, ""))
            ok = found is not None and found[0].password_sha256 == t.password_sha256 and found[0].prefix == t.prefix
            result.kv_ready[(t.project, t.service)] = 1.0 if ok else 0.0

        for name, user in desired.items():
            if user.password is not None:
                result.auth[name] = 1.0 if auth_ok(connect, user) else 0.0
        failed = sorted(n for n, v in result.auth.items() if v != 1.0)
        if failed:
            raise SyncError(f"AUTH and PING failed for: {', '.join(failed)}")
        # The infra users are applied and checked; the measurement comes
        # last, so its faults never skip or fail them.
        if measure:
            full = measure_tenants(result, admin, current, tenants, full, answer, extra)
        for t in tenants:
            result.kv_full[(t.project, t.service)] = 1.0 if t.name in full else 0.0
            result.kv_connections[(t.project, t.service)] = float(result.counts.get(t.name, 0))
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
    vault_addr = env.get("VAULT_ADDR", "http://vault-active.vault.svc.cluster.local:8200")
    sa_token_file = env.get("SA_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")
    vault_tokens: list[str] = []

    def vault_token() -> str:
        # One login a run, shared by the passwords and the tenants token.
        if not vault_tokens:
            vault_tokens.append(vault_login(vault_addr, env.get("VAULT_ROLE", "redis-acl-sync"), sa_token_file))
        return vault_tokens[0]

    def fetch_passwords() -> dict[str, str]:
        data = vault_read(vault_addr, vault_token(), env.get("VAULT_SECRET_PATH", "secret/data/redis/users"))
        return {k: v if isinstance(v, str) else "" for k, v in data.items()}

    def fetch_tenants() -> object:
        token = vault_read(vault_addr, vault_token(), env.get("CLOUD_TENANTS_TOKEN_PATH", "secret/data/redis/cloud-tenants")).get("token")
        return fetch_tenant_answer(
            env.get("CLOUD_TENANTS_URL", "http://cloud-reconciler.cloud.svc.cluster.local:9091/internal/redis-tenants"),
            token if isinstance(token, str) else "",
        )

    started = time.time()
    result = run(
        users_rules,
        fetch_passwords=fetch_passwords,
        connect=lambda: Redis(host, port),
        default_ips=lambda: namespace_pod_ips(
            [n for n in env.get("DEFAULT_USER_NAMESPACES", "").split(",") if n],
            kube_api,
            env.get("SA_TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token"),
            env.get("SA_CA_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"),
        ),
        fetch_tenants=fetch_tenants,
        measure=measure_due(started, int(env.get("KV_MEASURE_EVERY_SECONDS", str(MEASURE_EVERY_SECONDS)))),
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
    if result.tenants_fetch_ok is not None:
        gauges["cloud_kv_tenants_fetch_ok"] = 1.0 if result.tenants_fetch_ok else 0.0
    if result.tenants_error:
        print(f"warning: kept the tenants Redis holds: {result.tenants_error}", file=sys.stderr)
    for warning in result.tenants_warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if result.foreign_users is not None:
        gauges["redis_acl_foreign_users"] = float(len(result.foreign_users))
        for name in result.foreign_users:
            print(f"foreign ACL user (removed this run): {name}", file=sys.stderr)
    if result.measure_error:
        print(f"warning: Key Value measurement failed: {result.measure_error}", file=sys.stderr)
    if result.ok:
        gauges["redis_acl_sync_last_success_timestamp_seconds"] = now
        gauges["redis_acl_sync_changes"] = float(result.changes)
        gauges["redis_acl_sync_users"] = float(len(result.auth) + 1)

    if result.ok:
        print(f"ok: {result.changes} change(s), {len(result.auth)} users AUTH and PING, clients by user {result.counts}")
    else:
        print(f"FAILED, nothing more changed: {result.error}", file=sys.stderr)
    pushes = [(env.get("PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/redis-acl-sync"), metrics_text(gauges, labelled), "POST")]
    # Key Value series in their own groups, replaced whole (PUT), so a
    # tenant that went away loses its series. State after every good run;
    # usage after every good measurement, so between measurements the last
    # numbers stay.
    if result.ok:
        state = kv_metrics_text(
            {"cloud_kv_tenants": float(len(result.kv_full))},
            {"cloud_kv_ready": result.kv_ready, "cloud_kv_full": result.kv_full, "cloud_kv_connections": result.kv_connections},
        )
        pushes.append((env.get("PUSHGATEWAY_KV_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/redis-acl-sync-kv"), state, "PUT"))
    if result.ok and result.measured:
        usage = kv_metrics_text(
            {
                "cloud_kv_measured_timestamp_seconds": started,
                "cloud_kv_purged_keys": float(result.purged),
                "cloud_kv_memory_usage_calls": float(result.memory_usage_calls),
            },
            {"cloud_kv_bytes": result.kv_bytes, "cloud_kv_keys": result.kv_keys},
        )
        pushes.append((env.get("PUSHGATEWAY_KV_USAGE_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/redis-acl-sync-kv-usage"), usage, "PUT"))
    for url, body, method in pushes:
        try:
            push_metrics(url, body, method=method)
        except (OSError, urllib.error.URLError) as exc:
            print(f"pushgateway push failed: {exc}", file=sys.stderr)
            return 1
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
