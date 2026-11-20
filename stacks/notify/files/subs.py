"""Subscriptions of the notify pipe: who gets which alert, on which Channel.

Each person's settings live in their Authentik user attributes, key `notify`:

  push_instance  none | ha-sofia | ha-london   (the phone Channel)
  push_service   the Companion app's notify service, e.g. mobile_app_x
  email          an address; empty means the account email
  default        off | push | email  (Notifications sent to them by name)
  groups         {rule group name: push | email}
  alerts         {alertname: off | push | email}

A choice on an alert wins over the choice on its rule group, so "off" on one
alert silences it inside a subscribed group. An alert is stored only where it
differs from what its groups give, so a group change carries its alerts along.

Apprise holds each person's Channels under the tags u-<username>-push and
u-<username>-email (Authentik renders that config, stacks/authentik/notify.tf);
this module decides which of those tags an alert goes to.
"""

import copy
import json
import logging
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("notify-subs")

CHOICES = ("off", "push", "email")
CHANNELS = ("push", "email")
INSTANCES = ("ha-sofia", "ha-london")
SERVICE = re.compile(r"[a-z0-9_]+")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ALERTNAME = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*")


class Invalid(ValueError):
    """A settings form the page must refuse, with a message for the person."""


class Unavailable(Exception):
    """An upstream API did not answer usefully."""


def sanitize(name: str) -> str:
    """Make an Apprise tag part; Authentik's renderer uses the same rule."""
    return re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")


def channel_tag(username: str, channel: str) -> str:
    return "u-%s-%s" % (sanitize(username), channel)


def as_set(value):
    """A stored choice as a set of Channels: a list such as ["push", "email"],
    or the older single word ("push", "email", "off"). None if unreadable."""
    if isinstance(value, str):
        return {value} & set(CHANNELS) if value in CHOICES else None
    if isinstance(value, list):
        return {v for v in value if isinstance(v, str)} & set(CHANNELS)
    return None


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


def tags_for_alert(people: dict, alertname: str, groups) -> list:
    return sorted(
        channel_tag(user, ch)
        for user, settings in people.items()
        for ch in channels_for(settings, alertname, groups)
    )


def tag_for_recipient(people: dict, recipient: str):
    want = sanitize(recipient)
    for user, settings in people.items():
        default = sorted(as_set(settings.get("default")) or [])
        if sanitize(user) == want and default:
            return channel_tag(user, default[0])
    return None


def available(settings: dict, account_email: str) -> set:
    out = set()
    if settings.get("push_instance") in INSTANCES and SERVICE.fullmatch(settings.get("push_service") or ""):
        out.add("push")
    if EMAIL.fullmatch((settings.get("email") or account_email or "").strip()):
        out.add("email")
    return out


def apply_form(settings: dict, form: dict, groups_of, account_email: str) -> dict:
    """Merge a submitted form into settings. Only fields present change."""
    s = copy.deepcopy(settings)
    s.pop("topics", None)  # the Topic list this replaced
    groups = dict(s.get("groups") or {})
    alerts = dict(s.get("alerts") or {})

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
    if "default" in form:
        if form["default"] not in CHOICES:
            raise Invalid("Unknown choice for notifications sent to you by name.")
        s["default"] = form["default"]

    for key, value in form.items():
        if key.startswith("g:"):
            if value not in CHOICES:
                raise Invalid("Unknown choice for group %s." % key[2:])
            groups[key[2:]] = value
        elif key.startswith("a:"):
            name = key[2:]
            if not ALERTNAME.fullmatch(name) or value not in CHOICES + ("inherit",):
                raise Invalid("Unknown alert or choice: %s." % name)
            if value == "inherit":
                alerts.pop(name, None)
            else:
                alerts[name] = value

    groups = {g: c for g, c in groups.items() if as_set(c)}
    s["groups"] = groups
    s["alerts"] = {
        a: c for a, c in alerts.items() if as_set(c) is not None and as_set(c) != _from_groups(s, groups_of(a))
    }

    used = set()
    for c in [s.get("default")] + list(groups.values()) + list(s["alerts"].values()):
        used |= as_set(c) or set()
    missing = used - available(s, account_email)
    if "push" in missing:
        raise Invalid("Set up your phone first: pick its Home Assistant instance and notify service.")
    if "email" in missing:
        raise Invalid("Set an email address first.")
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


class Rules:
    """The alert inventory, read from Prometheus's rules API on demand."""

    TTL = 300
    MISS_RETRY = 60

    def __init__(self, base: str, timeout: float = 10, clock=time.monotonic):
        self.url = base.rstrip("/") + "/api/v1/rules?type=alert"
        self.timeout = timeout
        self.clock = clock
        self._lock = threading.Lock()
        self._catalog = []
        self._index = {}
        self._raw = {}
        self._fetched = None

    def _refresh(self):
        self._fetched = self.clock()
        try:
            data = _get_json(self.url, {}, self.timeout)["data"]["groups"]
        except (Unavailable, KeyError, ValueError) as e:
            log.warning("prometheus rules unavailable, keeping %d groups: %s", len(self._catalog), e)
            return
        catalog, index, raw = [], {}, {}
        for g in data:
            seen, alerts = set(), []
            for r in g.get("rules") or []:
                if r.get("type") != "alerting" or r["name"] in seen:
                    continue
                seen.add(r["name"])
                raw.setdefault(r["name"], r)
                alerts.append({
                    "name": r["name"],
                    "summary": (r.get("annotations") or {}).get("summary", ""),
                    "severity": (r.get("labels") or {}).get("severity", ""),
                })
                index.setdefault(r["name"], []).append(g["name"])
            if alerts:
                catalog.append({"name": g["name"], "alerts": alerts})
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
    rotated Secret takes effect without a restart."""

    TTL = 60

    def __init__(self, base: str, token_file: str, timeout: float = 10, clock=time.monotonic):
        self.base = base.rstrip("/")
        self.token_file = token_file
        self.timeout = timeout
        self.clock = clock
        self._lock = threading.Lock()
        self._people = None
        self._fetched = 0.0

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
            if self._people is None or self.clock() - self._fetched > self.TTL:
                people = {}
                for u in self._users({"is_active": "true"}):
                    notify = (u.get("attributes") or {}).get("notify")
                    if isinstance(notify, dict):
                        people[u["username"]] = notify
                self._people, self._fetched = people, self.clock()
            return self._people

    def user(self, username: str):
        for u in self._users({"username": username}):
            if u.get("username") == username:
                return u
        return None

    def save(self, user: dict, notify: dict):
        attributes = dict(user.get("attributes") or {}, notify=notify)
        self._call("/api/v3/core/users/%d/" % user["pk"], "PATCH", {"attributes": attributes})
        with self._lock:
            self._people = None
