"""Slack Channel of the notify pipe: chat.postMessage with the homelab bot.

A person's Slack target is a member ID (a DM from the bot) or, for a Home
Server Admin, a channel such as #alerts. Messages keep the format the
Alertmanager Slack receivers used before 2026-11-20: one attachment whose
title is "[CRITICAL] <alertname> (<n>)" and similar, coloured by severity.
scripts/cluster_healthcheck.sh (check 49) reads #alerts by that title, so
keep it.

The bot (secret/viktor slack_bot_token) holds chat:write, chat:write.public
and im:write: it can post to public channels it has not joined and DM
anyone in the workspace.
"""

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request

from subs import Unavailable

log = logging.getLogger("notify-slack")

# Slack errors that are worth a retry; any other error is permanent.
RETRYABLE = {"ratelimited", "service_unavailable", "fatal_error", "internal_error", "request_timeout"}


def style(labels: dict) -> str:
    """The receiver the old route tree picked, in the same order."""
    lane = labels.get("lane")
    if lane == "event":
        return "event"
    if lane == "security":
        return "security"
    if labels.get("alertname") == "TrivyKnownExploitedCVE":
        return "critical"
    if labels.get("alertname") in ("UpgradeFixNotLanded", "TrivyExposedSecretInImage"):
        return "warning"
    severity = labels.get("severity")
    if severity == "critical":
        return "critical"
    if severity == "info":
        return "info"
    return "warning"


def message(payload: dict, page_url: str) -> dict:
    """One Alertmanager group -> a chat.postMessage body (without channel)."""
    alerts = payload.get("alerts") or []
    group = payload.get("groupLabels") or {}
    common = payload.get("commonLabels") or {}
    first = (alerts[0].get("labels") if alerts else None) or {}
    labels = {**first, **common, **group}
    name = labels.get("alertname", "Alert")
    firing = payload.get("status") != "resolved"
    kind = style(labels)
    n = len(alerts)

    def summary(a):
        return (a.get("annotations") or {}).get("summary", "")

    bullets = "".join("• %s\n" % summary(a) for a in alerts)
    if kind == "event":
        title, fallback, color = "[EVENT] %s" % name, name, "warning"
        text = bullets
    elif kind == "security":
        sev = (first.get("severity") or "").upper()
        title = ("[SECURITY/%s] %s (%d)" % (sev, name, n)) if firing else "[RESOLVED] %s (%d)" % (name, n)
        fallback = ("[SECURITY-%s]: %s" % (sev, name)) if firing else "[RESOLVED]: %s" % name
        color = ("danger" if first.get("severity") == "critical" else "warning") if firing else "good"
        parts = []
        for a in alerts:
            ann = a.get("annotations") or {}
            parts.append("*%s*\n" % ann.get("summary", ""))
            if ann.get("description"):
                parts.append(ann["description"] + "\n")
            if ann.get("runbook"):
                parts.append("Runbook: %s\n" % ann["runbook"])
        text = "".join(parts)
    else:
        word = {"critical": "CRITICAL", "info": "INFO", "warning": "WARNING"}[kind]
        title = ("[%s] %s (%d)" % (word, name, n)) if firing else "[RESOLVED] %s (%d)" % (name, n)
        fallback = ("%s: %s" % (word, name)) if firing else "RESOLVED: %s" % name
        firing_color = {"critical": "danger", "info": "#439FE0", "warning": "warning"}[kind]
        color = firing_color if firing else "good"
        text = bullets
    link = "<%s/a/%s|Notify me about this>" % (page_url, urllib.parse.quote(name))
    attachment = {"title": title, "text": text + link, "fallback": fallback, "color": color, "mrkdwn_in": ["text"]}
    return {"text": "", "attachments": [attachment]}


def unrouted_message(name: str, severity: str, page_url: str) -> dict:
    text = ":warning: *%s* (%s) fired and reached nobody. <%s/a/%s|Turn it on>" % (
        name, severity or "no severity", page_url, urllib.parse.quote(name))
    return {"text": text}


def test_message(notification: dict) -> dict:
    """The Test button's Slack post: the Phone/Email text in an attachment."""
    color = {"failure": "danger", "warning": "warning", "success": "good"}.get(notification.get("type"), "#439FE0")
    return {"text": "", "attachments": [{"title": notification["title"], "text": notification["body"],
                                          "fallback": notification["title"], "color": color}]}


class Slack:
    def __init__(self, token_file: str, timeout: float = 10, sleep=time.sleep, base="https://slack.com/api"):
        self.token_file = token_file
        self.timeout = timeout
        self.sleep = sleep
        self.url = base.rstrip("/") + "/chat.postMessage"

    def _once(self, body: dict):
        try:
            with open(self.token_file) as f:
                token = f.read().strip()
        except OSError as e:
            raise Unavailable("no Slack token: %s" % e) from e
        req = urllib.request.Request(
            self.url,
            data=json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return 200, json.loads(resp.read() or b"{}"), resp.headers
        except urllib.error.HTTPError as e:
            return e.code, {}, e.headers
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Unavailable("slack: %s" % e) from e

    def post(self, target: str, body: dict) -> str:
        """-> "sent" or "failed" (a permanent refusal); raises Unavailable
        when a retry may work, so Alertmanager tries again."""
        body = dict(body, channel=target)
        for attempt in (1, 2):
            status, answer, headers = self._once(body)
            if status == 200 and answer.get("ok"):
                return "sent"
            error = answer.get("error") or "http %d" % status
            if status == 429 or error in RETRYABLE or status >= 500:
                wait = float((headers or {}).get("Retry-After") or 1)
                if attempt == 1 and wait <= 3:
                    self.sleep(wait)
                    continue
                raise Unavailable("slack %s for %s" % (error, target))
            log.warning("slack refused a post to %s: %s", target, error)
            return "failed"
        raise Unavailable("slack: no answer")
