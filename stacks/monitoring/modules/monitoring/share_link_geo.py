#!/usr/bin/env python3
"""Daily Immich share-link geo analytics -> Pushgateway.

Answers "how many distinct people opened this share link, and from which
country?" without putting per-IP data into Prometheus labels and without
touching the Alloy ingest path (a GeoIP mmdb dependency at log-shipper
startup would couple log shipping to a download/NFS mount, which is exactly
the coupling docs forbid for monitoring-critical components).

Pipeline, once a day:
  1. Download the DB-IP Country Lite database (CSV edition) - free, no
     account/license key. Licensed CC-BY 4.0: this product includes DB-IP
     data from https://db-ip.com (attribution satisfied by this notice).
  2. Sweep Loki for per-(slug, ip) request/open counts over the trailing
     window (default 30d = Loki retention), in 72h instant-query chunks; one
     unchunked 720h metric query 504s the SingleBinary (learned 2026-07-06).
  3. Classify IPs: internal/preview-proxy CIDRs are excluded from visitor
     counts (they are Viktor's own devices, the devvm, or Meta's WhatsApp/
     Messenger link-preview fetchers - fbsv.net fwdproxy fleet); the rest
     resolve to a country.
  4. PUT one metric group to the Pushgateway (replaces the previous run, so
     slugs that age out of the window disappear rather than going stale).

Pure stdlib (urllib/gzip/csv/ipaddress/bisect/array) on stock
python:3.12-alpine - no pip/apk at runtime (alert-digest pattern).
"""

import bisect
import csv
import gzip
import io
import ipaddress
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from array import array
from datetime import datetime, timedelta, timezone

LOKI_URL = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
PUSHGATEWAY_URL = os.environ.get(
    "PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091"
)
WINDOW_HOURS = int(os.environ.get("WINDOW_HOURS", "720"))
CHUNK_HOURS = int(os.environ.get("CHUNK_HOURS", "72"))
DBIP_URL_TEMPLATE = os.environ.get(
    "DBIP_URL_TEMPLATE",
    "https://download.db-ip.com/free/dbip-country-lite-{month}.csv.gz",
)
# Internal ranges + Meta's link-preview/fwdproxy ranges (AS32934). Excluded
# from visitor counts; reported via immich_share_link_excluded_ips instead.
EXCLUDE_CIDRS = [
    ipaddress.ip_network(c.strip())
    for c in os.environ.get(
        "EXCLUDE_CIDRS",
        "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,169.254.0.0/16,"
        "100.64.0.0/10,fc00::/7,::1/128,"
        "31.13.24.0/21,31.13.64.0/18,66.220.144.0/20,69.63.176.0/20,"
        "69.171.224.0/19,74.119.76.0/22,102.132.96.0/20,103.4.96.0/22,"
        "129.134.0.0/16,157.240.0.0/16,173.252.64.0/18,179.60.192.0/22,"
        "185.60.216.0/22,204.15.20.0/22",
    ).split(",")
]

# LogQL: keep in sync with the recording rules in loki.tf ("immich-immich" is
# the main Immich router token; immich-frame kiosk routers don't match it).
# GUARDS (load-bearing, mirror loki.tf): slug/ip extraction is ANCHORED to
# the CLF request-line position because log lines carry attacker-controlled
# User-Agent/Referer since 2026-07-06 — an unanchored regexp would let any
# client mint arbitrary slug label values via a crafted header. Status
# 2xx/304 required: Immich 404s unknown /s/<slug> and 401s bad ?slug= API
# calls, so junk-slug probes don't count.
SLUG_RE = r"(?P<slug>[A-Za-z0-9][A-Za-z0-9_-]{0,63})"
CLF_STATUS = r' | regexp `^\S+ - \S+ \[[^\]]*\] "[^"]*" (?P<status>[0-9]{3}) ` | status =~ "2..|304"'
Q_REQUESTS = (
    r'sum by (slug, ip) (count_over_time({namespace="traefik"} |= "immich-immich"'
    r' |= "slug="'
    r' | regexp `^(?P<ip>[0-9a-fA-F.:]+) - \S+ \[[^\]]*\] "[A-Z]+ [^" ]*[?&]slug=' + SLUG_RE + r'`'
    r' | slug != "" | ip != ""' + CLF_STATUS + r' [%dh]))' % CHUNK_HOURS
)
Q_OPENS = (
    r'sum by (slug, ip) (count_over_time({namespace="traefik"} |= "immich-immich"'
    r' |~ `"(GET|HEAD) /s/`'
    r' | regexp `^(?P<ip>[0-9a-fA-F.:]+) - \S+ \[[^\]]*\] "(?:GET|HEAD) /s/' + SLUG_RE + r'[ ?/]`'
    r' | slug != "" | ip != ""' + CLF_STATUS + r' [%dh]))' % CHUNK_HOURS
)


def http_get(url, timeout=300):
    req = urllib.request.Request(url, headers={"User-Agent": "share-link-geo/1.0"})
    return urllib.request.urlopen(req, timeout=timeout)


