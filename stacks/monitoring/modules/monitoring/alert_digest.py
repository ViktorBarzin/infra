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
  TRIVY_WEEKDAY      day the weekly Trivy section is appended (Mon..Sun or
                     0..6, default Mon). "never" turns the section off.

Weekly Trivy section (software-currency design, Phase 2): once a week the
digest appends a summary of the Trivy Operator findings that do not alert on
their own: Critical/High CVE totals with the fixable/unfixable split and the
change since last week, the top fixable images, config-audit, RBAC and
control-plane findings, and failed compliance controls. Fixable Critical/High
CVEs on internet-reachable workloads and secrets in images alert separately
(TrivyFixableCVEInternetReachable, TrivyExposedSecretInImage). Source:
trivy_* metrics in Prometheus (docs/architecture/trivy.md).
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

TRIVY_WEEKDAY_RAW = os.environ.get("TRIVY_WEEKDAY", "Mon")

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


# ---------------------------------------------------------------------------
# Weekly Trivy section
# ---------------------------------------------------------------------------

_WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
TRIVY_SEVERITIES = ["Critical", "High"]
# trivy.severity (stacks/trivy-operator) is CRITICAL,HIGH and applies to every
# scanner, config audit and RBAC included, so lower severities are never stored.
FINDING_SEVERITIES = ["Critical", "High"]

# A namespace is internet-reachable when any of its ingresses is proxied or
# non-proxied (the dns-type annotation ingress_factory stamps on every ingress).
_PUBLIC_NS = (
    'count by (namespace) (kube_ingress_annotations{'
    'annotation_cloudflare_viktorbarzin_me_dns_type=~"proxied|non-proxied"})'
)
# last_over_time(...[1h]) bridges the gap while a report is deleted at its 24h
# TTL and rescanned, so a mid-rescan instant does not undercount.
_VULN = 'trivy_image_vulnerabilities{severity=~"Critical|High"}'
TRIVY_QUERIES = {
    "vuln_total": "sum by (severity) (last_over_time(%s[1h]))" % _VULN,
    "vuln_total_prev": "sum by (severity) (last_over_time(%s[1h] offset 7d))" % _VULN,
    "scanned": "count(count by (namespace, name) (trivy_image_vulnerabilities))",
    # trivy_vulnerability_id is filtered at scrape time to fixable Critical/High.
    "fixable": "count by (severity) (last_over_time(trivy_vulnerability_id[1h]))",
    "fixable_prev": "count by (severity) (last_over_time(trivy_vulnerability_id[1h] offset 7d))",
    "fixable_public": (
        "count by (severity) (last_over_time(trivy_vulnerability_id[1h]) and on (namespace) %s)" % _PUBLIC_NS
    ),
    "top_fixable": (
        "topk(10, count by (namespace, image_repository, image_tag) "
        "(last_over_time(trivy_vulnerability_id[1h])))"
    ),
    "public_ns": _PUBLIC_NS,
    "secret_images": "count(count by (namespace, image_repository, image_tag) (trivy_image_exposedsecrets > 0))",
    "config_audit": "sum by (severity) (trivy_resource_configaudits)",
    "config_audit_prev": "sum by (severity) (trivy_resource_configaudits offset 7d)",
    "rbac": (
        'sum by (severity) ({__name__=~"trivy_role_rbacassessments|trivy_clusterrole_clusterrbacassessments"})'
    ),
    "infra": "sum by (severity) (trivy_resource_infraassessments)",
    "compliance_fail": 'max by (title) (trivy_cluster_compliance{status="Fail"})',
}


def parse_weekday(raw):
    """'Mon'/'monday'/'0' -> 0..6; anything else (e.g. 'never') -> None."""
    raw = (raw or "").strip().lower()
    if raw.isdigit() and 0 <= int(raw) <= 6:
        return int(raw)
    for i, name in enumerate(_WEEKDAYS):
        if raw.startswith(name):
            return i
    return None


