#!/usr/bin/env python3
"""Is canonical infra CI red? Every 10 minutes, to the Pushgateway.

Reads the newest push pipelines on master of Woodpecker repo 82 (Forgejo
viktor/infra, the registration that really applies) and pushes:

  infra_ci_red_streak                         newest pipelines in a row that
                                              ended error/failure/killed
  infra_ci_last_success_timestamp_seconds     when the newest success finished
                                              (0 when none is in the window)
  infra_ci_newest_red_pipeline                its number, 0 when the streak is 0
  infra_ci_status_last_run_timestamp_seconds  heartbeat for InfraCIStatusStale

running, pending and the other unfinished states count neither way. Repo 1,
the GitHub mirror, is never read: its push apply is a forge-guard no-op and
always green.

The InfraCIRed rule (prometheus_chart_values.tpl, group "Infra CI") fires on
streak >= 2 and no success for 1h. Why: from 2026-11-26 12:08 every repo-82
pipeline ended `error` at lint time with no steps, so the in-pipeline Slack
step never ran and nothing applied for a day.

A failed read exits 1 without pushing, so the heartbeat goes stale.
Tests: python3 infra_ci_status_test.py
"""
import json
import os
import sys
import time
import urllib.request
from typing import NamedTuple

WOODPECKER_API = os.environ.get("WOODPECKER_API", "http://woodpecker-server.woodpecker.svc.cluster.local/api")
REPO_ID = os.environ.get("WOODPECKER_REPO_ID", "82")
TOKEN = os.environ.get("WOODPECKER_API_TOKEN", "")
PUSHGATEWAY_URL = os.environ.get("PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091")
DRY_RUN = os.environ.get("DRY_RUN") == "1"

RED = frozenset({"error", "failure", "killed"})
PER_PAGE = 50   # Woodpecker's page size cap
MAX_PAGES = 10  # 500 pipelines, about a week of pushes


class Status(NamedTuple):
    red_streak: int
    last_success: int
    newest_red: int


def parse_json(raw):
    # strict=False: repo 82's pipeline JSON has carried raw control characters.
    return json.loads(raw, strict=False)


def newest_master_pushes(pipelines):
    return sorted((p for p in pipelines if p.get("event") == "push" and p.get("branch") == "master"),
                  key=lambda p: p["number"], reverse=True)


def summarise(pipelines):
    streak, newest_red = 0, 0
    for p in newest_master_pushes(pipelines):
        status = p.get("status")
        if status == "success":
            return Status(streak, int(p.get("finished") or p.get("created") or 0), newest_red)
        if status in RED:
            streak += 1
            newest_red = newest_red or p["number"]
    return Status(streak, 0, newest_red)


def metrics_text(s, now):
    gauges = [
        ("infra_ci_red_streak", "Newest repo-82 master push pipelines in a row that ended error/failure/killed.", s.red_streak),
        ("infra_ci_last_success_timestamp_seconds", "Finish time of the newest successful repo-82 master push pipeline, 0 if none in the window.", s.last_success),
        ("infra_ci_newest_red_pipeline", "Number of the newest red repo-82 master push pipeline, 0 when the streak is 0.", s.newest_red),
        ("infra_ci_status_last_run_timestamp_seconds", "When infra-ci-status last read Woodpecker and pushed.", now),
    ]
    out = []
    for name, help_text, value in gauges:
        out += ["# HELP %s %s" % (name, help_text), "# TYPE %s gauge" % name, "%s %d" % (name, value)]
    return "\n".join(out) + "\n"


def fetch_page(page):
    url = "%s/repos/%s/pipelines?branch=master&event=push&perPage=%d&page=%d" % (WOODPECKER_API, REPO_ID, PER_PAGE, page)
    headers = {"Authorization": "Bearer %s" % TOKEN} if TOKEN else {}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as resp:
        return parse_json(resp.read().decode("utf-8"))


def fetch_until_success():
    pipelines = []
    for page in range(1, MAX_PAGES + 1):
        batch = fetch_page(page)
        pipelines += batch
        if not batch or any(p.get("status") == "success" for p in newest_master_pushes(batch)):
            break
    return pipelines


def push_metrics(text):
    if DRY_RUN:
        print(text, end="")
        return
    req = urllib.request.Request("%s/metrics/job/infra-ci-status" % PUSHGATEWAY_URL, data=text.encode("utf-8"),
                                 method="PUT", headers={"Content-Type": "text/plain; version=0.0.4"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError("Pushgateway PUT failed: HTTP %d" % resp.status)


def main():
    pipelines = fetch_until_success()
    s = summarise(pipelines)
    push_metrics(metrics_text(s, int(time.time())))
    print("infra-ci-status: repo %s, %d pipelines read, red_streak=%d newest_red=#%d last_success=%d"
          % (REPO_ID, len(pipelines), s.red_streak, s.newest_red, s.last_success))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 - one line in the job log, then a failed Job
        print("infra-ci-status: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)