def load_dbip():
    """Download + parse DB-IP Country Lite. Returns (v4 arrays, v6 lists)."""
    now = datetime.now(timezone.utc)
    months = [now.strftime("%Y-%m"), (now.replace(day=1) - timedelta(days=1)).strftime("%Y-%m")]
    raw, used_month, last_err = None, None, None
    for month in months:
        url = DBIP_URL_TEMPLATE.format(month=month)
        try:
            with http_get(url) as resp:
                raw = resp.read()
            used_month = month
            break
        except urllib.error.HTTPError as e:  # month not published yet -> previous
            last_err = e
    if raw is None:
        raise RuntimeError(f"DB-IP download failed for {months}: {last_err}")

    v4_starts, v4_ends, v4_ccs = array("Q"), array("Q"), []
    v6 = []  # (start_int, end_int, cc) - 128-bit ints don't fit array('Q')
    with gzip.open(io.BytesIO(raw), "rt", encoding="utf-8", errors="replace") as fh:
        for row in csv.reader(fh):
            if len(row) < 3:
                continue
            try:
                start, end = ipaddress.ip_address(row[0]), ipaddress.ip_address(row[1])
            except ValueError:
                continue
            if start.version == 4:
                v4_starts.append(int(start))
                v4_ends.append(int(end))
                v4_ccs.append(row[2])
            else:
                v6.append((int(start), int(end), row[2]))
    v6.sort(key=lambda t: t[0])
    if len(v4_starts) < 100_000:  # sanity: a truncated download would undercount
        raise RuntimeError(f"DB-IP v4 table suspiciously small: {len(v4_starts)} rows")
    print(f"dbip loaded ({used_month}): {len(v4_starts)} v4 + {len(v6)} v6 ranges", flush=True)
    return v4_starts, v4_ends, v4_ccs, v6


def country_of(ip_str, v4_starts, v4_ends, v4_ccs, v6):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return "unknown"
    n = int(ip)
    if ip.version == 4:
        i = bisect.bisect_right(v4_starts, n) - 1
        if i >= 0 and v4_ends[i] >= n:
            return v4_ccs[i]
    else:
        i = bisect.bisect_right(v6, (n, 2**128, "")) - 1
        if i >= 0 and v6[i][1] >= n:
            return v6[i][2]
    return "unknown"


def is_excluded(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True
    return any(ip in net for net in EXCLUDE_CIDRS)


def loki_instant(query, at_epoch):
    params = urllib.parse.urlencode({"query": query, "time": str(at_epoch)})
    with http_get(f"{LOKI_URL}/loki/api/v1/query?{params}") as resp:
        body = json.load(resp)
    if body.get("status") != "success":
        raise RuntimeError(f"loki query failed: {body}")
    return body["data"]["result"]


def sweep(query_tpl):
    """Chunked sweep over WINDOW_HOURS. Returns {slug: {ip: count}}."""
    end = int(time.time())
    out = {}
    for i in range(0, WINDOW_HOURS, CHUNK_HOURS):
        at = end - i * 3600
        for series in loki_instant(query_tpl, at):
            slug = series["metric"].get("slug", "")
            ip = series["metric"].get("ip", "")
            if not slug or not ip:
                continue
            out.setdefault(slug, {})[ip] = out.get(slug, {}).get(ip, 0) + int(
                float(series["value"][1])
            )
    return out


def main():
    v4s, v4e, v4c, v6 = load_dbip()
    requests_by = sweep(Q_REQUESTS)
    opens_by = sweep(Q_OPENS)
    slugs = sorted(set(requests_by) | set(opens_by))

    # Text exposition requires all samples of a metric family to be grouped
    # under one TYPE line - collect per-family, then emit family by family.
    fam = {
        "immich_share_link_unique_ips": [],
        "immich_share_link_unique_ips_by_country": [],
        "immich_share_link_excluded_ips": [],
        "immich_share_link_requests_window": [],
        "immich_share_link_opens_window": [],
    }
    for slug in slugs:
        ips = set(requests_by.get(slug, {})) | set(opens_by.get(slug, {}))
        external = [ip for ip in ips if not is_excluded(ip)]
        excluded = len(ips) - len(external)
        by_country = {}
        for ip in external:
            cc = country_of(ip, v4s, v4e, v4c, v6)
            by_country[cc] = by_country.get(cc, 0) + 1
        fam["immich_share_link_unique_ips"].append(
            f'immich_share_link_unique_ips{{slug="{slug}"}} {len(external)}'
        )
        for cc, cnt in sorted(by_country.items()):
            fam["immich_share_link_unique_ips_by_country"].append(
                f'immich_share_link_unique_ips_by_country{{slug="{slug}",country="{cc}"}} {cnt}'
            )
        fam["immich_share_link_excluded_ips"].append(
            f'immich_share_link_excluded_ips{{slug="{slug}"}} {excluded}'
        )
        fam["immich_share_link_requests_window"].append(
            f'immich_share_link_requests_window{{slug="{slug}"}} '
            f"{sum(requests_by.get(slug, {}).values())}"
        )
        fam["immich_share_link_opens_window"].append(
            f'immich_share_link_opens_window{{slug="{slug}"}} '
            f"{sum(opens_by.get(slug, {}).values())}"
        )
        print(f"{slug}: {len(external)} external IPs {by_country}, "
              f"{excluded} excluded", flush=True)

    lines = [
        "# HELP immich_share_link_unique_ips Distinct external visitor IPs per share link over the window (internal + preview-bot CIDRs excluded)"
    ]
    for name, samples in fam.items():
        lines.append(f"# TYPE {name} gauge")
        lines += samples
    lines.append("# TYPE share_link_geo_window_hours gauge")
    lines.append(f"share_link_geo_window_hours {WINDOW_HOURS}")
    lines.append("# TYPE share_link_geo_last_success_timestamp gauge")
    lines.append(f"share_link_geo_last_success_timestamp {int(time.time())}")
    payload = "\n".join(lines) + "\n"

    req = urllib.request.Request(
        f"{PUSHGATEWAY_URL}/metrics/job/share-link-geo",
        data=payload.encode(),
        method="PUT",
        headers={"Content-Type": "text/plain"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        resp.read()
    print(f"pushed {len(slugs)} slugs to pushgateway", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FATAL: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