def is_trivy_day(now, weekday):
    """True when `now` falls on `weekday` (0 = Monday)."""
    return weekday is not None and now.weekday() == weekday


def _delta(cur, prev):
    if prev is None:
        return "no data a week ago"
    d = int(cur) - int(prev)
    if d > 0:
        return "+%d" % d
    if d < 0:
        return "%d" % d
    return "\u00b10"


def _by_label(result, label):
    out = {}
    for r in result:
        key = r.get("metric", {}).get(label, "")
        out[key] = int(float(r["value"][1]))
    return out


def _scalar(result):
    return int(float(result[0]["value"][1])) if result else 0


def collect_trivy_stats(query):
    """Run TRIVY_QUERIES through `query(promql) -> result list` and shape them.

    A "_prev" (week-ago) value is None when Prometheus has no data for it, so
    the message can say so instead of reporting a change from zero.
    """
    raw = {k: query(q) for k, q in TRIVY_QUERIES.items()}
    public = set(_by_label(raw["public_ns"], "namespace"))
    top = []
    for r in raw["top_fixable"]:
        m = r.get("metric", {})
        top.append(
            {
                "namespace": m.get("namespace", "?"),
                "image": "%s:%s" % (m.get("image_repository", "?"), m.get("image_tag", "?")),
                "count": int(float(r["value"][1])),
                "public": m.get("namespace") in public,
            }
        )
    top.sort(key=lambda t: (-t["count"], t["namespace"], t["image"]))

    def sev(key):
        return _by_label(raw[key], "severity")

    def sev_or_none(key):
        return sev(key) if raw[key] else None

    return {
        "scanned": _scalar(raw["scanned"]),
        "vuln_total": sev("vuln_total"),
        "vuln_total_prev": sev_or_none("vuln_total_prev"),
        "fixable": sev("fixable"),
        "fixable_prev": sev_or_none("fixable_prev"),
        "fixable_public": sev("fixable_public"),
        "top_fixable": top,
        "secret_images": _scalar(raw["secret_images"]),
        "config_audit": sev("config_audit"),
        "config_audit_prev": sev_or_none("config_audit_prev"),
        "rbac": sev("rbac"),
        "infra": sev("infra"),
        "compliance_fail": _by_label(raw["compliance_fail"], "title"),
    }


def _fmt_counts(cur, prev, severities):
    """'Critical 5 (+1), High 50 (-2)', or a single trailing note without prev."""
    if prev is None:
        body = ", ".join("%s %d" % (s, cur.get(s, 0)) for s in severities)
        return "%s (no data a week ago)" % body
    return ", ".join("%s %d (%s)" % (s, cur.get(s, 0), _delta(cur.get(s, 0), prev.get(s, 0))) for s in severities)


def _fmt_plain(cur, severities):
    return ", ".join("%s %d" % (s, cur.get(s, 0)) for s in severities)


