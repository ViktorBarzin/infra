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
import sys
from dataclasses import dataclass, field
from typing import Iterable

import yaml

BASE_PORT = 3773
VALID_TIERS = ("admin", "power-user", "namespace-owner")
# Tier -> supplementary groups the reconcile ENSURES (additive-only; never stripped).
TIER_GROUPS: dict[str, tuple[str, ...]] = {
    "admin": ("code-shared", "docker", "sudo"),
    "power-user": (),
    "namespace-owner": (),
}
DEFAULT_SHELL = "/bin/zsh"
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


@dataclass(frozen=True)
class DesiredState:
    accounts: dict[str, Account]
    ttyd_user_map: str
    dispatch: dict[str, dict]
    ports: dict[str, int]


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
    return User(os_user, spec["authentik_user"], spec["k8s_user"], tier, namespaces)


def load_roster(text: str) -> Roster:
    data = yaml.safe_load(text) or {}
    users_raw = data.get("users") or {}
    return Roster({name: _parse_user(name, spec) for name, spec in users_raw.items()})


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


def _allocate_ports(roster: Roster, existing_ports: dict[str, int]) -> dict[str, int]:
    ports = {u: existing_ports[u] for u in roster.users if u in existing_ports}
    used = set(ports.values())
    for os_user in sorted(roster.users):
        if os_user in ports:
            continue
        candidate = BASE_PORT
        while candidate in used:
            candidate += 1
        ports[os_user] = candidate
        used.add(candidate)
    return ports


_TTYD_MAP_HEADER = (
    "# Generated from roster.yaml by roster_engine.py — DO NOT EDIT BY HAND.\n"
    "# <authentik_user>=<os_user>; consumed by t3-dispatch.\n"
)


def derive_desired_state(
    roster: Roster, existing_ports: dict[str, int]
) -> DesiredState:
    ports = _allocate_ports(roster, existing_ports)
    ordered = sorted(roster.users.values(), key=lambda u: ports[u.os_user])
    ttyd_lines = [f"{u.authentik_user}={u.os_user}" for u in ordered]
    ttyd_user_map = _TTYD_MAP_HEADER + "\n".join(ttyd_lines) + "\n"
    dispatch = {
        u.authentik_user: {"os_user": u.os_user, "port": ports[u.os_user]}
        for u in ordered
    }
    accounts = {
        u.os_user: Account(
            os_user=u.os_user,
            tier=u.tier,
            shell=DEFAULT_SHELL,
            login_locked=True,
            groups=TIER_GROUPS[u.tier],
        )
        for u in roster.users.values()
    }
    return DesiredState(accounts, ttyd_user_map, dispatch, ports)


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
            }
            for name, a in ds.accounts.items()
        },
        "ttyd_user_map": ds.ttyd_user_map,
        "dispatch": ds.dispatch,
        "ports": ds.ports,
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
    pd.add_argument("--ports-json", required=True, help="JSON map {os_user: port}")
    args = parser.parse_args(argv)

    roster = load_roster_file(args.roster)
    if args.cmd == "validate":
        with open(args.k8s_users_json, encoding="utf-8") as fh:
            issues = validate_tiers(roster, json.load(fh))
        for issue in issues:
            print(f"{issue.severity.upper()}: {issue.message}", file=sys.stderr)
        return 1 if has_blocking_errors(issues) else 0
    with open(args.ports_json, encoding="utf-8") as fh:
        desired = derive_desired_state(roster, json.load(fh))
    json.dump(_desired_state_to_dict(desired), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
