"""Alertmanager webhook -> Apprise API adapter (the notify pipe).

Alertmanager posts every alert group here (stacks/monitoring, route
notify-pipe); since 2026-11-20 this is the only way alerts reach people,
apart from six root-cause alerts that also go straight to #alerts. The
adapter looks up who subscribed to the alert, directly or through its rule
group (subs.py), then posts Slack itself (slack.py) and asks apprise-api to
notify Phone and Email, tagged u-<username>-push / u-<username>-email. A
group with a `recipient` label goes to that person's default Channels only.
Each person picks their Subscriptions on the settings page (page.py), which
this process also serves. Designs: docs/plans/2026-11-17-notify-pipe-
design.md and docs/plans/2026-11-20-notify-one-flow-design.md.

Retries: a send that may work later (Slack rate limit, Apprise or Authentik
down) answers 503, and Alertmanager sends the group again. Channels that
already got this exact notification are skipped on the retry.

Environment:
  APPRISE_URL         base URL of apprise-api, e.g. http://apprise.notify.svc:8000
  APPRISE_KEY         config key holding every Recipient's Channels (notify)
  APPRISE_USER        apprise-api administrator user
  APPRISE_PASSWORD    apprise-api administrator password
  AUTHENTIK_URL       base URL of Authentik's API
  AUTHENTIK_TOKEN_FILE  file holding the notify-settings service account token
  PROMETHEUS_URL      base URL of Prometheus (rules and query APIs)
  LOKI_URL            base URL of Loki (its ruler's rules API)
  PAGE_URL            public URL of the settings page
  INGRESS_PROOF_FILE  file holding the header value Traefik adds (page.py)
  SLACK_TOKEN_FILE    file holding the Slack bot token
  SLACK_LIVE          "true" to post to Slack; otherwise only log what it would post
  STATE_DIR           local volume for the subscriber snapshot and the unrouted list
  UNROUTED_CHANNEL    where "fired and reached nobody" goes (default #alerts)
  ADMIN_GROUP         Authentik group allowed to target a Slack channel
  PORT, PAGE_PORT     listen ports (default 8080 webhook, 8081 page)
"""

import base64
import hashlib
import json
import logging
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import slack
import subs
from subs import Unavailable

log = logging.getLogger("notify-adapter")

RESULTS = ("sent", "failed", "no_recipients", "rejected")
CHANNEL_NAMES = ("push", "email", "slack", "unrouted")
METRICS: dict = {}
DELIVERIES: dict = {}
_lock = threading.Lock()


def build(payload: dict) -> dict:
    """One Alertmanager group -> one Notification."""
    resolved = payload.get("status") == "resolved"
    alerts = payload.get("alerts") or []
    if not resolved:
        alerts = [a for a in alerts if a.get("status") == "firing"] or alerts

    def text(a, *keys):
        ann = a.get("annotations") or {}
        for k in keys:
            if ann.get(k):
                return ann[k]
        return (a.get("labels") or {}).get("alertname", "Alert")

    first = alerts[0] if alerts else {}
    if resolved:
        ann = first.get("annotations") or {}
        title = ann.get("notification_resolved_title") or "Resolved: " + text(first, "notification_title", "summary")
        bodies = [(a.get("annotations") or {}).get("notification_resolved_body") or "This is no longer happening." for a in alerts]
        kind = "success"
    else:
        title = text(first, "notification_title", "summary")
        bodies = [text(a, "notification_body", "description", "summary") for a in alerts]
        critical = any((a.get("labels") or {}).get("severity") == "critical" for a in alerts)
        kind = "failure" if critical else "warning"
    if len(alerts) > 1:
        title += " (+%d more)" % (len(alerts) - 1)
    body = "\n\n".join(dict.fromkeys(bodies)) or title
    return {"title": title, "body": body, "type": kind}


def notification_key(payload: dict) -> str:
    """Identifies one notification: Alertmanager sends the same group, status
    and alert set again when it retries."""
    alerts = sorted("%s:%s" % (a.get("fingerprint", ""), a.get("status", "")) for a in payload.get("alerts") or [])
    raw = "|".join([payload.get("groupKey", ""), payload.get("status", "")] + alerts)
    return hashlib.sha1(raw.encode()).hexdigest()


class Delivered:
    """Which (notification, Channel, target) went out, for an hour."""

    TTL = 3600

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self._seen = {}
        self._lock = threading.Lock()

    def has(self, key) -> bool:
        with self._lock:
            now = self.clock()
            self._seen = {k: t for k, t in self._seen.items() if now - t < self.TTL}
            return key in self._seen

    def add(self, key):
        with self._lock:
            self._seen[key] = self.clock()