def build_trivy_section(stats):
    header = ":shield: *Weekly Trivy summary*"
    if not stats.get("scanned"):
        return header + "\nNo scan data in Prometheus. Check the trivy-operator pod in trivy-system."

    vt, fx = stats["vuln_total"], stats["fixable"]
    unfixable = {s: max(vt.get(s, 0) - fx.get(s, 0), 0) for s in TRIVY_SEVERITIES}
    lines = [
        "%s (%d workload containers scanned)" % (header, stats["scanned"]),
        "\u2022 Critical/High CVEs: %s" % _fmt_counts(vt, stats["vuln_total_prev"], TRIVY_SEVERITIES),
        "\u2022 fixable %s; unfixable %s"
        % (_fmt_counts(fx, stats["fixable_prev"], TRIVY_SEVERITIES), _fmt_plain(unfixable, TRIVY_SEVERITIES)),
        "\u2022 fixable on internet-reachable workloads: %s (these alert per namespace)"
        % _fmt_plain(stats["fixable_public"], TRIVY_SEVERITIES),
    ]
    if stats["top_fixable"]:
        lines.append("\u2022 Top fixable images:")
        for t in stats["top_fixable"]:
            tag = " (internet-reachable)" if t["public"] else ""
            lines.append("    \u2013 %s %s: %d%s" % (t["namespace"], t["image"], t["count"], tag))
    lines.append("\u2022 Secrets found in %d image(s) (these alert on their own)" % stats["secret_images"])

    ca, ca_prev = stats["config_audit"], stats["config_audit_prev"]
    total_ca = sum(ca.values())
    ca_change = _delta(total_ca, sum(ca_prev.values()) if ca_prev is not None else None)
    lines.append("\u2022 Config audit: %s (total %s)" % (_fmt_plain(ca, FINDING_SEVERITIES), ca_change))
    lines.append("\u2022 RBAC: %s" % _fmt_plain(stats["rbac"], FINDING_SEVERITIES))
    lines.append("\u2022 Control-plane assessment: %s" % _fmt_plain(stats["infra"], FINDING_SEVERITIES))
    if stats["compliance_fail"]:
        lines.append(
            "\u2022 Failed compliance controls: "
            + ", ".join("%s: %d" % (k, v) for k, v in sorted(stats["compliance_fail"].items()))
        )
    lines.append("Details: `kubectl get vulnerabilityreports -A`, runbook docs/runbooks/trivy-operator.md")
    return "\n".join(lines)


def prometheus_query(promql):
    url = "%s/api/v1/query?%s" % (PROMETHEUS_URL, urllib.parse.urlencode({"query": promql}))
    return _get_json(url).get("data", {}).get("result", [])


def trivy_section_if_due(now):
    """The Trivy section on its weekday, else None. Never raises."""
    weekday = parse_weekday(TRIVY_WEEKDAY_RAW)
    if not is_trivy_day(now, weekday):
        return None
    try:
        return build_trivy_section(collect_trivy_stats(prometheus_query))
    except Exception as e:  # noqa: BLE001 - the daily digest must still post
        sys.stderr.write("trivy section failed: %s\n" % e)
        return ":shield: *Weekly Trivy summary* unavailable (%s)" % e


# More instances of one alertname than this collapse into a single digest line.
COLLAPSE_OVER = 5


def _group_by_name(items):
    """Consecutive runs of the same alertname (items arrive sorted by name)."""
    groups = []
    for a in items:
        if groups and groups[-1][0]["alertname"] == a["alertname"]:
            groups[-1].append(a)
        else:
            groups.append([a])
    return groups


def build_message(alerts, resolved, trivy_section=None):
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
        for group in _group_by_name(items):
            a = group[0]
            lock = ":lock: " if a["lane"] == "security" else ""
            age = (" _(%s)_" % a["age"]) if a["age"] else ""
            summary = (" — %s" % a["summary"]) if a["summary"] else ""
            if len(group) > COLLAPSE_OVER:
                # Per-namespace or per-image alerts (e.g. the Trivy ones) can
                # number in the dozens; one line keeps the digest readable.
                lines.append(
                    "• %s*%s* \u00d7%d%s (+%d more, see Alertmanager)%s"
                    % (lock, a["alertname"], len(group), summary, len(group) - 1, age)
                )
                continue
            for a in group:
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

    if trivy_section:
        lines.append("")
        lines.append(trivy_section)

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
    # The CronJob runs at 08:00 Europe/London, so the UTC weekday matches the
    # London one at that hour all year.
    text = build_message(alerts, resolved, trivy_section=trivy_section_if_due(_now_utc()))
    sys.stderr.write("digest: %d firing (source=%s), %d resolved-24h\n" % (len(alerts), source, len(resolved)))
    post_to_slack(text)


if __name__ == "__main__":
    main()
