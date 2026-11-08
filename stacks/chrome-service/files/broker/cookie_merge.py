#!/usr/bin/env python3
"""Merge rules for cookies pushed back into a user's hub browser.

A hub is a cluster Chrome holding one person's logins. Their other browsers
(terminal-lobby session browsers, T3's browser, pool workers) start from a
copy of it, and push cookies they picked up back here, so a login made in any
of them reaches all of them.

The rules exist to make that safe. The person this protects most asked that
nothing ever signs him out, so:

- a pushed cookie replaces the hub's copy only when it expires LATER. A re-login
  or a rotation moves expiry forward; a stale copy from a long-lived session
  does not, so it cannot overwrite a newer login, and two browsers cannot flap;
- a cookie that disappeared from the hub before expiring (a sign-out there)
  leaves a tombstone, and only a cookie expiring after the tombstone may
  recreate it, so an old copy cannot undo the sign-out;
- a push may replace a site's cookies only when it carries every cookie the
  hub holds live for that site; a browser the site signed out lacks the login
  cookies, so its fresh anonymous ones can fill gaps but replace nothing;
- on protected domains a push can fill a missing cookie but never replace one,
  so a test login or a prompt-injected page cannot swap the hub's session;
- session cookies, expired cookies and cookies for our own hosts are never
  taken: they are per-browser state or belong to the homelab itself;
- nothing is ever deleted.

Stdlib only, like cdp_cookies.py beside it.
"""

from __future__ import annotations

import ipaddress
import json
from dataclasses import dataclass, field
from typing import Iterable

Cookie = dict
Key = tuple[str, str, str, str, bool]

DEFAULT_PROTECTED = (
    "google.com", "google.bg", "google.co.uk", "youtube.com",
    "fidelity.co.uk", "fidelity.com", "chess.com", "tripit.com",
)
DEFAULT_HUB_LIMIT = 3000
LOCAL_SUFFIXES = ("viktorbarzin.me", "lan", "local", "localhost")


def _bare(domain: str) -> str:
    return domain.lstrip(".").lower()


def _under(domain: str, suffix: str) -> bool:
    d = _bare(domain)
    return d == suffix or d.endswith("." + suffix)


_SECOND_LEVEL = {"co", "com", "org", "net", "ac", "gov", "edu", "ltd", "plc"}


def site_of(domain: str) -> str:
    """The registrable site a cookie domain belongs to (amazon.co.uk, google.com).

    An approximation of the public suffix list that is right for every domain in
    the hubs today: two labels, or three under a two-letter country code with a
    generic second level (co.uk, com.au).
    """
    labels = _bare(domain).split(".")
    if len(labels) >= 3 and len(labels[-1]) == 2 and labels[-2] in _SECOND_LEVEL:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])


def cookie_key(c: Cookie) -> Key:
    """Identity of a cookie: name, domain, path and its partition, if any."""
    partition = c.get("partitionKey") or ""
    if isinstance(partition, dict):
        top, cross = partition.get("topLevelSite", ""), bool(partition.get("hasCrossSiteAncestor"))
    else:
        top, cross = str(partition), bool(c.get("_crHasCrossSiteAncestor"))
    return (c.get("name", ""), c.get("domain", "").lower(), c.get("path", "/"), top, cross)


def is_local_host(domain: str) -> bool:
    d = _bare(domain)
    if not d:
        return True
    try:
        ipaddress.ip_address(d.strip("[]"))
        return True
    except ValueError:
        pass
    return any(_under(d, s) for s in LOCAL_SUFFIXES)


def _expires(c: Cookie) -> float:
    try:
        return float(c.get("expires", -1))
    except (TypeError, ValueError):
        return -1.0


def _is_session(c: Cookie) -> bool:
    return _expires(c) <= 0


@dataclass
class MergeResult:
    accepted: list[Cookie] = field(default_factory=list)
    skipped: dict[str, int] = field(default_factory=dict)

    def skip(self, reason: str) -> None:
        self.skipped[reason] = self.skipped.get(reason, 0) + 1