class Once:
    """Alertnames already reported as reaching nobody, kept on disk."""

    def __init__(self, path=None):
        self.path = path
        self._names = set()
        self._lock = threading.Lock()
        if path:
            try:
                with open(path) as f:
                    self._names = set(json.load(f))
            except (OSError, ValueError):
                pass

    def seen(self, name) -> bool:
        with self._lock:
            return name in self._names

    def mark(self, name):
        with self._lock:
            self._names.add(name)
            if self.path:
                try:
                    subs.write_private(self.path, sorted(self._names))
                except OSError as e:
                    log.warning("could not save the unrouted list: %s", e)


class Apprise:
    def __init__(self, base: str, key: str, user: str, password: str, timeout: float = 30):
        self.base = base.rstrip("/")
        self.key = key
        self.timeout = timeout
        token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
        self.headers = {"Authorization": "Basic " + token, "Accept": "application/json"}

    def _call(self, method, path, data=None):
        headers = dict(self.headers)
        if data is not None:
            data = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except (urllib.error.URLError, OSError) as e:
            raise Unavailable(str(e)) from e

    def tags(self) -> set:
        status, body = self._call("GET", "/json/urls/%s?privacy=1" % self.key)
        if status in (204, 404):
            return set()
        if status != 200:
            raise Unavailable("listing tags returned %d" % status)
        return set(json.loads(body).get("tags") or [])

    def send(self, notification: dict, tags: list) -> str:
        # Apprise answers 424 both for a failed Channel and for a tag nobody
        # carries, so send only to tags it holds. A missing tag is a Channel
        # someone chose that Apprise lost or the renderer refused
        # (stacks/authentik/files/notify_render.py): a failure, not silence.
        held = self.tags()
        present = [t for t in tags if t in held]
        missing = sorted(set(tags) - held)
        if missing:
            log.warning("apprise holds no channel for %s", missing)
        if not present:
            return "failed" if missing else "no_recipients"
        status, body = self._call("POST", "/notify/%s" % self.key, dict(notification, tag=", ".join(present)))
        if status >= 500:
            raise Unavailable("notify returned %d" % status)
        if status != 200:
            log.warning("apprise notify returned %d: %s", status, body[:300])
            return "failed"
        return "failed" if missing else "sent"


def count(result: str):
    with _lock:
        METRICS[result] = METRICS.get(result, 0) + 1


def count_delivery(channel: str, result: str):
    with _lock:
        DELIVERIES[(channel, result)] = DELIVERIES.get((channel, result), 0) + 1


def render_metrics(stale=False) -> str:
    lines = [
        "# HELP notify_notifications_total Alert groups handled, by result.",
        "# TYPE notify_notifications_total counter",
    ]
    with _lock:
        for r in RESULTS:
            lines.append('notify_notifications_total{result="%s"} %d' % (r, METRICS.get(r, 0)))
        lines += [
            "# HELP notify_deliveries_total Sends to one Channel, by Channel and result.",
            "# TYPE notify_deliveries_total counter",
        ]
        for ch in CHANNEL_NAMES:
            for r in ("sent", "failed", "unavailable", "skipped"):
                lines.append('notify_deliveries_total{channel="%s",result="%s"} %d' % (ch, r, DELIVERIES.get((ch, r), 0)))
    lines += [
        "# HELP notify_snapshot_in_use 1 while routing uses the saved snapshot because Authentik does not answer.",
        "# TYPE notify_snapshot_in_use gauge",
        "notify_snapshot_in_use %d" % (1 if stale else 0),
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug(fmt, *args)

    def reply(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, b"ok")
        elif self.path == "/metrics":
            stale = bool(getattr(self.server.directory, "stale", False))
            self.reply(200, render_metrics(stale).encode(), "text/plain; version=0.0.4")
        else:
            self.reply(404)

    def do_POST(self):
        if self.path != "/alertmanager":
            return self.reply(404)
        srv = self.server
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length))
            notification = build(payload)
            labels = payload.get("groupLabels") or payload.get("commonLabels") or {}
            common = payload.get("commonLabels") or labels
        except (ValueError, KeyError, AttributeError, TypeError) as e:
            log.warning("bad payload: %s", e)
            count("rejected")
            return self.reply(400, b"bad payload")
        try:
            code, result = self.deliver(srv, payload, notification, labels, common)
        except Exception:  # a bug must not look like silence: count it, let Alertmanager retry
            log.exception("delivery crashed for %s", labels.get("alertname"))
            count("failed")
            return self.reply(503, b"adapter error")
        count(result)
        self.reply(code, result.encode())

    def deliver(self, srv, payload, notification, labels, common):
        name = labels.get("alertname") or common.get("alertname", "")
        try:
            people = srv.directory.subscribers()
            recipient = labels.get("recipient")
            if recipient:
                targets, subscribed = subs.targets_for_recipient(people, recipient), False
            else:
                targets, subscribed = subs.targets_for_alert(people, name, srv.rules.groups_of(name)), True
        except Unavailable as e:
            log.error("cannot route %s: %s", name, e)
            return 503, "failed"

        jobs = []
        slack_body = slack.message(payload, srv.page_url)
        for target in sorted({subs.slack_target(people[u]) for u, ch in targets if ch == "slack"} - {None}):
            jobs.append(("slack", target, lambda t=target: srv.slack.post(t, slack_body)))
        push = [subs.channel_tag(u, "push") for u, ch in targets if ch == "push"]
        if push:
            jobs.append(("push", ",".join(push), lambda: srv.apprise.send(notification, push)))
        email = [subs.channel_tag(u, "email") for u, ch in targets if ch == "email"]
        if email:
            n = notification
            if subscribed:
                link = "%s/a/%s" % (srv.page_url, urllib.parse.quote(name))
                n = dict(n, body=n["body"] + "\n\nChange what you get: " + link)
            jobs.append(("email", ",".join(email), lambda: srv.apprise.send(n, email)))
        unrouted = (
            not targets and subscribed and payload.get("status") == "firing"
            and (common.get("severity") == "critical" or common.get("lane") == "security")
            and not srv.unrouted.seen(name)
        )
        if unrouted:
            body = slack.unrouted_message(name, common.get("severity") or common.get("lane"), srv.page_url)
            jobs.append(("unrouted", srv.unrouted_channel, lambda: srv.slack.post(srv.unrouted_channel, body)))

        key = notification_key(payload)
        results, retry = [], False
        for channel, target, send in jobs:
            done = "%s|%s|%s" % (key, channel, target)
            if channel in ("slack", "unrouted") and not srv.slack_live:
                log.info("slack shadow: would post %s to %s (%s)", name, target, channel)
                count_delivery(channel, "skipped")
                continue
            if srv.delivered.has(done):
                count_delivery(channel, "skipped")
                results.append("sent")
                continue
            try:
                result = send()
            except Unavailable as e:
                log.error("%s to %s unavailable: %s", channel, target, e)
                count_delivery(channel, "unavailable")
                retry = True
                continue
            count_delivery(channel, result)
            results.append(result)
            if result == "sent":
                srv.delivered.add(done)
                if channel == "unrouted":
                    srv.unrouted.mark(name)
        if retry:
            return 503, "failed"
        result = "failed" if "failed" in results else "sent" if "sent" in results else "no_recipients"
        log.info("%s alertname=%s targets=%s title=%r", result, name, targets, notification["title"])
        return 200, result


