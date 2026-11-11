#!/usr/bin/env python3
"""Pure derivation + offboarding-diff engine for the devvm Workstation roster.

Functional core (this module, unit-tested) / imperative shell (the bash
provisioner that consumes the JSON this emits and performs the host mutations).
No host I/O lives in the tested functions. See PRD ViktorBarzin/infra#9.

The roster (`roster.yaml`) is the single source of truth for the workstation
lifecycle. `os_user` is the pinned key; `authentik_user` / `k8s_user` differ
per person and are recorded explicitly (no email->username derivation).
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from typing import Iterable

import yaml

BASE_PORT = 3773
# The ports a t3-serve may listen on. The devvm firewall (playbooks/devvm.yml,
# table devvm_lobby) admits only Traefik and loopback to 3773-3780, and 3780 is
# t3-dispatch itself, so a T3 port outside this range would either be open to
# the LAN or collide with the dispatch.
T3_PORT_MAX = 3779
# t3_host is the first DNS label of the user's T3 host (t3 -> t3.viktorbarzin.me).
_T3_HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
# Per-user playwright-mcp HTTP port (the browser MCP each user's Claude sessions
# connect to). Distinct range from T3_PORT, allocated for EVERY roster user incl.
# the admin (wizard is listed). Sticky from existing, so the live in-session
# assignments (wizard 8931, emo 8932, ancamilea 8933) are preserved across
# reconciles once seeded; a fresh box allocates from 8931 in sorted order.
PLAYWRIGHT_BASE_PORT = 8931
VALID_TIERS = ("admin", "power-user", "namespace-owner")
# single    - ~/code IS the locked infra clone (the original non-admin layout)
# workspace - ~/code is a plain directory of per-project clones; the locked
#             infra clone lives at ~/code/infra and `repos` clone alongside it
VALID_CODE_LAYOUTS = ("single", "workspace")
# Repo names become root-executed clone/mv paths under ~/code — plain
# leading-alphanumeric names only (no separators, dotfiles, or option-like names).
# A `repos` entry is either `name` (Forgejo viktor/<name>) or `owner/name`, with
# both parts held to the same rule; either way it clones to ~/code/<name>.
_REPO_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def _is_owned_repo(value: object) -> bool:
    """True for exactly `owner/name`, each part a plain repo name."""
    if not isinstance(value, str) or value.count("/") != 1:
        return False
    owner, name = value.split("/")
    return bool(_REPO_NAME_RE.match(owner) and _REPO_NAME_RE.match(name))


def repo_dir(repo: str) -> str:
    """The directory under ~/code a `repos` entry clones to: its name part."""
    return repo.rsplit("/", 1)[-1]
# Tier -> supplementary groups the reconcile ENSURES (additive-only; never stripped).
# codex-shared reads the shared ChatGPT login in /opt/codex-shared (the codex
# wrapper in playbooks/devvm.yml); admins and power users had it by hand until
# 2026-11-11, so a rebuilt box now gives it to the same people.
TIER_GROUPS: dict[str, tuple[str, ...]] = {
    "admin": ("code-shared", "codex-shared", "docker", "sudo"),
    "power-user": ("codex-shared",),
    "namespace-owner": (),
}
# Groups a roster row may add beyond its tier's (`extra_groups`). docker is
# root-equivalent, so it is granted per person in a reviewed diff rather than
# by tier; emo keeps it (Viktor, 2026-11-11). sudo and code-shared stay
# tier: admin's alone.
EXTRA_GROUPS_ALLOWED: tuple[str, ...] = ("docker",)
DEFAULT_SHELL = "/bin/zsh"
# The FLOOR a membership-driven provision lands on: the least privilege that
# still makes the box useful, and the same default provision-user.yml already
# writes into Vault k8s_users. Anything above it — power-user, admin, extra
# namespaces, repos — needs a reviewed commit, and validate_tiers still checks
# it against the cluster.
FLOOR_TIER = "namespace-owner"
FLOOR_CODE_LAYOUT = "workspace"
# A unix account name derived from an Authentik identity. The identity itself is
# never rewritten (it is the login, and /etc/ttyd-user-map keys on it); this is
# only the OS name that carries it.
_OS_NAME_SAFE = re.compile(r"[^a-z0-9_-]")
_REVERSIBLE_OFFBOARD_KINDS = (
    "disable_instance",
    "unmap_dispatch",
    "remove_from_t3_group",
    "lock_login",
    "revoke_cluster_rbac",
)


class RosterError(ValueError):
    """Raised when the roster is structurally invalid."""


@dataclass(frozen=True)
class User:
    os_user: str
    authentik_user: str
    k8s_user: str
    tier: str
    namespaces: tuple[str, ...] = ()
    code_layout: str = "single"
    repos: tuple[str, ...] = ()
    # Whether this user gets the per-user claude-auth-sync timer. Default True:
    # everyone provisioned here is expected to use Claude. Set false for a
    # roster member who has an account but does not use Claude on this box —
    # the timer validates a credential that was never created, so it fails
    # every ~6h forever and raises WorkstationClaudeAuthInvalid with nothing
    # to fix. Reversible: flip back to true and the next reconcile re-enables.
    claude_auth: bool = True
    # Parked: the account and everything on disk stay, but NONE of the per-user
    # daemons run (t3-serve, playwright-mcp, playwright-snapshot-refresh,
    # claude-auth-sync). For someone who has an account here but is not using
    # the box — those daemons otherwise sit running indefinitely on a shared
    # VM, and a credential timer among them alerts forever with nothing to fix.
    # Deliberately reversible: flip to false and the next reconcile brings the
    # whole set back, because nothing was removed.
    parked: bool = False
    # Pinned T3 port and host label. Terraform (stacks/t3code) builds a T3 host
    # only for rows that have both, and routes that host's native requests
    # straight to the port, so the port is written here rather than chosen on
    # the box. A row without t3_port keeps the sticky allocation.
    t3_port: int | None = None
    t3_host: str | None = None
    # Forgejo `owner/name` whose master holds this user's AGENTS.md, which the
    # provisioner installs as ~/.agents/AGENTS.md. Each user's file is in a
    # private repo of their own, so one user cannot read another's.
    agents_repo: str | None = None
    # Forgejo `owner/name` of the user's chezmoi source, which the provisioner
    # applies once on a new box (`chezmoi init --apply`).
    dotfiles: str | None = None
    # Groups from EXTRA_GROUPS_ALLOWED this user gets on top of the tier's.
    extra_groups: tuple[str, ...] = ()


@dataclass(frozen=True)
class Roster:
    users: dict[str, User] = field(default_factory=dict)


@dataclass(frozen=True)
class Account:
    os_user: str
    tier: str
    shell: str
    login_locked: bool
    groups: tuple[str, ...]
    code_layout: str = "single"
    repos: tuple[str, ...] = ()
    claude_auth: bool = True
    parked: bool = False
    # The Authentik username, carried through because a per-user credential
    # minted against a service has to name the identity that owns it, not the
    # OS account. browser-bridge's CLI token is the first such credential;
    # everything before it keyed on os_user alone. Defaulted so an older
    # caller constructing Account positionally keeps working.
    authentik_user: str = ""
    agents_repo: str | None = None
    dotfiles: str | None = None


@dataclass(frozen=True)
class DesiredState:
    accounts: dict[str, Account]
    ttyd_user_map: str
    dispatch: dict[str, dict]
    ports: dict[str, int]
    playwright_ports: dict[str, int] = field(default_factory=dict)
    # /etc/ttyd-admins — who administers this box, one OS user per line.
    # Defaulted so an older caller constructing DesiredState positionally keeps
    # working; derive_desired_state always fills it.
    ttyd_admins: str = ""
    # /etc/sudoers.d/ttyd-users — the grant letting the service user become each
    # other user. Defaulted for the same reason as ttyd_admins.
    ttyd_sudoers: str = ""


@dataclass(frozen=True)
class OffboardAction:
    os_user: str
    kind: str
    reversible: bool


# --------------------------------------------------------------------------
# Parsing + structural validation
# --------------------------------------------------------------------------


def _parse_user(os_user: str, spec: dict) -> User:
    for required in ("authentik_user", "k8s_user", "tier"):
        if required not in spec:
            raise RosterError(f"user {os_user!r}: missing required field {required!r}")
    tier = spec["tier"]
    if tier not in VALID_TIERS:
        raise RosterError(
            f"user {os_user!r}: unknown tier {tier!r} (valid: {list(VALID_TIERS)})"
        )
    namespaces = tuple(spec.get("namespaces") or ())
    if tier == "namespace-owner" and not namespaces:
        raise RosterError(f"user {os_user!r}: namespace-owner requires namespaces")
    if tier != "namespace-owner" and namespaces:
        raise RosterError(f"user {os_user!r}: only namespace-owner may set namespaces")
    code_layout = spec.get("code_layout", "single")
    if code_layout not in VALID_CODE_LAYOUTS:
        raise RosterError(
            f"user {os_user!r}: unknown code_layout {code_layout!r} "
            f"(valid: {list(VALID_CODE_LAYOUTS)})"
        )
    repos = tuple(spec.get("repos") or ())
    if repos and code_layout != "workspace":
        raise RosterError(f"user {os_user!r}: repos require code_layout: workspace")
    for repo in repos:
        if not (
            isinstance(repo, str) and (_REPO_NAME_RE.match(repo) or _is_owned_repo(repo))
        ):
            raise RosterError(f"user {os_user!r}: unsafe repo name {repo!r}")
    dirs = [repo_dir(r) for r in repos]
    if "infra" in dirs:
        raise RosterError(
            f"user {os_user!r}: infra is implicit at ~/code/infra — drop it from repos"
        )
    if len(set(dirs)) != len(dirs):
        raise RosterError(
            f"user {os_user!r}: two repos clone to the same directory under ~/code"
        )
    agents_repo = spec.get("agents_repo")
    if agents_repo is not None and not _is_owned_repo(agents_repo):
        raise RosterError(
            f"user {os_user!r}: agents_repo must be a Forgejo owner/name, "
            f"got {agents_repo!r}"
        )
    dotfiles = spec.get("dotfiles")
    if dotfiles is not None and not _is_owned_repo(dotfiles):
        raise RosterError(
            f"user {os_user!r}: dotfiles must be a Forgejo owner/name, got {dotfiles!r}"
        )
    extra_groups = spec.get("extra_groups") or []
    if not isinstance(extra_groups, list) or any(
        g not in EXTRA_GROUPS_ALLOWED for g in extra_groups
    ):
        raise RosterError(
            f"user {os_user!r}: extra_groups must be a list of "
            f"{list(EXTRA_GROUPS_ALLOWED)}, got {extra_groups!r}"
        )
    claude_auth = spec.get("claude_auth", True)
    if not isinstance(claude_auth, bool):
        raise RosterError(
            f"user {os_user!r}: claude_auth must be true or false, got {claude_auth!r}"
        )
    parked = spec.get("parked", False)
    if not isinstance(parked, bool):
        raise RosterError(
            f"user {os_user!r}: parked must be true or false, got {parked!r}"
        )
    t3_port = spec.get("t3_port")
    if t3_port is not None and (
        type(t3_port) is not int or not BASE_PORT <= t3_port <= T3_PORT_MAX
    ):
        raise RosterError(
            f"user {os_user!r}: t3_port must be an integer from {BASE_PORT} to "
            f"{T3_PORT_MAX}, got {t3_port!r}"
        )
    t3_host = spec.get("t3_host")
    if t3_host is not None:
        if not isinstance(t3_host, str) or not _T3_HOST_RE.match(t3_host):
            raise RosterError(
                f"user {os_user!r}: t3_host must be one lowercase DNS label "
                f"(t3 for t3.viktorbarzin.me), got {t3_host!r}"
            )
        if t3_port is None:
            raise RosterError(
                f"user {os_user!r}: t3_host needs a pinned t3_port, which "
                f"Terraform routes the host's native requests to"
            )
    return User(
        os_user,
        spec["authentik_user"],
        spec["k8s_user"],
        tier,
        namespaces,
        code_layout,
        repos,
        claude_auth,
        parked,
        t3_port,
        t3_host,
        agents_repo,
        dotfiles,
        tuple(sorted(set(extra_groups))),
    )


def _refuse_duplicates(users: dict[str, User], attr: str) -> None:
    seen: dict[object, str] = {}
    for name in sorted(users):
        value = getattr(users[name], attr)
        if value is None:
            continue
        if value in seen:
            raise RosterError(
                f"users {seen[value]!r} and {name!r} both set {attr}: {value}"
            )
        seen[value] = name


def load_roster(text: str) -> Roster:
    data = yaml.safe_load(text) or {}
    users_raw = data.get("users") or {}
    users = {name: _parse_user(name, spec) for name, spec in users_raw.items()}
    _refuse_duplicates(users, "t3_port")
    _refuse_duplicates(users, "t3_host")
    return Roster(users)


def load_roster_file(path: str) -> Roster:
    with open(path, encoding="utf-8") as fh:
        return load_roster(fh.read())


# --------------------------------------------------------------------------
# Tier validation against live k8s_users (fail-loud)
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class ValidationIssue:
    os_user: str
    severity: str  # "error" = tier conflict (abort) | "warn" = absent (grant pending)
    message: str


def validate_tiers(
    roster: Roster, k8s_user_tiers: dict[str, str]
) -> list[ValidationIssue]:
    """Compare each roster user's tier against the live `k8s_users` map. A real
    conflict (roster tier != cluster tier) is an "error" (abort). A net-new user
    not yet in `k8s_users` is a "warn" (onboarding proceeds; the kubectl grant is
    pending). Admins are exempt (cluster-admin is granted out of band). An empty
    list means the roster is consistent with the cluster."""
    issues = []
    for user in roster.users.values():
        if user.tier == "admin":
            continue
        actual = k8s_user_tiers.get(user.k8s_user)
        if actual is None:
            issues.append(
                ValidationIssue(
                    user.os_user,
                    "warn",
                    f"{user.os_user}: tier {user.tier} but k8s_user {user.k8s_user!r} "
                    f"absent from k8s_users (kubectl grant pending — add the entry)",
                )
            )
        elif actual != user.tier:
            issues.append(
                ValidationIssue(
                    user.os_user,
                    "error",
                    f"{user.os_user}: roster tier {user.tier} != k8s_users tier "
                    f"{actual} for {user.k8s_user!r}",
                )
            )
    return issues


def has_blocking_errors(issues: list[ValidationIssue]) -> bool:
    return any(issue.severity == "error" for issue in issues)


# --------------------------------------------------------------------------
# Desired-state derivation (sticky ports, ttyd map, dispatch, accounts)
# --------------------------------------------------------------------------


def _allocate_ports(
    roster: Roster,
    existing_ports: dict[str, int],
    base: int = BASE_PORT,
    pinned: dict[str, int] | None = None,
    limit: int | None = None,
) -> dict[str, int]:
    """Sticky port allocation: pinned ports first, then keep every other roster
    user's existing port unless a pin took it, then assign each remaining user
    the next free port from `base` (never past `limit`). Used for both T3_PORT
    (base 3773, pins from t3_port) and the per-user playwright-mcp port (base
    8931)."""
    ports = dict(pinned or {})
    used = set(ports.values())
    for u in sorted(roster.users):
        if u in ports or u not in existing_ports or existing_ports[u] in used:
            continue
        ports[u] = existing_ports[u]
        used.add(existing_ports[u])
    for os_user in sorted(roster.users):
        if os_user in ports:
            continue
        candidate = base
        while candidate in used:
            candidate += 1
        if limit is not None and candidate > limit:
            raise RosterError(
                f"no free T3 port for {os_user!r}: {base}-{limit} are all taken"
            )
        ports[os_user] = candidate
        used.add(candidate)
    return ports


_TTYD_MAP_HEADER = (
    "# Generated from roster.yaml by roster_engine.py — DO NOT EDIT BY HAND.\n"
    "# <authentik_user>=<os_user>; consumed by t3-dispatch.\n"
)

# /etc/ttyd-admins — the admin list terminal-lobby's act-as switch reads
# (docs: terminal-lobby docs/plans/2026-08-16-admin-act-as-user-design.md).
#
# It cannot come from Authentik group membership: every devvm user is in
# "Home Server Admins", because that is what lets them reach the lobby host at
# all. The roster tier is what actually distinguishes an administrator here, so
# the same reconcile that writes /etc/ttyd-user-map writes this beside it.
#
# One OS user per line; blanks and # comments ignored. An absent or empty file
# means no admins, so the feature is unavailable rather than open.
_TTYD_ADMINS_HEADER = (
    "# Generated from roster.yaml by roster_engine.py — DO NOT EDIT BY HAND.\n"
    "# OS users with tier: admin. Consumed by terminal-lobby's act-as switch\n"
    "# (tmux-api, file-api, clipboard-upload, session-events).\n"
)


# The service user runs ttyd and the API services (User=wizard in every unit),
# so it is the LEFT side of every grant and never a target of one.
TTYD_SERVICE_USER = "wizard"

# What the service may run AS another user. Named binaries, never ALL: this file
# is the boundary between two people's accounts on one box.
_TTYD_USER_COMMANDS = (
    "/usr/bin/tmux",
    "/usr/local/bin/tmux-user-attach",
    "/usr/local/bin/tmux-user-dirlist",
    "/usr/local/bin/file-api",
    "/usr/local/bin/session-events",
    "/usr/local/bin/skills-api",
)

# What it may run as root: the wrappers that need privilege of their own.
# Each validates its arguments against the user map, so the grant is narrow in
# what it can be pointed at as well as in what it can run.
_TTYD_ROOT_COMMANDS = (
    "/usr/local/bin/tmux-restore-user",
    "/usr/local/bin/tmux-user-setfacl",
    "/usr/local/bin/tmux-persist-forget",
    # Mints a one-time T3 pairing code as the named user, so the lobby can pair
    # a user's T3 app. Validates its argument against /etc/ttyd-user-map.
    "/usr/local/bin/t3-mint",
)

_TTYD_SUDOERS_HEADER = (
    "# Generated from roster.yaml by roster_engine.py — DO NOT EDIT BY HAND.\n"
    "# Install at /etc/sudoers.d/ttyd-users (mode 0440, owner root:root).\n"
    "#\n"
    "# Lets the user running ttyd and the API services become each OTHER mapped\n"
    "# user, for a fixed set of binaries. Never (ALL): this is the boundary\n"
    "# between two people's accounts on one machine.\n"
    "#\n"
    "# Derived rather than hand-maintained since 2026-08-29. A hand-maintained\n"
    "# copy has no offboarding: a roster row removed here stops producing a line,\n"
    "# so the next reconcile revokes the grant.\n"
)


def _ttyd_sudoers(os_users: list[str]) -> str:
    """The sudo grant, one line per non-service user plus the root wrappers."""
    lines = [
        f"{TTYD_SERVICE_USER} ALL=({u}) NOPASSWD: " + ", ".join(_TTYD_USER_COMMANDS)
        for u in sorted(os_users)
        if u != TTYD_SERVICE_USER
    ]
    lines.append(
        f"{TTYD_SERVICE_USER} ALL=(root) NOPASSWD: " + ", ".join(_TTYD_ROOT_COMMANDS)
    )
    return _TTYD_SUDOERS_HEADER + "".join(f"{l}\n" for l in lines)


def derive_desired_state(
    roster: Roster,
    existing_ports: dict[str, int],
    existing_playwright_ports: dict[str, int] | None = None,
) -> DesiredState:
    ports = _allocate_ports(
        roster,
        existing_ports,
        pinned={u.os_user: u.t3_port for u in roster.users.values() if u.t3_port},
        limit=T3_PORT_MAX,
    )
    playwright_ports = _allocate_ports(
        roster, existing_playwright_ports or {}, base=PLAYWRIGHT_BASE_PORT
    )
    ordered = sorted(roster.users.values(), key=lambda u: ports[u.os_user])
    ttyd_lines = [f"{u.authentik_user}={u.os_user}" for u in ordered]
    ttyd_user_map = _TTYD_MAP_HEADER + "\n".join(ttyd_lines) + "\n"
    # Sorted by name, not by port like the map above: this file is read by
    # people as often as by services, and its order carries no meaning.
    admin_lines = sorted(u.os_user for u in ordered if u.tier == "admin")
    ttyd_admins = _TTYD_ADMINS_HEADER + "".join(f"{u}\n" for u in admin_lines)
    # host is what t3-dispatch keys on: a request for <host>.viktorbarzin.me
    # is served only to the Authentik user who owns that host. A row without a
    # t3_host has no web host, so its entry carries no host.
    dispatch = {
        u.authentik_user: {"os_user": u.os_user, "port": ports[u.os_user]}
        | ({"host": u.t3_host} if u.t3_host else {})
        for u in ordered
    }
    accounts = {
        u.os_user: Account(
            os_user=u.os_user,
            tier=u.tier,
            shell=DEFAULT_SHELL,
            login_locked=True,
            groups=tuple(sorted(set(TIER_GROUPS[u.tier]) | set(u.extra_groups))),
            code_layout=u.code_layout,
            repos=u.repos,
            claude_auth=u.claude_auth and not u.parked,
            parked=u.parked,
            authentik_user=u.authentik_user,
            agents_repo=u.agents_repo,
            dotfiles=u.dotfiles,
        )
        for u in roster.users.values()
    }
    ttyd_sudoers = _ttyd_sudoers([u.os_user for u in ordered])
    return DesiredState(
        accounts,
        ttyd_user_map,
        dispatch,
        ports,
        playwright_ports,
        ttyd_admins,
        ttyd_sudoers,
    )


def groups_to_add(desired: Iterable[str], current: Iterable[str]) -> list[str]:
    """Additive-only: the groups to `gpasswd -a`. Never proposes a removal, so a
    routine reconcile can't strip a pre-existing user's legacy groups."""
    return sorted(set(desired) - set(current))


# --------------------------------------------------------------------------
# Offboarding diff (staged: reversible cut, then gated destructive removal)
# --------------------------------------------------------------------------


def to_deprovision(old: Roster, new: Roster) -> list[str]:
    return sorted(set(old.users) - set(new.users))


def offboard_plan(
    old: Roster, new: Roster, *, include_destructive: bool
) -> list[OffboardAction]:
    """Staged offboarding actions for users dropped from the roster. The
    reversible cut (disable instance, unmap, lock, revoke RBAC) is always
    returned; the irreversible `userdel_archive` is included ONLY when
    explicitly requested, so it can never be auto-applied by a reconcile."""
    plan: list[OffboardAction] = []
    for os_user in to_deprovision(old, new):
        plan.extend(
            OffboardAction(os_user, kind, True) for kind in _REVERSIBLE_OFFBOARD_KINDS
        )
        if include_destructive:
            plan.append(OffboardAction(os_user, "userdel_archive", False))
    return plan


# --------------------------------------------------------------------------
# Membership sync — Authentik's T3 Users group is the one user list
# --------------------------------------------------------------------------
#
# The group carries one bit: is this person allowed on the box. The roster carries
# policy (tier, namespaces, layout, repos), which a group cannot express. So the
# roster is not a second user list — it is a policy table keyed by user, and a row
# for someone outside the group is inert.
#
# Everything here is pure: the CI pipeline reads the group, calls this, and writes
# what it returns. Keeping the diff and the file edits in the tested core is what
# keeps the pipeline a thin shell.


@dataclass(frozen=True)
class MembershipPlan:
    """What a group-vs-roster comparison implies.

    provision   — group members with no policy row: floor-tier rows to write
    deprovision — os_users whose row should be commented out (they left the group)
    protected   — os_users spared from deprovision because they administer this box
    conflicts   — group members whose derived OS name is already taken by someone
                  else; reported so a human decides, never resolved by guessing
    """

    provision: list["User"] = field(default_factory=list)
    deprovision: list[str] = field(default_factory=list)
    protected: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)


def authentik_local_part(name: str) -> str:
    """The part of an Authentik username the roster and /etc/ttyd-user-map key on.

    Usernames in this instance ARE emails (verified 2026-06-08), and every
    consumer strips the domain, so the comparison has to as well or every member
    reads as unknown."""
    return name.split("@", 1)[0]


def os_name_for(authentik_user: str) -> str:
    """A unix-safe account name for an Authentik identity.

    Lowercased, anything outside [a-z0-9_-] folded to `_`, and forced to start
    with a letter — `useradd` rejects the rest. Truncated to 32, the Linux limit.
    """
    name = _OS_NAME_SAFE.sub("_", authentik_local_part(authentik_user).lower())
    if not name or not name[0].isalpha():
        name = "u" + name
    return name[:32]


def floor_user(authentik_user: str) -> User:
    """The row a membership-driven provision writes: the floor tier, a namespace
    named after the user, and nothing else granted."""
    os_user = os_name_for(authentik_user)
    return User(
        os_user=os_user,
        authentik_user=authentik_local_part(authentik_user),
        k8s_user=os_user,
        tier=FLOOR_TIER,
        namespaces=(os_user,),
        code_layout=FLOOR_CODE_LAYOUT,
    )


def membership_plan(group_members: Iterable[str], roster: Roster) -> MembershipPlan:
    """Compare the group's membership against the roster's policy rows.

    ADMINS ARE NEVER DEPROVISIONED here. Membership is exactly what this would
    revoke, so an admin dropped from the group by accident could not reach the box
    to undo it. They are reported as `protected` instead, which is a visible state
    rather than a silent exception."""
    members = {authentik_local_part(m) for m in group_members}
    by_identity = {u.authentik_user: u for u in roster.users.values()}

    plan_provision: list[User] = []
    conflicts: list[str] = []
    for member in sorted(members):
        if member in by_identity:
            continue
        candidate = floor_user(member)
        taken = roster.users.get(candidate.os_user)
        if taken is not None and taken.authentik_user != member:
            conflicts.append(
                f"{member}: OS name {candidate.os_user!r} already belongs to "
                f"{taken.authentik_user!r} — pick a name and add the row by hand"
            )
            continue
        plan_provision.append(candidate)

    deprovision: list[str] = []
    protected: list[str] = []
    for os_user, user in sorted(roster.users.items()):
        if user.authentik_user in members:
            continue
        (protected if user.tier == "admin" else deprovision).append(os_user)

    return MembershipPlan(plan_provision, deprovision, protected, conflicts)


# --------------------------------------------------------------------------
# Roster text edits
# --------------------------------------------------------------------------
#
# The roster is edited as TEXT, not re-emitted from parsed YAML: the file is
# mostly comments — why a user is parked, what an offboarding did, which fields a
# tier implies — and a yaml.dump round-trip would drop every one of them. So a
# change touches only the line it is about, and the tests assert that.

_USERS_KEY = "users:"


def _user_line_index(lines: list[str], os_user: str) -> int:
    want = os_user + ":"
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue  # already commented out — not a live row
        if stripped.split()[0:1] == [want]:
            return i
    raise RosterError(f"{os_user!r} has no live row in the roster")


def comment_out_user(text: str, os_user: str, *, note: str) -> str:
    """Comment a user's row out, preserving it as a record, with `note` above it.

    Commented and absent read identically to the parser, so this IS removal as far
    as every consumer is concerned — while leaving the row one edit away from
    coming back, and leaving a dated line saying what happened."""
    lines = text.splitlines()
    i = _user_line_index(lines, os_user)
    indent = " " * (len(lines[i]) - len(lines[i].lstrip()))
    lines[i] = "# " + lines[i]
    lines.insert(i + 1, f"{indent}#  {note}")
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def _flow_row(user: User) -> str:
    fields = [
        f"authentik_user: {user.authentik_user}",
        f"k8s_user: {user.k8s_user}",
        f"tier: {user.tier}",
        f"namespaces: [{', '.join(user.namespaces)}]",
        f"code_layout: {user.code_layout}",
    ]
    return "{" + ", ".join(fields) + "}"


def append_user(text: str, user: User, *, note: str) -> str:
    """Add a policy row for `user` at the end of the `users:` block, with `note`.

    Refuses when a live row already exists: a second row for one person is a
    silent policy fork, and the caller asking for it has a stale view of the
    roster."""
    lines = text.splitlines()
    try:
        _user_line_index(lines, user.os_user)
    except RosterError:
        pass
    else:
        raise RosterError(f"{user.os_user!r} already has a live row in the roster")

    for i, line in enumerate(lines):
        if line.strip() == _USERS_KEY or line.startswith(_USERS_KEY):
            break
    else:
        raise RosterError("roster has no `users:` block to append to")

    # After the users: key, walk to the end of that block — the last line that is
    # indented (a row, or a comment sitting among the rows).
    end = i
    for j in range(i + 1, len(lines)):
        if lines[j].strip() == "":
            continue
        if lines[j][:1] in (" ", "\t") or lines[j].lstrip().startswith("#"):
            end = j
            continue
        break
    lines.insert(end + 1, f"  #  {note}")
    lines.insert(end + 2, f"  {user.os_user}: {_flow_row(user)}")
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


# --------------------------------------------------------------------------
# CLI adapter (imperative shell entrypoint — consumed by t3-provision-users.sh)
# --------------------------------------------------------------------------


def _desired_state_to_dict(ds: DesiredState) -> dict:
    return {
        "accounts": {
            name: {
                "os_user": a.os_user,
                "tier": a.tier,
                "shell": a.shell,
                "login_locked": a.login_locked,
                "groups": list(a.groups),
                "code_layout": a.code_layout,
                "repos": list(a.repos),
                "claude_auth": a.claude_auth,
                "parked": a.parked,
                "authentik_user": a.authentik_user,
                "agents_repo": a.agents_repo,
                "dotfiles": a.dotfiles,
            }
            for name, a in ds.accounts.items()
        },
        "ttyd_user_map": ds.ttyd_user_map,
        "ttyd_admins": ds.ttyd_admins,
        "ttyd_sudoers": ds.ttyd_sudoers,
        "dispatch": ds.dispatch,
        "ports": ds.ports,
        "playwright_ports": ds.playwright_ports,
    }


def _main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Workstation roster engine")
    sub = parser.add_subparsers(dest="cmd", required=True)
    pv = sub.add_parser(
        "validate", help="exit 1 if roster tiers diverge from k8s_users"
    )
    pv.add_argument("--roster", required=True)
    pv.add_argument("--k8s-users-json", required=True, help="JSON map {k8s_user: tier}")
    pd = sub.add_parser("derive", help="emit desired state as JSON")
    pd.add_argument("--roster", required=True)
    pd.add_argument("--ports-json", required=True, help="JSON map {os_user: T3_PORT}")
    pd.add_argument(
        "--playwright-ports-json",
        help="JSON map {os_user: PLAYWRIGHT_PORT} (optional; sticky allocation)",
    )
    pdp = sub.add_parser(
        "deprovision",
        help="name the os_users dropped from the roster since --old (one per line)",
    )
    pdp.add_argument("--old", required=True, help="the roster this box last applied")
    pdp.add_argument("--new", required=True, help="the roster now in effect")
    pm = sub.add_parser(
        "membership",
        help="diff the Authentik group against the roster's policy rows",
    )
    pm.add_argument("--roster", required=True)
    pm.add_argument(
        "--group-members-json",
        required=True,
        help="JSON list of Authentik usernames in the T3 Users group",
    )
    pm.add_argument(
        "--apply",
        action="store_true",
        help="rewrite the roster in place (default: report the plan only)",
    )
    pm.add_argument(
        "--note",
        default="",
        help="dated note written above each row this adds or comments out",
    )
    args = parser.parse_args(argv)

    if args.cmd == "deprovision":
        # A subcommand rather than something the shell imports: a module executed
        # outside sys.modules cannot resolve its own dataclass annotations, so a
        # hand-rolled importlib load of this file fails at import time.
        for os_user in to_deprovision(
            load_roster_file(args.old), load_roster_file(args.new)
        ):
            print(os_user)
        return 0

    if args.cmd == "membership":
        with open(args.group_members_json, encoding="utf-8") as fh:
            members = json.load(fh)
        with open(args.roster, encoding="utf-8") as fh:
            text = fh.read()
        plan = membership_plan(members, load_roster(text))
        for c in plan.conflicts:
            print(f"CONFLICT: {c}", file=sys.stderr)
        for p in plan.protected:
            print(
                f"PROTECTED: {p} administers this box and is not in the group — "
                "left in place deliberately",
                file=sys.stderr,
            )
        if args.apply:
            for user in plan.provision:
                text = append_user(text, user, note=args.note)
            for os_user in plan.deprovision:
                text = comment_out_user(text, os_user, note=args.note)
            if plan.provision or plan.deprovision:
                with open(args.roster, "w", encoding="utf-8") as fh:
                    fh.write(text)
        json.dump(
            {
                "provision": [
                    {"os_user": u.os_user, "authentik_user": u.authentik_user,
                     "tier": u.tier, "namespaces": list(u.namespaces)}
                    for u in plan.provision
                ],
                "deprovision": plan.deprovision,
                "protected": plan.protected,
                "conflicts": plan.conflicts,
                "applied": bool(args.apply and (plan.provision or plan.deprovision)),
            },
            sys.stdout,
            indent=2,
            sort_keys=True,
        )
        sys.stdout.write("\n")
        # Conflicts are a human's decision, not a failure of the sync: report
        # them, land whatever else was unambiguous, and exit non-zero so the
        # pipeline surfaces it.
        return 1 if plan.conflicts else 0

    roster = load_roster_file(args.roster)
    if args.cmd == "validate":
        with open(args.k8s_users_json, encoding="utf-8") as fh:
            issues = validate_tiers(roster, json.load(fh))
        for issue in issues:
            print(f"{issue.severity.upper()}: {issue.message}", file=sys.stderr)
        return 1 if has_blocking_errors(issues) else 0
    with open(args.ports_json, encoding="utf-8") as fh:
        existing_ports = json.load(fh)
    existing_playwright_ports = {}
    if args.playwright_ports_json:
        with open(args.playwright_ports_json, encoding="utf-8") as fh:
            existing_playwright_ports = json.load(fh)
    desired = derive_desired_state(roster, existing_ports, existing_playwright_ports)
    json.dump(_desired_state_to_dict(desired), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