def merge(incoming: Iterable[Cookie], hub: Iterable[Cookie], tombstones: dict[Key, float],
          now: float, protected: Iterable[str] = DEFAULT_PROTECTED,
          hub_limit: int = DEFAULT_HUB_LIMIT) -> MergeResult:
    """Decide which pushed cookies the hub should take.

    Returns the accepted cookies (still in Playwright shape; translate with
    to_cdp_param before handing them to Chrome) and a count per skip reason.
    """
    protected = tuple(protected)
    hub_by_key = {cookie_key(c): c for c in hub}
    hub_domains = {_bare(c.get("domain", "")) for c in hub_by_key.values()}
    result = MergeResult()

    # One candidate per key: when a push repeats a key, the latest expiry wins.
    candidates: dict[Key, Cookie] = {}
    for c in incoming:
        if not isinstance(c, dict) or not c.get("name") or not c.get("domain"):
            result.skip("invalid")
            continue
        if is_local_host(c["domain"]):
            result.skip("local_host")
            continue
        if _is_session(c):
            result.skip("session")
            continue
        if _expires(c) <= now:
            result.skip("expired")
            continue
        key = cookie_key(c)
        held = candidates.get(key)
        if held is not None and _expires(c) <= _expires(held):
            continue
        candidates[key] = c

    # A browser that a site signed out pushes that site's cookies minus the
    # login ones, with fresh anonymous cookies that expire LATER (Amazon did this
    # to T3's headless browser, 2026-11-08). Expiry alone would let those replace
    # the hub's signed-in set. So a push may replace a site's cookies only when it
    # carries every cookie the hub currently holds live for that site; otherwise
    # it may only fill gaps.
    live_by_site: dict[str, set] = {}
    for k, h in hub_by_key.items():
        if not _is_session(h) and _expires(h) > now:
            live_by_site.setdefault(site_of(h["domain"]), set()).add(k)
    pushed_by_site: dict[str, set] = {}
    for k, c in candidates.items():
        pushed_by_site.setdefault(site_of(c["domain"]), set()).add(k)
    incomplete = {s for s, keys in live_by_site.items() if not keys <= pushed_by_site.get(s, set())}

    new_keys = 0
    for key, c in candidates.items():
        existing = hub_by_key.get(key)
        if existing is not None:
            if any(_under(c["domain"], p) for p in protected):
                result.skip("protected")
                continue
            if site_of(c["domain"]) in incomplete and _expires(c) > _expires(existing) and not _is_session(existing):
                result.skip("site_incomplete")
                continue
            if _is_session(existing) or _expires(c) <= _expires(existing):
                result.skip("not_newer")
                continue
            result.accepted.append(c)
            continue
        if key in tombstones and _expires(c) <= tombstones[key]:
            result.skip("tombstoned")
            continue
        known = any(_under(c["domain"], d) or _under(d, _bare(c["domain"])) for d in hub_domains if d)
        if not known and not (c.get("httpOnly") or c.get("secure")):
            result.skip("untrusted_new_domain")
            continue
        if len(hub_by_key) + new_keys >= hub_limit:
            result.skip("hub_full")
            continue
        new_keys += 1
        result.accepted.append(c)
    return result


def to_cdp_param(c: Cookie) -> dict:
    """A Playwright-format cookie as a CDP Network.CookieParam.

    Playwright stores the partition as a string plus _crHasCrossSiteAncestor;
    CDP wants an object, and rejects the whole Storage.setCookies call when a
    single cookie carries the string form.
    """
    param = {
        "name": c["name"],
        "value": c.get("value", ""),
        "domain": c["domain"],
        "path": c.get("path", "/"),
        "secure": bool(c.get("secure")),
        "httpOnly": bool(c.get("httpOnly")),
    }
    if c.get("sameSite") in ("Strict", "Lax", "None"):
        param["sameSite"] = c["sameSite"]
    if not _is_session(c):
        param["expires"] = _expires(c)
    _, _, _, top, cross = cookie_key(c)
    if top:
        param["partitionKey"] = {"topLevelSite": top, "hasCrossSiteAncestor": cross}
    return param


def update_tombstones(previous: Iterable[Cookie], current: Iterable[Cookie],
                      tombstones: dict[Key, float], now: float) -> dict[Key, float]:
    """Record cookies that left the hub before they expired.

    `previous` is the last snapshot, `current` what the hub holds now.
    """
    current_keys = {cookie_key(c) for c in current}
    out = {k: exp for k, exp in tombstones.items() if exp > now and k not in current_keys}
    for c in previous:
        key = cookie_key(c)
        if key in current_keys or _is_session(c) or _expires(c) <= now:
            continue
        out[key] = max(out.get(key, 0.0), _expires(c))
    return out


def tombstones_to_json(tombstones: dict[Key, float]) -> str:
    return json.dumps([[list(k), exp] for k, exp in tombstones.items()])


def tombstones_from_json(text: str) -> dict[Key, float]:
    return {(k[0], k[1], k[2], k[3], bool(k[4])): float(exp) for k, exp in json.loads(text)}
