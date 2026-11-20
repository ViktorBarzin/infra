"""Alertmanager webhook -> Apprise API adapter (the notify pipe).

Alertmanager posts every alert group here (stacks/monitoring, route
notify-pipe). The adapter looks up who subscribed to that alert, directly or
through its Prometheus rule group (subs.py), and asks apprise-api to notify
their Channels, tagged u-<username>-push / u-<username>-email. A group with a
`recipient` label goes to that person's default channel only. Each person
picks their Subscriptions on the settings page (page.py), which this process
also serves. Design: docs/plans/2026-11-17-notify-pipe-design.md.

Environment:
  APPRISE_URL         base URL of apprise-api, e.g. http://apprise.notify.svc:8000
  APPRISE_KEY         config key holding every Recipient's Channels (notify)
  APPRISE_USER        apprise-api administrator user
  APPRISE_PASSWORD    apprise-api administrator password
  AUTHENTIK_URL       base URL of Authentik's API
  AUTHENTIK_TOKEN_FILE  file holding the notify-settings service account token
  PROMETHEUS_URL      base URL of Prometheus (rules API)
  PAGE_URL            public URL of the settings page
  INGRESS_PROOF_FILE  file holding the header value Traefik adds (page.py)
  PORT, PAGE_PORT     listen ports (default 8080 webhook, 8081 page)
"""

import base64
import json
import logging
import os
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import subs
from subs import Unavailable

log = logging.getLogger("notify-adapter")

RESULTS = ("sent", "failed", "no_recipients", "rejected")
METRICS: dict = {}
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


def route(labels: dict, people: dict, groups_of) -> tuple:
    """-> (Apprise tags, whether these are Subscriptions rather than a direct send)."""
    recipient = labels.get("recipient")
    if recipient:
        tag = subs.tag_for_recipient(people, recipient)
        return ([tag] if tag else []), False
    name = labels.get("alertname", "")
    return subs.tags_for_alert(people, name, groups_of(name)), True


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
        # carries, so send only to tags it holds. A missing one is a Channel
        # the renderer refused (stacks/authentik/files/notify_render.py).
        held = self.tags()
        present = [t for t in tags if t in held]
        if len(present) < len(tags):
            log.warning("apprise holds no channel for %s", sorted(set(tags) - held))
        if not present:
            return "no_recipients"
        status, body = self._call("POST", "/notify/%s" % self.key, dict(notification, tag=", ".join(present)))
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
        srv = self.server
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length))
            notification = build(payload)
            labels = payload.get("groupLabels") or payload.get("commonLabels") or {}
        except (ValueError, KeyError, AttributeError) as e:
            log.warning("bad payload: %s", e)
            count("rejected")
            return self.reply(400, b"bad payload")
        try:
            tags, subscribed = route(labels, srv.directory.subscribers(), srv.rules.groups_of)
            results = []
            push = [t for t in tags if t.endswith("-push")]
            email = [t for t in tags if t.endswith("-email")]
            if push:
                results.append(srv.apprise.send(notification, push))
            if email:
                n = notification
                if subscribed:
                    link = "%s/a/%s" % (srv.page_url, urllib.parse.quote(labels.get("alertname", "")))
                    n = dict(n, body=n["body"] + "\n\nChange what you get: " + link)
                results.append(srv.apprise.send(n, email))
        except Unavailable as e:
            log.error("upstream unavailable: %s", e)
            count("failed")
            return self.reply(503, b"upstream unavailable")
        result = "failed" if "failed" in results else "sent" if "sent" in results else "no_recipients"
        log.info("%s alertname=%s tags=%s title=%r", result, labels.get("alertname"), tags, notification["title"])
        count(result)
        self.reply(200, result.encode())


def make_server(address, apprise, directory, rules, page_url) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(address, Handler)
    server.apprise = apprise
    server.directory = directory
    server.rules = rules
    server.page_url = page_url.rstrip("/")
    return server


def main():
    import page

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    apprise = Apprise(
        os.environ["APPRISE_URL"],
        os.environ.get("APPRISE_KEY", "notify"),
        os.environ["APPRISE_USER"],
        os.environ["APPRISE_PASSWORD"],
    )
    directory = subs.Authentik(os.environ["AUTHENTIK_URL"], os.environ["AUTHENTIK_TOKEN_FILE"])
    rules = subs.Rules(os.environ["PROMETHEUS_URL"])
    page_url = os.environ["PAGE_URL"]
    port = int(os.environ.get("PORT", "8080"))
    page_port = int(os.environ.get("PAGE_PORT", "8081"))
    ui = page.make_server(("0.0.0.0", page_port), directory, rules, os.environ["INGRESS_PROOF_FILE"], page_url)
    threading.Thread(target=ui.serve_forever, daemon=True).start()
    log.info("webhook on :%d, settings page on :%d", port, page_port)
    make_server(("0.0.0.0", port), apprise, directory, rules, page_url).serve_forever()


if __name__ == "__main__":
    main()
