#!/usr/bin/env python3
"""Daily proxy-visit digest -> Slack #alerts.

Once a day, queries Loki for the visit lines emitted by the per-user browser
pods' visit-collector sidecars (see stacks/proxy/files/collector), builds a
per-user domain summary, and posts it to #alerts — but ONLY on days with
activity. The operator's own proxy account is excluded from the digest.

Full per-URL detail lives in the Grafana dashboard; this message is a scannable
domain summary, mirroring the alert-digest pattern (pure build_digest + thin
Loki/Slack I/O, DRY_RUN support, pure stdlib so the CronJob needs no pip).

Env (all have in-cluster defaults):
  LOKI_URL             default http://loki.monitoring.svc.cluster.local:3100
  DIGEST_HOURS         lookback window, default 24
  DIGEST_EXCLUDE_USER  a proxy username to omit (the operator), default empty
  SLACK_WEBHOOK_URL    Slack incoming-webhook URL. Empty (or DRY_RUN) -> print.
  SLACK_CHANNEL        default "#alerts"
  DRY_RUN              if set, print instead of posting.
"""
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

LOKI_URL = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100").rstrip("/")
DIGEST_HOURS = float(os.environ.get("DIGEST_HOURS", "24"))
EXCLUDE_USER = os.environ.get("DIGEST_EXCLUDE_USER", "").strip()
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "").strip()
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#alerts")
DRY_RUN = bool(os.environ.get("DRY_RUN", "")) or not SLACK_WEBHOOK_URL

VISIT_QUERY = '{namespace="proxy", container="visit-collector"}'


def _domain(url):
    """Registrable-ish host for the summary: hostname minus a leading www."""
    try:
        host = (urllib.parse.urlparse(url).hostname or "").lower()
    except Exception:
        host = ""
    if not host:
        return "(unknown)"
    return host[4:] if host.startswith("www.") else host


def build_digest(records, exclude_user, date_label):
    """Pure: parsed visit records -> the Slack message, or None if no activity.

    A record is a dict with at least `user` and `url`. Records for
    `exclude_user` are dropped. Returns None when nothing remains, so the caller
    posts nothing on quiet days.
    """
    by_user = {}
    for r in records:
        if not isinstance(r, dict):
            continue
        user = (r.get("user") or "").strip() or "(unknown)"
        if exclude_user and user == exclude_user:
            continue
        url = (r.get("url") or "").strip()
        if not url:
            continue
        by_user.setdefault(user, {})
        dom = _domain(url)
        by_user[user][dom] = by_user[user].get(dom, 0) + 1

    if not by_user:
        return None

    users = sorted(by_user)
    total = sum(sum(d.values()) for d in by_user.values())
    header = "*Proxy visits — %s*  (%d %s, %d pages)" % (
        date_label,
        len(users),
        "user" if len(users) == 1 else "users",
        total,
    )
    lines = [header]
    for user in users:
        doms = by_user[user]
        n = sum(doms.values())
        ranked = sorted(doms.items(), key=lambda kv: (-kv[1], kv[0]))
        summary = ", ".join("%s \u00d7%d" % (dom, c) for dom, c in ranked)
        lines.append("\u2022 *%s* (%d): %s" % (user, n, summary))
    return "\n".join(lines)


def _get_json(url, timeout=30):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def fetch_visits(hours):
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(hours=hours)
    q = urllib.parse.urlencode(
        {
            "query": VISIT_QUERY,
            "start": str(int(start.timestamp() * 1e9)),
            "end": str(int(end.timestamp() * 1e9)),
            "limit": "5000",
            "direction": "forward",
        }
    )
    data = _get_json("%s/loki/api/v1/query_range?%s" % (LOKI_URL, q))
    out = []
    for stream in data.get("data", {}).get("result", []):
        for _ts, line in stream.get("values", []):
            try:
                rec = json.loads(line)
            except Exception:
                continue  # stderr / non-JSON lines from the sidecar
            if isinstance(rec, dict) and rec.get("kind") == "nav":
                out.append(rec)
    return out


def post_to_slack(text):
    payload = {"channel": SLACK_CHANNEL, "text": text}
    if DRY_RUN:
        print("[DRY_RUN] would POST to Slack %s:\n%s" % (SLACK_CHANNEL, text))
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
        records = fetch_visits(DIGEST_HOURS)
    except Exception as e:
        # Loki unreachable — fail safe: log and send nothing rather than a garbage report.
        sys.stderr.write("proxy-visit-digest: Loki fetch failed (%s); sending nothing\n" % e)
        return
    date_label = datetime.datetime.now(datetime.timezone.utc).strftime("%a %d %b %Y")
    msg = build_digest(records, EXCLUDE_USER, date_label)
    if msg is None:
        sys.stderr.write("proxy-visit-digest: no activity in last %sh; nothing to post\n" % DIGEST_HOURS)
        return
    sys.stderr.write("proxy-visit-digest: %d visit records; posting digest\n" % len(records))
    post_to_slack(msg)


if __name__ == "__main__":
    main()
