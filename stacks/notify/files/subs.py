"""Subscriptions of the notify pipe: who gets which alert, on which Channels.

Each person's settings live in their Authentik user attributes, key `notify`:

  push_instance  none | ha-sofia | ha-london   (the Phone Channel)
  push_service   the Companion app's notify service, e.g. mobile_app_x
  email          an address; empty means the account email
  slack_target   a Slack member ID for DMs (U0123ABCD), or, for a Home
                 Server Admin, a channel such as #alerts
  default        Channels for Notifications sent to them by name
  groups         {rule group name: [Channels]}
  alerts         {alertname: [Channels]}   ([] means off for that alert)

A Channel list is any of "push", "email", "slack". Values written before
2026-11-20 are single words ("push", "email", "off"); they read as one-item
lists. A choice on an alert wins over the choice on its rule groups. An alert
is stored only where it differs from what its groups give, so a group change
carries its alerts along.

Apprise holds each person's Phone and Email under the tags u-<username>-push
and u-<username>-email (Authentik renders that config, stacks/authentik/
notify.tf). Slack goes from the adapter itself (slack.py).
"""

import copy
import json
import logging
import os
import re
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("notify-subs")

CHANNELS = ("push", "email", "slack")
OLD_WORDS = ("off", "push", "email")
INSTANCES = ("ha-sofia", "ha-london")
SERVICE = re.compile(r"[a-z0-9_]+")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ALERTNAME = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*")
SLACK_MEMBER = re.compile(r"[UW][A-Z0-9]{6,15}")
SLACK_CHANNEL = re.compile(r"#[a-z0-9][a-z0-9_-]{0,79}")


class Invalid(ValueError):
    """A settings form the page must refuse, with a message for the person."""


class Conflict(Invalid):
    """Someone changed a row after the page was loaded."""


class Unavailable(Exception):
    """An upstream API did not answer usefully."""


def sanitize(name: str) -> str:
    """Make an Apprise tag part; Authentik's renderer uses the same rule."""
    return re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")


def channel_tag(username: str, channel: str) -> str:
    return "u-%s-%s" % (sanitize(username), channel)


def as_set(value):
    """A stored choice as a set of Channels, or None if unreadable."""
    if isinstance(value, str):
        return {value} & set(CHANNELS) if value in OLD_WORDS else None
    if isinstance(value, list):
        return {v for v in value if isinstance(v, str)} & set(CHANNELS)
    return None


def as_list(channels) -> list:
    return [c for c in CHANNELS if c in channels]


def show(value) -> str:
    """A stored choice as the page sends it back: "inherit" or "push,email"."""
    chosen = as_set(value)
    return "inherit" if chosen is None else ",".join(as_list(chosen))


def parse(value: str, allow_inherit: bool):
    """The page's "push,email" (or "inherit") -> a list, or None for inherit."""
    value = value.strip()
    if value == "inherit" and allow_inherit:
        return None
    words = [w for w in value.split(",") if w]
    if any(w not in CHANNELS for w in words):
        raise Invalid("Unknown Channel in %r." % value)
    return as_list(set(words))


def _from_groups(settings: dict, groups) -> set:
    chosen = settings.get("groups") or {}
    out = set()
    for g in groups:
        out |= as_set(chosen.get(g)) or set()
    return out


def channels_for(settings: dict, alertname: str, groups) -> set:
    own = as_set((settings.get("alerts") or {}).get(alertname))
    if own is not None:
        return own
    return _from_groups(settings, groups)


def targets_for_alert(people: dict, alertname: str, groups) -> list:
    """-> sorted [(username, channel)] of everyone this alert reaches."""
    return sorted(
        (user, ch)
        for user, settings in people.items()
        for ch in channels_for(settings, alertname, groups)
    )


def targets_for_recipient(people: dict, recipient: str) -> list:
    want = sanitize(recipient)
    for user, settings in people.items():
        if sanitize(user) == want:
            return [(user, ch) for ch in as_list(as_set(settings.get("default")) or set())]
    return []


def slack_target(settings: dict):
    target = (settings.get("slack_target") or "").strip()
    if SLACK_MEMBER.fullmatch(target) or SLACK_CHANNEL.fullmatch(target):
        return target
    return None


def available(settings: dict, account_email: str) -> set:
    out = set()
    if settings.get("push_instance") in INSTANCES and SERVICE.fullmatch(settings.get("push_service") or ""):
        out.add("push")
    if EMAIL.fullmatch((settings.get("email") or account_email or "").strip()):
        out.add("email")
    if slack_target(settings):
        out.add("slack")
    return out


