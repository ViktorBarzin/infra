#!/usr/bin/env python3
"""Nightly k8s-upgrade report -> Slack.

Runs each morning (CronJob k8s-upgrade-nightly-report) after the 23:00 UTC
version-check chain has finished. Reads the chain's Pushgateway gauges + live
cluster state and posts ONE concise, actionable report to Slack so the
autonomous upgrader's nightly outcome — and any blocker holding it back — is
visible at a glance during the upgrade-cleanup window.

Outcomes it distinguishes:
  ⚪ no upgrade needed     — cluster already at the latest supported patch
  🔴 BLOCKED              — compat gate refused the target; lists live reasons
  🟢 UPGRADED             — all nodes now on the detected target
  🟡 in progress / passed — gate passed, chain mid-flight (or partial)
  ⚠️  detector STALE       — the 23:00 detector did not run last night

Read-only. The pure helpers (parse_metrics / select / fmt_age / compose_report)
are unit-tested in test_nightly_report.py; all I/O (kubectl, Pushgateway, the
compat-gate subprocess, Slack) lives in thin wrappers below them.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

PUSHGW = os.environ.get("PUSHGW", "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics")
SLACK_FILE = os.environ.get("SLACK_FILE", "/secrets/k8s-upgrade/slack_webhook")
SCRIPTS_DIR = os.environ.get("SCRIPTS_DIR", "/scripts")
STALE_SECONDS = 90000  # ~25h: a nightly detector older than this didn't run last night

_METRIC_RE = re.compile(r"^(?P<name>\w+)(?:\{(?P<labels>[^}]*)\})?\s+(?P<value>[-+0-9.eE]+)\s*$")
_LABEL_RE = re.compile(r'(\w+)="([^"]*)"')


# ---------------------------------------------------------------- pure helpers
def parse_metrics(text):
    """Prometheus text exposition -> list of (name, {labels}, float value)."""
    out = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _METRIC_RE.match(line)
        if not m:
            continue
        labels = dict(_LABEL_RE.findall(m.group("labels") or ""))
        try:
            val = float(m.group("value"))
        except ValueError:
            continue
        out.append((m.group("name"), labels, val))
    return out


def select(metrics, name):
    """All (labels, value) tuples for a given metric name."""
    return [(lbl, val) for (n, lbl, val) in metrics if n == name]


def fmt_age(seconds):
    if seconds < 0:
        return "in the future?!"
    if seconds < 3600:
        return f"{int(seconds // 60)}m ago"
    if seconds < 86400:
        return f"{seconds / 3600:.1f}h ago"
    return f"{seconds / 86400:.1f}d ago"


def _render_reasons(blocker_reasons):
    """Group compat-gate reason lines by their [ACTIONABLE]/[WAITING]/[PINNED]
    tag into labelled sections, stripping the tag from each bullet. Untagged
    lines (older reason format) fall back to a generic 'Blockers' list. PURE.
    Returns a list of message lines."""
    lines = [r.strip() for r in (blocker_reasons or "").splitlines() if r.strip()]
    out, shown = [], set()
    for title, tag in (("Action needed", "[ACTIONABLE]"),
                       ("Waiting on upstream", "[WAITING]"),
                       ("Pinned (held by us)", "[PINNED]")):
        sub = [l for l in lines if l.startswith(tag)]
        if sub:
            out.append(f"{title}:")
            for l in sub:
                shown.add(l)
                out.append(f"  • {l[len(tag):].strip()}")
    rest = [l for l in lines if l not in shown]
    if rest:
        out.append("Blockers:")
        out.extend(f"  • {l}" for l in rest)
    return out


def compose_report(now_ts, nodes, metrics, blocker_reasons, jobs):
    """Build the Slack message text from gathered facts. PURE.

    nodes: list of (name, kubeletVersion). metrics: parse_metrics() output.
    blocker_reasons: multi-line str (compat-gate output) or None.
    jobs: list of {name, status, age_s}.
    """
    # kubelet reports "v1.35.6" but the gauges carry "1.35.6" — normalise so the
    # UPGRADED comparison against the target actually matches.
    versions = sorted({v.lstrip("v") for _, v in nodes})
    if len(versions) == 1:
        node_line = f"Running: *{versions[0]}* (all {len(nodes)} nodes uniform)"
    elif versions:
        node_line = f"Running: *MIXED* {', '.join(versions)} across {len(nodes)} nodes"
    else:
        node_line = "Running: *unknown* (could not read nodes)"

    lr = select(metrics, "k8s_version_check_last_run_timestamp")
    stale = False
    if lr:
        age = now_ts - lr[0][1]
        stale = age > STALE_SECONDS
        run_line = f"Last detector run: {fmt_age(age)} ({'STALE ⚠️' if stale else 'fresh ✓'})"
    else:
        run_line = "Last detector run: *unknown* (no metric)"
        stale = True

    avail = [(lbl, val) for lbl, val in select(metrics, "k8s_upgrade_available") if val == 1]
    blocked = any(val == 1 for _, val in select(metrics, "k8s_upgrade_blocked"))
    held = any(val == 1 for _, val in select(metrics, "k8s_upgrade_held"))

    if avail:
        lbl = avail[0][0]
        target = lbl.get("target", "?")
        kind = lbl.get("kind", "?")
        tgt_line = f"Detected target: *{target}* ({kind})"
        if blocked:
            # actionable block — an addon upgrade would clear it (K8sUpgradeBlocked fired)
            headline = f"🔴 BLOCKED (action needed) — {target}"
        elif held:
            # waiting on upstream and/or a pinned addon — nothing to do but wait;
            # intentionally NO alert, this nightly line is the only signal
            headline = f"⏸️ HELD — {target} not yet upgradable"
        elif len(versions) == 1 and target == versions[0]:
            headline = f"🟢 UPGRADED — all nodes now on {target}"
        else:
            headline = f"🟡 IN PROGRESS / gate passed for {target}"
    else:
        target = None
        tgt_line = "Detected target: none"
        headline = "⚪ No upgrade needed (cluster at latest supported patch)"

    if stale:
        headline = "⚠️ Detector did not run last night — " + headline

    msg = [f"*[k8s-upgrade nightly]* {headline}", node_line, run_line, tgt_line]

    if (blocked or held) and blocker_reasons:
        msg.extend(_render_reasons(blocker_reasons))

    if jobs:
        msg.append("Chain jobs (recent):")
        for j in jobs:
            msg.append(f"  • {j['name']}: {j['status']} ({fmt_age(j['age_s'])})")

    return "\n".join(msg)


# ----------------------------------------------------------------------- I/O
def _kubectl_json(args):
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=30)
        return json.loads(r.stdout) if r.stdout.strip() else {}
    except Exception:
        return {}


def get_nodes():
    d = _kubectl_json(["get", "nodes", "-o", "json"])
    return [(it["metadata"]["name"],
             it.get("status", {}).get("nodeInfo", {}).get("kubeletVersion", "?"))
            for it in d.get("items", [])]


def _job_status(it):
    st = it.get("status", {})
    for c in st.get("conditions", []):
        if c.get("type") == "Failed" and c.get("status") == "True":
            return "Failed"
        if c.get("type") == "Complete" and c.get("status") == "True":
            return "Complete"
    if st.get("active"):
        return "Active"
    return "Pending"


def get_jobs(now_ts):
    import datetime
    d = _kubectl_json(["-n", "k8s-upgrade", "get", "jobs", "-o", "json"])
    out = []
    for it in d.get("items", []):
        ct = it["metadata"].get("creationTimestamp")
        try:
            age = now_ts - datetime.datetime.strptime(
                ct, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        except Exception:
            age = 0
        if age <= 93600:  # last 26h only
            out.append({"name": it["metadata"]["name"], "status": _job_status(it), "age_s": age})
    return sorted(out, key=lambda j: j["age_s"])


def get_blocker_reasons(target):
    try:
        with open(f"{SCRIPTS_DIR}/addon-compat.json") as f:
            matrix = f.read()
        r = subprocess.run(["python3", f"{SCRIPTS_DIR}/compat-gate.py", target],
                           input=matrix, capture_output=True, text=True, timeout=60)
        return r.stdout.strip()
    except Exception as e:
        return f"(could not run compat-gate: {e})"


def post_slack(text):
    if os.environ.get("DRY_RUN"):
        return  # main() always prints the message; DRY_RUN just skips the POST
    with open(SLACK_FILE) as f:
        url = f.read().strip()
    data = json.dumps({"text": text}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=20)


def main():
    import time
    now_ts = float(os.environ.get("NOW_TS", "")) if os.environ.get("NOW_TS") else time.time()
    try:
        metrics_txt = urllib.request.urlopen(PUSHGW, timeout=20).read().decode()
    except Exception:
        metrics_txt = ""
    metrics = parse_metrics(metrics_txt)
    nodes = get_nodes()
    jobs = get_jobs(now_ts)

    avail = [(lbl, val) for lbl, val in select(metrics, "k8s_upgrade_available") if val == 1]
    blocked = any(val == 1 for _, val in select(metrics, "k8s_upgrade_blocked"))
    held = any(val == 1 for _, val in select(metrics, "k8s_upgrade_held"))
    reasons = get_blocker_reasons(avail[0][0].get("target", "")) if (avail and (blocked or held)) else None

    msg = compose_report(now_ts, nodes, metrics, reasons, jobs)
    post_slack(msg)
    print(msg)


if __name__ == "__main__":
    main()
