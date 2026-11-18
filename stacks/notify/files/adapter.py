"""Alertmanager webhook -> Apprise API adapter (the notify pipe).

Alertmanager posts one alert group. A group with a `topic` label goes to the
Apprise tag topic-<topic>; a group with a `recipient` label goes to the
Recipient's default channel, tag person-<username>. Apprise holds which
Channels carry which tags; Authentik renders that config (stacks/authentik/
notify.tf). Design: docs/plans/2026-11-17-notify-pipe-design.md.

Environment:
  APPRISE_URL       base URL of apprise-api, e.g. http://apprise.notify.svc:8000
  APPRISE_KEY       config key holding every Recipient's Channels (notify)
  APPRISE_USER      apprise-api administrator user
  APPRISE_PASSWORD  apprise-api administrator password
  TOPICS            comma-separated list of known Topics
  PORT              listen port (default 8080)
"""

import base64
import json
import logging
import os
import re
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("notify-adapter")

RESULTS = ("sent", "failed", "no_recipients", "rejected")
METRICS: dict = {}
_lock = threading.Lock()


class Rejected(Exception):
    """The alert group names no known Topic and no Recipient."""


class Unavailable(Exception):
    """apprise-api did not answer, so Alertmanager should retry."""


def sanitize(name: str) -> str:
    """Make an Apprise tag part; Authentik's renderer uses the same rule."""
    return re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")


def tag_for(labels: dict, topics: set) -> str:
    topic = labels.get("topic")
    if topic:
        if topic not in topics:
            raise Rejected("unknown topic %r" % topic)
        return "topic-" + sanitize(topic)
    recipient = labels.get("recipient")
    if recipient:
        return "person-" + sanitize(recipient)
    raise Rejected("no topic or recipient label")


def build(payload: dict, topics: set) -> dict:
    """One Alertmanager group -> one Notification."""
    tag = tag_for(payload.get("groupLabels") or payload.get("commonLabels") or {}, topics)
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
    return {"tag": tag, "title": title, "body": body, "type": kind}


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

    def send(self, notification: dict) -> str:
        # Apprise answers 424 both for a failed Channel and for a tag nobody
        # carries, so look first: a Topic with no Subscription is not a failure.
        if notification["tag"] not in self.tags():
            return "no_recipients"
        status, body = self._call("POST", "/notify/%s" % self.key, notification)
        if status == 200:
            return "sent"
        if status >= 500:
            raise Unavailable("notify returned %d" % status)
        log.warning("apprise notify returned %d: %s", status, body[:300])
        return "failed"


def count(result: str):
    with _lock:
        METRICS[result] = METRICS.get(result, 0) + 1


def render_metrics() -> str:
    lines = [
        "# HELP notify_notifications_total Alert groups handled, by result.",
        "# TYPE notify_notifications_total counter",
    ]
    with _lock:
        for r in RESULTS:
            lines.append('notify_notifications_total{result="%s"} %d' % (r, METRICS.get(r, 0)))
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
            self.reply(200, render_metrics().encode(), "text/plain; version=0.0.4")
        else:
            self.reply(404)

    def do_POST(self):
        if self.path != "/alertmanager":
            return self.reply(404)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length))
            notification = build(payload, self.server.topics)
        except Rejected as e:
            log.warning("rejected alert group: %s", e)
            count("rejected")
            return self.reply(200, b"rejected")
        except (ValueError, KeyError) as e:
            log.warning("bad payload: %s", e)
            count("rejected")
            return self.reply(400, b"bad payload")
        try:
            result = self.server.apprise.send(notification)
        except Unavailable as e:
            log.error("apprise unavailable: %s", e)
            count("failed")
            return self.reply(503, b"apprise unavailable")
        log.info("%s tag=%s title=%r", result, notification["tag"], notification["title"])
        count(result)
        self.reply(200, result.encode())


def make_server(address, apprise, topics) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(address, Handler)
    server.apprise = apprise
    server.topics = set(topics)
    return server


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    apprise = Apprise(
        os.environ["APPRISE_URL"],
        os.environ.get("APPRISE_KEY", "notify"),
        os.environ["APPRISE_USER"],
        os.environ["APPRISE_PASSWORD"],
    )
    topics = {t.strip() for t in os.environ.get("TOPICS", "").split(",") if t.strip()}
    port = int(os.environ.get("PORT", "8080"))
    log.info("listening on :%d, topics=%s", port, sorted(topics))
    make_server(("0.0.0.0", port), apprise, topics).serve_forever()


if __name__ == "__main__":
    main()