def apply_form(settings: dict, form: dict, groups_of, account_email: str, is_admin: bool = False) -> dict:
    """Merge a submitted form into settings. Only fields present change.

    For a key k the page may also send "o:k", the value it showed. If the
    stored value differs, someone changed that row meanwhile: Conflict."""
    s = copy.deepcopy(settings)
    s.pop("topics", None)  # the Topic list this replaced
    groups = dict(s.get("groups") or {})
    alerts = dict(s.get("alerts") or {})

    def stored(key):
        if key == "default":
            return s.get("default")
        if key.startswith("g:"):
            return groups.get(key[2:])
        return alerts.get(key[2:])

    for key, shown in form.items():
        if key.startswith("o:") and key[2:] in form:
            now = show(stored(key[2:]))
            if key[2:].startswith("g:") and now == "inherit":
                now = ""
            if key[2:] == "default" and now == "inherit":
                now = ""
            if now != shown:
                name = key[4:] if key[2:4] in ("a:", "g:") else "notifications sent to you by name"
                raise Conflict("%s changed since you opened the page. Reload it and try again." % name)

    if "push_instance" in form:
        if form["push_instance"] not in ("none",) + INSTANCES:
            raise Invalid("Pick a Home Assistant instance from the list.")
        s["push_instance"] = form["push_instance"]
    if "push_service" in form:
        service = form["push_service"].strip()
        if service.startswith("notify."):
            service = service[len("notify."):]
        if service and not SERVICE.fullmatch(service):
            raise Invalid("The notify service is lowercase letters, digits and _, like mobile_app_your_iphone.")
        s["push_service"] = service
    if "email" in form:
        address = form["email"].strip()
        if address and not EMAIL.fullmatch(address):
            raise Invalid("That email address does not look right.")
        s["email"] = address
    if "slack_target" in form:
        target = form["slack_target"].strip()
        if target.startswith("#"):
            if not is_admin:
                raise Invalid("Only Home Server Admins can send to a Slack channel; enter your member ID for direct messages.")
            if not SLACK_CHANNEL.fullmatch(target):
                raise Invalid("A Slack channel looks like #alerts.")
        elif target and not SLACK_MEMBER.fullmatch(target):
            raise Invalid("A Slack member ID looks like U01AB2CD3EF. In Slack: your profile, the three dots, Copy member ID.")
        s["slack_target"] = target
    if "default" in form:
        s["default"] = parse(form["default"], allow_inherit=False)

    for key, value in form.items():
        if key.startswith("g:"):
            groups[key[2:]] = parse(value, allow_inherit=False)
        elif key.startswith("a:"):
            name = key[2:]
            if not ALERTNAME.fullmatch(name):
                raise Invalid("Unknown alert: %s." % name)
            chosen = parse(value, allow_inherit=True)
            if chosen is None:
                alerts.pop(name, None)
            else:
                alerts[name] = chosen

    s["groups"] = {g: as_list(as_set(c)) for g, c in groups.items() if as_set(c)}
    s["alerts"] = {
        a: as_list(as_set(c))
        for a, c in alerts.items()
        if as_set(c) is not None and as_set(c) != _from_groups(s, groups_of(a))
    }
    if s.get("default") is not None:
        s["default"] = as_list(as_set(s["default"]) or set())

    used = set()
    for c in [s.get("default")] + list(s["groups"].values()) + list(s["alerts"].values()):
        used |= as_set(c) or set()
    missing = used - available(s, account_email)
    if "push" in missing:
        raise Invalid("Set up your phone first: pick its Home Assistant instance and notify service.")
    if "email" in missing:
        raise Invalid("Set an email address first.")
    if "slack" in missing:
        raise Invalid("Set your Slack member ID first.")
    return s


def _get_json(url: str, headers: dict, timeout: float, method="GET", data=None):
    body = None
    headers = dict(headers, Accept="application/json")
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise Unavailable("%s %s returned %d" % (method, url.split("?")[0], e.code)) from e
    except (urllib.error.URLError, OSError) as e:
        raise Unavailable("%s %s: %s" % (method, url.split("?")[0], e)) from e
    return json.loads(raw) if raw else {}


