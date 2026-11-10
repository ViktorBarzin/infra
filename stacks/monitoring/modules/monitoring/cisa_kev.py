#!/usr/bin/env python3
"""Load CISA's Known Exploited Vulnerabilities catalogue into Prometheus.

Runs daily as the cisa-kev CronJob (cisa_kev.tf). Downloads the catalogue and
PUTs one series per CVE to the Pushgateway:

    cisa_kev_listed{vuln_id="CVE-..."}       the date CISA added it, epoch seconds
    cisa_kev_entries                         number of CVEs in the catalogue
    cisa_kev_last_success_timestamp_seconds  when this run finished

The TrivyKnownExploitedCVE alert joins cisa_kev_listed on vuln_id with
Trivy's trivy_vulnerability_id. A download that fails, or a catalogue smaller
than MIN_ENTRIES (a truncated or wrong file), pushes nothing, so the previous
catalogue stays in place and CisaKevFeedStale fires after 3 days.

Tests: python3 cisa_kev_test.py
"""
import datetime
import json
import os
import re
import sys
import time
import urllib.request

FEED_URL = os.environ.get(
    "KEV_URL", "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json")
PUSHGATEWAY_URL = os.environ.get("PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091")
# 1,773 entries on 2026-11-10; the catalogue only grows.
MIN_ENTRIES = int(os.environ.get("MIN_ENTRIES", "1000"))
DRY_RUN = os.environ.get("DRY_RUN") == "1"

CVE_RE = re.compile(r"^CVE-\d{4}-\d{4,}$")


class FeedError(Exception):
    pass


def _date_epoch(value):
    try:
        d = datetime.date.fromisoformat(value)
    except (TypeError, ValueError):
        return 0
    return int(datetime.datetime(d.year, d.month, d.day, tzinfo=datetime.timezone.utc).timestamp())


def parse_feed(feed, min_entries=MIN_ENTRIES):
    """Return {cve_id: date_added_epoch}. Raises FeedError on a bad catalogue."""
    vulns = feed.get("vulnerabilities") if isinstance(feed, dict) else None
    if not isinstance(vulns, list):
        raise FeedError("catalogue has no vulnerabilities list")
    out = {}
    for v in vulns:
        cve = v.get("cveID") if isinstance(v, dict) else None
        if not isinstance(cve, str) or not CVE_RE.match(cve) or cve in out:
            continue
        out[cve] = _date_epoch(v.get("dateAdded"))
    if len(out) < min_entries:
        raise FeedError("catalogue has %d CVEs, expected at least %d" % (len(out), min_entries))
    return out


def metrics_text(kev, now):
    lines = ["# TYPE cisa_kev_listed gauge"]
    lines += ['cisa_kev_listed{vuln_id="%s"} %d' % (cve, added) for cve, added in sorted(kev.items())]
    lines += [
        "# TYPE cisa_kev_entries gauge",
        "cisa_kev_entries %d" % len(kev),
        "# TYPE cisa_kev_last_success_timestamp_seconds gauge",
        "cisa_kev_last_success_timestamp_seconds %d" % now,
    ]
    return "\n".join(lines) + "\n"


def fetch_feed():
    req = urllib.request.Request(FEED_URL, headers={"User-Agent": "homelab-cisa-kev/1"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def push_metrics(text):
    if DRY_RUN:
        print("[DRY_RUN] would PUT %d bytes to Pushgateway" % len(text))
        return
    req = urllib.request.Request("%s/metrics/job/cisa-kev" % PUSHGATEWAY_URL, data=text.encode("utf-8"),
                                 method="PUT", headers={"Content-Type": "text/plain; version=0.0.4"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError("Pushgateway PUT failed: HTTP %d" % resp.status)


def main():
    kev = parse_feed(fetch_feed())
    push_metrics(metrics_text(kev, int(time.time())))
    print("cisa-kev: pushed %d known-exploited CVEs" % len(kev))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # the CronJob retries; the stale alert covers a lasting failure
        print("cisa-kev: %s" % e, file=sys.stderr)
        sys.exit(1)
