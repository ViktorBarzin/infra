#!/usr/bin/env python3
"""Daily alert digest -> Slack.

Posts a once-a-day "state of the lab" summary to the #alerts Slack channel:
the full current board of firing alerts grouped by severity, plus a one-line
list of what fired-and-cleared in the last 24h.

This is the safety net for the "alert on change" routing model (warnings/info
no longer re-notify while firing; criticals re-ping slowly). The digest is the
recurring reminder of everything still firing, reviewed once each morning.

Pure stdlib (urllib + json) on purpose: the CronJob runs stock python:alpine
with NO pip/apk install at runtime, so it has none of the per-run disk-write
footprint that got status-page-pusher disabled (infra memory id=559).

Sources:
  * Current board  -> Alertmanager v2 (/api/v2/alerts): active, not silenced,
    not inhibited == exactly what a human would otherwise be paged about, with
    the human-readable `summary` annotation. Falls back to Prometheus ALERTS
    if Alertmanager is unreachable.
  * Resolved-in-24h -> Prometheus (alertnames seen firing in the last 24h that
    are not firing now). Best-effort; skipped silently if Prometheus errors.

Env (all have in-cluster defaults):
  ALERTMANAGER_URL   default http://prometheus-alertmanager.monitoring.svc.cluster.local:9093
  PROMETHEUS_URL     default http://prometheus-server.monitoring.svc.cluster.local:80
  SLACK_WEBHOOK_URL  Slack incoming-webhook URL. If empty (or DRY_RUN set),
                     the payload is printed to stdout instead of posted.
  SLACK_CHANNEL      default "#alerts"
  DRY_RUN            if set (any value), print instead of posting.
"""
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

ALERTMANAGER_URL = os.environ.get(
    "ALERTMANAGER_URL",
    "http://prometheus-alertmanager.monitoring.svc.cluster.local:9093",
).rstrip("/")
PROMETHEUS_URL = os.environ.get(
    "PROMETHEUS_URL",
    "http://prometheus-server.monitoring.svc.cluster.local:80",
).rstrip("/")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "").strip()
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#alerts")
DRY_RUN = bool(os.environ.get("DRY_RUN", "")) or not SLACK_WEBHOOK_URL

SEV_ORDER = ["critical", "warning", "info"]
SEV_EMOJI = {"critical": ":red_circle:", "warning": ":large_yellow_circle:", "info": ":large_blue_circle:"}


def _get_json(url, timeout=30):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _humanize(seconds):
    seconds = int(max(seconds, 0))
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    if d:
        return "%dd%dh" % (d, h)
    if h:
        return "%dh%dm" % (h, m)
    if m:
        return "%dm" % m
    return "<1m"


def _now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def _age(starts_at):
    if not starts_at:
        return ""
    try:
        ts = starts_at.replace("Z", "+00:00")
        # Trim sub-second precision beyond microseconds if present.
        started = datetime.datetime.fromisoformat(ts)
        return _humanize((_now_utc() - started).total_seconds())
    except ValueError:
        return ""


def fetch_current_from_alertmanager():
    """Active, non-silenced, non-inhibited alerts with their summaries."""
    q = urllib.parse.urlencode(
        {"active": "true", "silenced": "false", "inhibited": "false", "unprocessed": "false"}
    )
    data = _get_json("%s/api/v2/alerts?%s" % (ALERTMANAGER_URL, q))
    alerts = []
    for a in data:
        if a.get("status", {}).get("state") != "active":
            continue
        labels = a.get("labels", {})
        ann = a.get("annotations", {})
        alerts.append(
            {
                "alertname": labels.get("alertname", "?"),
                "severity": (labels.get("severity") or "info").lower(),
                "lane": labels.get("lane", ""),
                "summary": ann.get("summary", ""),
                "age": _age(a.get("startsAt", "")),
            }
        )
    return alerts