def write_private(path: str, data) -> None:
    """Write JSON atomically, readable by this user only."""
    folder = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class Rules:
    """The alert inventory, read on demand from rules APIs: Prometheus's and
    Loki's ruler, which answers the same /api/v1/rules shape. Groups of the
    same name from both are one group. A source that fails keeps its last
    answer."""

    TTL = 300
    MISS_RETRY = 60

    def __init__(self, urls, timeout: float = 10, clock=time.monotonic):
        if isinstance(urls, str):
            urls = [urls]
        self.urls = [u.rstrip("/") + "/api/v1/rules?type=alert" if "/api/v1/rules" not in u else u for u in urls]
        self.timeout = timeout
        self.clock = clock
        self._lock = threading.Lock()
        self._by_source = {u: [] for u in self.urls}
        self._catalog = []
        self._index = {}
        self._raw = {}
        self._fetched = None

    def _refresh(self):
        self._fetched = self.clock()
        for url in self.urls:
            try:
                self._by_source[url] = _get_json(url, {}, self.timeout)["data"]["groups"]
            except (Unavailable, KeyError, ValueError, TypeError) as e:
                log.warning("rules unavailable from %s, keeping %d groups: %s", url.split("/api")[0], len(self._by_source[url]), e)
        merged, index, raw = {}, {}, {}
        for url in self.urls:
            for g in self._by_source[url]:
                entry = merged.setdefault(g["name"], {"name": g["name"], "alerts": [], "seen": set()})
                for r in g.get("rules") or []:
                    if r.get("type") != "alerting" or r["name"] in entry["seen"]:
                        continue
                    entry["seen"].add(r["name"])
                    raw.setdefault(r["name"], r)
                    entry["alerts"].append({
                        "name": r["name"],
                        "summary": (r.get("annotations") or {}).get("summary", ""),
                        "severity": (r.get("labels") or {}).get("severity", ""),
                    })
                    if g["name"] not in index.setdefault(r["name"], []):
                        index[r["name"]].append(g["name"])
        catalog = [{"name": e["name"], "alerts": e["alerts"]} for e in merged.values() if e["alerts"]]
        self._catalog = sorted(catalog, key=lambda g: g["name"].lower())
        self._index = index
        self._raw = raw

    def catalog(self) -> list:
        with self._lock:
            if self._fetched is None or self.clock() - self._fetched > self.TTL:
                self._refresh()
            return self._catalog

    def _fresh(self, alertname: str):
        age = None if self._fetched is None else self.clock() - self._fetched
        # A rule added since the last read: look again, once a minute at most.
        if age is None or age > self.TTL or (alertname not in self._index and age > self.MISS_RETRY):
            self._refresh()

    def groups_of(self, alertname: str) -> list:
        with self._lock:
            self._fresh(alertname)
            return list(self._index.get(alertname, []))

    def rule(self, alertname: str):
        """The first rule of that name as the rules API gives it (query,
        labels, annotations, active alerts), or None."""
        with self._lock:
            self._fresh(alertname)
            return self._raw.get(alertname)


class Authentik:
    """Reads and writes users' `notify` attributes as the notify-settings
    service account. The token is read from a file on every call, so a
    rotated Secret takes effect without a restart.

    Every successful read of everyone's settings is also saved to
    `snapshot_file`. When Authentik does not answer, routing uses the last
    read in memory, else that file: an Authentik outage must not silence
    the alert about it."""

    TTL = 60

    def __init__(self, base: str, token_file: str, timeout: float = 10, clock=time.monotonic, snapshot_file=None):
        self.base = base.rstrip("/")
        self.token_file = token_file
        self.timeout = timeout
        self.clock = clock
        self.snapshot_file = snapshot_file
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._people = None
        self._fetched = 0.0
        self.stale = False

    def _call(self, path, method="GET", data=None):
        try:
            with open(self.token_file) as f:
                token = f.read().strip()
        except OSError as e:
            raise Unavailable("no Authentik token: %s" % e) from e
        return _get_json(self.base + path, {"Authorization": "Bearer " + token}, self.timeout, method, data)

    def _users(self, query: dict):
        page = 1
        while page:
            q = urllib.parse.urlencode(dict(query, page=page, page_size=100, include_groups="false"))
            data = self._call("/api/v3/core/users/?" + q)
            yield from data.get("results") or []
            page = (data.get("pagination") or {}).get("next") or 0

    def subscribers(self) -> dict:
        """{username: notify settings} of every active user who has some."""
        with self._lock:
            if self._people is not None and self.clock() - self._fetched <= self.TTL:
                return self._people
            try:
                people = {}
                for u in self._users({"is_active": "true"}):
                    notify = (u.get("attributes") or {}).get("notify")
                    if isinstance(notify, dict):
                        people[u["username"]] = notify
            except Unavailable as e:
                if self._people is None and self.snapshot_file:
                    try:
                        with open(self.snapshot_file) as f:
                            self._people = json.load(f)
                    except (OSError, ValueError):
                        pass
                if self._people is None:
                    raise
                log.warning("authentik unavailable, routing from the last snapshot: %s", e)
                self.stale = True
                return self._people
            self._people, self._fetched, self.stale = people, self.clock(), False
            if self.snapshot_file:
                try:
                    write_private(self.snapshot_file, people)
                except OSError as e:
                    log.warning("could not write the snapshot: %s", e)
            return people

    def user(self, username: str):
        for u in self._users({"username": username}):
            if u.get("username") == username:
                return u
        return None

    def update(self, username: str, change):
        """Read the user fresh, let change(user) return the new notify
        settings, write them. One writer at a time in this process."""
        with self._write_lock:
            user = self.user(username)
            if user is None:
                raise Invalid("No account found for %s." % username)
            notify = change(user)
            self.save(user, notify)
            return notify

    def save(self, user: dict, notify: dict):
        attributes = dict(user.get("attributes") or {}, notify=notify)
        self._call("/api/v3/core/users/%d/" % user["pk"], "PATCH", {"attributes": attributes})
        with self._lock:
            self._people = None