def make_server(address, apprise, directory, rules, page_url, slack_client=None, slack_live=False,
                unrouted=None, unrouted_channel="#alerts") -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(address, Handler)
    server.apprise = apprise
    server.directory = directory
    server.rules = rules
    server.page_url = page_url.rstrip("/")
    server.slack = slack_client
    server.slack_live = slack_live
    server.delivered = Delivered()
    server.unrouted = unrouted or Once()
    server.unrouted_channel = unrouted_channel
    return server


def main():
    import page
    import preview

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    apprise = Apprise(
        os.environ["APPRISE_URL"],
        os.environ.get("APPRISE_KEY", "notify"),
        os.environ["APPRISE_USER"],
        os.environ["APPRISE_PASSWORD"],
    )
    state = os.environ.get("STATE_DIR", "")
    directory = subs.Authentik(
        os.environ["AUTHENTIK_URL"], os.environ["AUTHENTIK_TOKEN_FILE"],
        snapshot_file=os.path.join(state, "subscribers.json") if state else None,
    )
    rule_urls = [os.environ["PROMETHEUS_URL"]]
    if os.environ.get("LOKI_URL"):
        rule_urls.append(os.environ["LOKI_URL"].rstrip("/") + "/prometheus/api/v1/rules?type=alert")
    rules = subs.Rules(rule_urls)
    page_url = os.environ["PAGE_URL"]
    slack_client = slack.Slack(os.environ["SLACK_TOKEN_FILE"])
    slack_live = os.environ.get("SLACK_LIVE", "").lower() == "true"
    unrouted = Once(os.path.join(state, "unrouted.json") if state else None)
    port = int(os.environ.get("PORT", "8080"))
    page_port = int(os.environ.get("PAGE_PORT", "8081"))
    prom = preview.Prometheus(os.environ["PROMETHEUS_URL"])
    ui = page.make_server(
        ("0.0.0.0", page_port), directory, rules, os.environ["INGRESS_PROOF_FILE"], page_url, apprise, prom,
        slack_client=slack_client, admin_group=os.environ.get("ADMIN_GROUP", "Home Server Admins"),
    )
    threading.Thread(target=ui.serve_forever, daemon=True).start()
    log.info("webhook on :%d, settings page on :%d, slack %s", port, page_port, "live" if slack_live else "shadow")
    make_server(
        ("0.0.0.0", port), apprise, directory, rules, page_url, slack_client, slack_live,
        unrouted, os.environ.get("UNROUTED_CHANNEL", "#alerts"),
    ).serve_forever()


if __name__ == "__main__":
    main()