def fetch_current_from_prometheus():
    """Fallback: firing alerts from Prometheus (no summaries, includes inhibited)."""
    url = "%s/api/v1/query?%s" % (
        PROMETHEUS_URL,
        urllib.parse.urlencode({"query": 'ALERTS{alertstate="firing"}'}),
    )
    data = _get_json(url)
    alerts = []
    for s in data.get("data", {}).get("result", []):
        m = s.get("metric", {})
        alerts.append(
            {
                "alertname": m.get("alertname", "?"),
                "severity": (m.get("severity") or "info").lower(),
                "lane": m.get("lane", ""),
                "summary": "",
                "age": "",
            }
        )
    return alerts


def fetch_resolved_last_24h(active_names):
    """Alertnames that fired in the last 24h but are not firing now."""
    try:
        url = "%s/api/v1/query?%s" % (
            PROMETHEUS_URL,
            urllib.parse.urlencode(
                {"query": 'count by (alertname) (max_over_time(ALERTS{alertstate="firing"}[24h]))'}
            ),
        )
        data = _get_json(url)
        seen = {s["metric"].get("alertname", "?") for s in data.get("data", {}).get("result", [])}
        return sorted(seen - active_names)
    except Exception:
        return []


def build_message(alerts, resolved):
    today = _now_utc().strftime("%a %d %b %Y")
    by_sev = {s: [] for s in SEV_ORDER}
    for a in alerts:
        by_sev.setdefault(a["severity"], []).append(a)

    n = len(alerts)
    counts = " ".join("%s %d" % (s, len(by_sev.get(s, []))) for s in SEV_ORDER if by_sev.get(s))

    if n == 0:
        header = ":white_check_mark: *Daily alert digest* — %s\nAll clear: nothing firing." % today
    else:
        header = ":bar_chart: *Daily alert digest* — %s\nFiring now: *%d*%s" % (
            today,
            n,
            (" (" + counts + ")") if counts else "",
        )

    lines = [header]
    for sev in SEV_ORDER:
        items = sorted(by_sev.get(sev, []), key=lambda a: a["alertname"])
        if not items:
            continue
        lines.append("")
        lines.append("%s *%s (%d)*" % (SEV_EMOJI.get(sev, ""), sev.capitalize(), len(items)))
        for a in items:
            lock = ":lock: " if a["lane"] == "security" else ""
            age = (" _(%s)_" % a["age"]) if a["age"] else ""
            summary = (" — %s" % a["summary"]) if a["summary"] else ""
            lines.append("• %s*%s*%s%s" % (lock, a["alertname"], summary, age))

    # Any non-standard severities (defensive — shouldn't happen).
    extra = [s for s in by_sev if s not in SEV_ORDER and by_sev[s]]
    for sev in sorted(extra):
        lines.append("")
        lines.append("*%s (%d)*" % (sev, len(by_sev[sev])))
        for a in sorted(by_sev[sev], key=lambda a: a["alertname"]):
            lines.append("• *%s* — %s" % (a["alertname"], a["summary"]))

    if resolved:
        lines.append("")
        lines.append(":white_check_mark: Resolved in last 24h (%d): %s" % (len(resolved), ", ".join(resolved)))

    return "\n".join(lines)


def post_to_slack(text):
    payload = {"channel": SLACK_CHANNEL, "text": text}
    if DRY_RUN:
        print("[DRY_RUN] would POST to Slack channel %s:\n%s" % (SLACK_CHANNEL, text))
        return
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        SLACK_WEBHOOK_URL, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError("Slack POST failed: HTTP %d" % resp.status)


def main():
    try:
        alerts = fetch_current_from_alertmanager()
        source = "alertmanager"
    except Exception as e:
        sys.stderr.write("alertmanager fetch failed (%s); falling back to prometheus\n" % e)
        alerts = fetch_current_from_prometheus()
        source = "prometheus-fallback"

    active_names = {a["alertname"] for a in alerts}
    resolved = fetch_resolved_last_24h(active_names)
    text = build_message(alerts, resolved)
    sys.stderr.write("digest: %d firing (source=%s), %d resolved-24h\n" % (len(alerts), source, len(resolved)))
    post_to_slack(text)


if __name__ == "__main__":
    main()
