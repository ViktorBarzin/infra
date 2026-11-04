#!/usr/bin/env python3
"""Daily DNS digest for both sites -> Slack #alerts.

Once a day, checks the last 24 h of DNS lookups at both sites and posts what a
person may need to act on. Nothing is posted on a day with nothing to report.

  * Threat-feed matches: lookups (blocked or not) of a name on HaGeZi's Threat
    Intelligence Feeds list (malware, phishing, command-and-control). London's
    lookups come from the Flint's dnsmasq query log in Loki
    ({job="syslog", host="flint-london"}, --log-queries=extra lines); Sofia's
    from Technitium's Postgres query log (table dns_logs).
  * London DNS errors: SERVFAIL/REFUSED answers and dnsmasq's concurrent-query
    limit. Posted only when they point at a real problem: any "config error"
    (dnsmasq reached no upstream), the concurrent-query limit, or at least three
    different failing names. Lookups that DNS fingerprinting tools send on
    purpose (version.bind and friends, from Avast's daily network check) are
    left out.
  * Blocked by GL content protection: names London's dnsmasq added to the
    GL_DPI_BLOCK ipset with a real address.
  * Monitoring gaps: hours in which a query log recorded nothing, per Sofia
    instance and for London, so a log that stops does not look like a quiet day.

Every successful run pushes dns_digest_* metrics to the Pushgateway, so an
alert fires if the digest stops running or checks no names (see
prometheus_chart_values.tpl, "DNS digest").

London client addresses become device names through the probe's
{job="london-neigh"} snapshots; Sofia addresses through reverse DNS.

Env (all have in-cluster defaults except the database password):
  LOKI_URL           default http://loki.monitoring.svc.cluster.local:3100
  PUSHGATEWAY_URL    default http://prometheus-prometheus-pushgateway.monitoring:9091
  FEED_URL           HaGeZi TIF wildcard domains list
  PGHOST/PGUSER/PGDATABASE/PGPASSWORD  Technitium's query-log database (psql)
  SOFIA_INSTANCES    Technitium instances expected to log, comma-separated
  COVERAGE_START     ISO 8601 UTC; hours before it are not reported as gaps
  SLACK_WEBHOOK_URL  Slack incoming-webhook URL. Empty (or DRY_RUN) -> print.
  SLACK_CHANNEL      default "#alerts"
  DRY_RUN            if set, print instead of posting and do not push metrics.
"""
import csv
import datetime
import io
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

LOKI_URL = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100").rstrip("/")
PUSHGATEWAY_URL = os.environ.get(
    "PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091").rstrip("/")
FEED_URL = os.environ.get(
    "FEED_URL", "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt")
SOFIA_INSTANCES = [s for s in os.environ.get(
    "SOFIA_INSTANCES", "technitium,technitium-secondary,technitium-tertiary").split(",") if s]
COVERAGE_START = os.environ.get("COVERAGE_START", "").strip()
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "").strip()
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#alerts")
DRY_RUN = bool(os.environ.get("DRY_RUN", "")) or not SLACK_WEBHOOK_URL

MAX_PER_DEVICE = 10
MAX_DEVICES = 15
MAX_LINES = 15
MAX_ERROR_LOOKUPS = 50
MIN_DISTINCT_ERROR_NAMES = 3
FEED_MIN_SHARE = 0.95
FEED_MAX_AGE = datetime.timedelta(hours=72)
MIN_WINDOW_HOURS = 3

# Names DNS fingerprinting tools ask for on purpose (fpdns, nmap, Avast's daily
# network check). A REFUSED answer to them is the expected result.
FINGERPRINT_NAMES = frozenset({
    "version.bind", "hostname.bind", "authors.bind", "id.server", "version.server",
    "version.maradns", "version.mydns", "version.pdns", "erre-con-erre-cigarro.maradns.org",
})

FLINT = '{job="syslog", host="flint-london"}'
# LogQL backtick strings are raw: no escaping inside them.
LONDON_NAMES = (
    'sum by (domain) (count_over_time(' + FLINT +
    ' |~ `^[0-9]+ [^ ]+ query\\[[A-Z0-9]+\\] `'
    ' !~ ` query\\[[A-Z0-9]+\\] probe-[0-9]+\\.viktorbarzin\\.me `'
    ' | regexp `query\\[[A-Z0-9]+\\] (?P<domain>[^ ]+) from` [%dh]))'
)
LONDON_CLIENTS = (
    'sum by (client, domain) (count_over_time(' + FLINT +
    ' |~ `query\\[[A-Z0-9]+\\] (%s) from`'
    ' | regexp `^[0-9]+ (?P<client>[^/ ]+)/[0-9]+ query\\[[A-Z0-9]+\\] (?P<domain>[^ ]+) from` [24h]))'
)
LONDON_BLOCKED = (
    'sum by (domain) (count_over_time(' + FLINT +
    ' |~ ` (reply|cached) (%s) is (0\\.0\\.0\\.0|::)$`'
    ' | regexp ` (reply|cached) (?P<domain>[^ ]+) is ` [24h]))'
)
LONDON_HOURLY = 'sum(count_over_time(' + FLINT + ' |~ ` query\\[` [1h]))'
# A real address only: when AdGuard has already answered 0.0.0.0 the ipset
# gets 0.0.0.0 too, and that block is AdGuard's.
DPI_24H = (
    'sum by (client, domain) (count_over_time(' + FLINT +
    ' |= " ipset add GL_DPI_BLOCK " != " GL_DPI_BLOCK 0.0.0.0 " != " GL_DPI_BLOCK :: "'
    ' | regexp "^[0-9]+ (?P<client>[^/ ]+)/[0-9]+ ipset add GL_DPI_BLOCK [^ ]+ (?P<domain>[^ ]+)$" [24h]))'
)
OVERFLOW_24H = 'sum(count_over_time(' + FLINT + ' |= "Maximum number of concurrent DNS queries reached" [24h]))'
ERRORS_RAW = FLINT + ' |~ ` (reply|config) error is (SERVFAIL|REFUSED)`'
NEIGH_RAW = '{job="london-neigh"}'

# Technitium response types 4-6: Blocked, UpstreamBlocked, UpstreamBlockedCached.
SOFIA_LOOKUPS = (
    "COPY (SELECT client_ip, qname, count(*), bool_or(response_type IN (4, 5, 6)) FROM dns_logs"
    " WHERE timestamp > now() - interval '24 hours' GROUP BY 1, 2) TO STDOUT WITH CSV"
)
SOFIA_COVERAGE = (
    "COPY (SELECT server, date_trunc('hour', timestamp), count(*) FROM dns_logs"
    " WHERE timestamp >= '%s' GROUP BY 1, 2) TO STDOUT WITH CSV"
)

_ERROR_RE = re.compile(r"^(\d+) ([^/ ]+)/(\d+) (reply|config) error is (SERVFAIL|REFUSED)\b")
_QUERY_RE = re.compile(r"^(\d+) ([^/ ]+)/(\d+) query\[[A-Z0-9]+\] (\S+) from ")
_NEIGH_RE = re.compile(r"^(\S+) dev \S+ .*lladdr ([0-9a-f:]{17})")
_POD_SUFFIX_RE = re.compile(r"-[a-z0-9]{6,10}-[a-z0-9]{5}$")
_ROUTER = {"127.0.0.1", "::1"}


class FeedError(Exception):
    """The threat feed is missing, truncated or stale."""


class Feed:
    def __init__(self, domains, header_count, modified):
        self.domains = domains
        self.header_count = header_count
        self.modified = modified


# --- pure seams: dnsmasq lines ---------------------------------------------

def parse_error_line(line):
    """'<serial> <client>/<port> (reply|config) error is RCODE ...' -> (serial, client, port, rcode, kind).

    kind "config" is dnsmasq answering itself because no upstream answered,
    logged as 'config error is REFUSED (EDE: network error)'.
    """
    m = _ERROR_RE.match(line.strip())
    if not m:
        return None
    serial, client, port, kind, rcode = m.groups()
    return serial, client, port, rcode, kind


def parse_query_line(line):
    """'<serial> <client>/<port> query[A] <name> from ...' -> (serial, client, port, name)."""
    m = _QUERY_RE.match(line.strip())
    return m.groups() if m else None


def error_query_regex(keys):
    """A regex matching the query[] lines of the given (serial, client, port).

    dnsmasq logs an error without the name; the name is on the query line with
    the same serial and client/port.
    """
    alts = "|".join(re.escape("%s %s/%s" % k) for k in keys)
    return "^(%s) query\\[" % alts


def logql_alternation(names):
    """Names -> 'a\\.example|b\\.example' for a LogQL backtick regex."""
    return "|".join(re.escape(n) for n in sorted(set(names)))


def is_fingerprint(name):
    return name.lower().rstrip(".") in FINGERPRINT_NAMES


def errors_worth_posting(errors, overflow):
    """[(client, name, rcode, kind, count)] -> the errors to post, or [] for a normal day.

    One or two names failing upstream (a broken record somewhere on the
    internet) happens most days and nobody here can fix it. A post is due when
    dnsmasq reached no upstream (kind "config"), hit its concurrent-query
    limit, or at least three different names failed.
    """
    real = [e for e in errors if not is_fingerprint(e[1])]
    if overflow or any(e[3] == "config" for e in real) or len({e[1] for e in real}) >= MIN_DISTINCT_ERROR_NAMES:
        return real
    return []


# --- pure seams: devices ---------------------------------------------------

def build_device_map(snapshots):
    """london-neigh JSON lines (oldest first) -> {address: device name}.

    Each address maps to the MAC the neighbour tables last saw it on, and the
    MAC to its DHCP hostname when the lease has one. Later snapshots win.
    """
    ip_mac, mac_host = {}, {}
    for raw in snapshots:
        try:
            snap = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if not isinstance(snap, dict):
            continue
        for line in (snap.get("leases") or "").splitlines():
            parts = line.split()
            if len(parts) >= 4:
                mac, ip, host = parts[1].lower(), parts[2], parts[3]
                ip_mac[ip] = mac
                if host != "*":
                    mac_host[mac] = host
        for key in ("neigh4", "neigh6"):
            for line in (snap.get(key) or "").splitlines():
                m = _NEIGH_RE.match(line.strip())
                if m:
                    ip_mac[m.group(1)] = m.group(2).lower()
    return {ip: mac_host.get(mac, mac) for ip, mac in ip_mac.items()}


def device_name(addr, devices):
    if addr in _ROUTER:
        return "the Flint"
    return devices.get(addr, addr)


# --- pure seams: threat feed -----------------------------------------------

def parse_feed(lines):
    """HaGeZi wildcard-domains lines -> Feed (entries lowercased, header count and date)."""
    domains, count, modified = set(), None, None
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            if line.startswith("# Number of entries:"):
                try:
                    count = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
            elif line.startswith("# Last modified:"):
                try:
                    modified = datetime.datetime.strptime(
                        line.split(":", 1)[1].strip(), "%d %b %Y %H:%M UTC"
                    ).replace(tzinfo=datetime.timezone.utc)
                except ValueError:
                    pass
            continue
        domains.add(line.lower().rstrip("."))
    return Feed(domains, count, modified)


def check_feed(feed, now):
    """Raise FeedError unless the feed is complete and recent."""
    if feed.header_count is None or feed.modified is None:
        raise FeedError("feed has no 'Number of entries' / 'Last modified' header")
    if len(feed.domains) < FEED_MIN_SHARE * feed.header_count:
        raise FeedError("feed has %d of %d entries" % (len(feed.domains), feed.header_count))
    age = now - feed.modified
    if age > FEED_MAX_AGE:
        raise FeedError("feed is %dh old" % (age.total_seconds() // 3600))


def feed_match(name, domains):
    """The feed entry that covers `name` (itself or a parent domain), or None."""
    labels = name.lower().rstrip(".").split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        if candidate in domains:
            return candidate
    return None


def find_threats(rows, domains):
    """[(site, client, name, count, blocked)] -> [(site, client, name, entry, count, blocked)] on the feed."""
    out = []
    for site, client, name, count, blocked in rows:
        entry = feed_match(name, domains)
        if entry:
            out.append((site, client, name, entry, count, blocked))
    return sorted(out)


# --- pure seams: Sofia query log -------------------------------------------

def parse_sofia_lookups(csv_text):
    """psql CSV 'client_ip,qname,count,blocked' -> [("Sofia", client, name, count, blocked)]."""
    rows = []
    for rec in csv.reader(io.StringIO(csv_text)):
        if len(rec) != 4 or not rec[1]:
            continue
        rows.append(("Sofia", rec[0], rec[1], int(rec[2]), rec[3] == "t"))
    return rows


def instance_of(server):
    """Technitium's server name is the pod name at first start: drop the pod suffix."""
    return _POD_SUFFIX_RE.sub("", server)


def _parse_hour(text):
    return datetime.datetime.strptime(text[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)


def parse_sofia_coverage(csv_text):
    """psql CSV 'server,hour,count' (UTC) -> {instance: {hour: count}}."""
    out = {}
    for rec in csv.reader(io.StringIO(csv_text)):
        if len(rec) != 3:
            continue
        inst, hour = instance_of(rec[0]), _parse_hour(rec[1])
        out.setdefault(inst, {})
        out[inst][hour] = out[inst].get(hour, 0) + int(rec[2])
    return out


def coverage_gaps(counts, expected, hours, since=None):
    """{instance: {hour: count}} -> {instance: [hours with no rows]} for each expected instance."""
    out = {}
    for inst in expected:
        missing = [h for h in hours if (since is None or h >= since) and not counts.get(inst, {}).get(h)]
        if missing:
            out[inst] = missing
    return out


def last_full_hours(now, n=24):
    top = now.replace(minute=0, second=0, microsecond=0)
    return [top - datetime.timedelta(hours=k) for k in range(n, 0, -1)]


# --- pure seams: the message -----------------------------------------------

def _capped(lines, cap=MAX_LINES):
    if len(lines) <= cap:
        return lines
    return lines[:cap] + ["• +%d more" % (len(lines) - cap)]


def _device_lines(per_client, devices):
    """{client: [(domain, count)]} -> bullet lines, merged per device name."""
    merged = {}
    for client, items in per_client.items():
        name = device_name(client, devices)
        for domain, count in items:
            merged.setdefault(name, {})
            merged[name][domain] = merged[name].get(domain, 0) + count
    lines = []
    names = sorted(merged, key=lambda n: (-sum(merged[n].values()), n))
    for name in names[:MAX_DEVICES]:
        items = sorted(merged[name].items(), key=lambda dc: (-dc[1], dc[0]))
        shown = ", ".join("%s x%d" % dc for dc in items[:MAX_PER_DEVICE])
        more = len(items) - MAX_PER_DEVICE
        lines.append("• %s: %s%s" % (name, shown, " (+%d more)" % more if more > 0 else ""))
    if len(names) > MAX_DEVICES:
        lines.append("• +%d more devices" % (len(names) - MAX_DEVICES))
    return lines


def _hours_label(hours):
    if len(hours) >= 24:
        return "any of the last 24 hours"
    shown = ", ".join(h.strftime("%H:%M") for h in hours[:6])
    if len(hours) > 6:
        shown += ", +%d more" % (len(hours) - 6)
    return "%d of the last 24 hours (%s UTC)" % (len(hours), shown)


def build_digest(errors, overflow, dpi, threats, gaps, devices, date_label):
    """Pure: the day's findings -> Slack text, or None when there is nothing to report.

    errors:  [(client, name, rcode, kind, count)], already filtered by errors_worth_posting
    overflow: times London's dnsmasq hit its concurrent-query limit
    dpi:     {client: [(domain, count)]} added to GL_DPI_BLOCK
    threats: [(site, client, name, entry, count, blocked)]
    gaps:    [(log label, instance or None, [hours])]
    devices: {address: name} for both sites
    """
    if not errors and not overflow and not dpi and not threats and not gaps:
        return None
    out = ["*DNS digest, %s*" % date_label]
    if threats:
        out.append("*Threat-feed matches* (HaGeZi Threat Intelligence Feeds: malware, phishing, C2)")
        merged = {}
        for site, client, name, entry, count, blocked in threats:
            key = (site, device_name(client, devices), name, entry)
            prev = merged.get(key, (0, True))
            merged[key] = (prev[0] + count, prev[1] and blocked)
        lines = []
        for (site, device, name, entry), (count, blocked) in sorted(merged.items()):
            note = "" if entry == name.lower().rstrip(".") else " (feed entry %s)" % entry
            lines.append("• %s, %s: %s x%d%s, %s" % (
                site, device, name, count, note, "blocked" if blocked else "not blocked"))
        out.extend(_capped(lines))
    if errors or overflow:
        out.append("*London DNS errors*")
        merged = {}
        for client, name, rcode, kind, count in errors:
            label = rcode + (" (no upstream answered)" if kind == "config" else "")
            key = (device_name(client, devices), name, label)
            merged[key] = merged.get(key, 0) + count
        lines = ["• %s: %s %s x%d" % (device, name, label, count)
                 for (device, name, label), count in sorted(merged.items(), key=lambda kv: (-kv[1], kv[0]))]
        out.extend(_capped(lines))
        if overflow:
            out.append("• dnsmasq hit its concurrent-query limit %d times" % overflow)
    if dpi:
        out.append("*Blocked by GL content protection* (London)")
        out.extend(_device_lines(dpi, devices))
        out.append("_Unblock through the content-protection allowlist in the GL admin UI._")
    if gaps:
        out.append("*Monitoring gaps*")
        for label, inst, hours in gaps:
            if inst:
                out.append("• %s: %s logged nothing in %s" % (label, inst, _hours_label(hours)))
            else:
                out.append("• %s: nothing in %s" % (label, _hours_label(hours)))
    return "\n".join(out)


def metrics_text(names_checked, feed_entries, matches, now):
    """Pushgateway exposition text for one successful run."""
    lines = [
        "# HELP dns_digest_last_success Unix time of the last successful DNS digest run",
        "# TYPE dns_digest_last_success gauge",
        "dns_digest_last_success %d" % int(now.timestamp()),
        "# HELP dns_digest_names_checked Distinct names checked against the threat feed in the last 24 h",
        "# TYPE dns_digest_names_checked gauge",
    ]
    for site in sorted(names_checked):
        lines.append('dns_digest_names_checked{site="%s"} %d' % (site, names_checked[site]))
    lines += [
        "# HELP dns_digest_feed_entries Entries in the threat feed the digest used",
        "# TYPE dns_digest_feed_entries gauge",
        "dns_digest_feed_entries %d" % feed_entries,
        "# HELP dns_digest_threat_matches Lookups of threat-feed names in the last 24 h",
        "# TYPE dns_digest_threat_matches gauge",
        "dns_digest_threat_matches %d" % matches,
    ]
    return "\n".join(lines) + "\n"


# --- I/O: feed, Loki, Postgres, Slack, Pushgateway -------------------------

def fetch_feed():
    req = urllib.request.Request(FEED_URL, headers={"User-Agent": "homelab-dns-digest"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return parse_feed(line.decode("utf-8", "replace") for line in resp)


def _get_json(path, params, timeout=300):
    url = "%s%s?%s" % (LOKI_URL, path, urllib.parse.urlencode(params))
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _ns(at):
    return str(int(at.timestamp() * 1e9))


def _instant(query, at):
    return _get_json("/loki/api/v1/query", {"query": query, "time": _ns(at)}).get("data", {}).get("result", [])


def _lines(query, start, end, limit=5000):
    data = _get_json("/loki/api/v1/query_range", {
        "query": query, "start": _ns(start), "end": _ns(end), "limit": str(limit), "direction": "forward",
    })
    rows = []
    for stream in data.get("data", {}).get("result", []):
        rows.extend(stream.get("values", []))
    rows.sort(key=lambda r: r[0])
    return [line for _ts, line in rows]


def _by_client(result):
    out = {}
    for r in result:
        metric = r.get("metric", {})
        client, domain = metric.get("client"), metric.get("domain")
        if client and domain:
            out[(client, domain)] = out.get((client, domain), 0) + int(float(r["value"][1]))
    return out


def _per_client(counts):
    out = {}
    for (client, domain), count in counts.items():
        out.setdefault(client, []).append((domain, count))
    return out


def london_names(at, hours=24):
    """{name: lookups} for the `hours` before `at`. Splits the window when Loki's series cap is hit."""
    try:
        result = _instant(LONDON_NAMES % hours, at)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        if "maximum number of series" not in body or hours <= MIN_WINDOW_HOURS:
            raise
        half = hours // 2
        out = london_names(at, half)
        for name, count in london_names(at - datetime.timedelta(hours=half), hours - half).items():
            out[name] = out.get(name, 0) + count
        return out
    out = {}
    for r in result:
        name = r.get("metric", {}).get("domain")
        if name:
            out[name] = out.get(name, 0) + int(float(r["value"][1]))
    return out


def london_rows(names, now):
    """Names already known to match -> [("London", client, name, count, blocked)]."""
    if not names:
        return []
    alt = logql_alternation(names)
    blocked = {r["metric"].get("domain") for r in _instant(LONDON_BLOCKED % alt, now)}
    rows = [("London", client, name, count, name in blocked)
            for (client, name), count in _by_client(_instant(LONDON_CLIENTS % alt, now)).items()]
    seen = {r[2] for r in rows}
    rows += [("London", "unknown device", n, 1, n in blocked) for n in names if n not in seen]
    return rows


def london_gaps(now, hours):
    """Hours in which Loki holds no London lookups."""
    data = _get_json("/loki/api/v1/query_range", {
        "query": LONDON_HOURLY,
        "start": _ns(hours[0] + datetime.timedelta(hours=1)),
        "end": _ns(hours[-1] + datetime.timedelta(hours=1)),
        "step": "3600",
    })
    seen = {}
    for series in data.get("data", {}).get("result", []):
        for ts, value in series.get("values", []):
            hour = datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc) - datetime.timedelta(hours=1)
            seen[hour.replace(minute=0, second=0, microsecond=0)] = int(float(value))
    return [h for h in hours if not seen.get(h)]


def fetch_errors(now):
    start = now - datetime.timedelta(hours=24)
    found = [e for e in (parse_error_line(l) for l in _lines(ERRORS_RAW, start, now)) if e]
    names = {}
    keys = sorted({(s, c, p) for s, c, p, _r, _k in found})[:MAX_ERROR_LOOKUPS]
    if keys:
        query = FLINT + " |~ `" + error_query_regex(keys) + "`"
        for line in _lines(query, start, now):
            q = parse_query_line(line)
            if q:
                names[q[:3]] = q[3]
    counts = {}
    for serial, client, port, rcode, kind in found:
        name = names.get((serial, client, port), "(unknown name)")
        counts[(client, name, rcode, kind)] = counts.get((client, name, rcode, kind), 0) + 1
    return [(c, n, r, k, cnt) for (c, n, r, k), cnt in counts.items()]


def psql_copy(statement):
    """Run one COPY ... TO STDOUT through psql (PG* env) in UTC; return the CSV text."""
    proc = subprocess.run(
        ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", "SET TIME ZONE 'UTC'", "-c", statement],
        capture_output=True, text=True, timeout=300, env=dict(os.environ, PGCONNECT_TIMEOUT="30"),
    )
    if proc.returncode != 0:
        raise RuntimeError("psql failed: %s" % proc.stderr.strip()[:500])
    return proc.stdout


def reverse_names(addresses):
    """{address: 'host (address)'} through reverse DNS, for addresses that have a PTR record."""
    out = {}
    for addr in addresses:
        try:
            host = socket.gethostbyaddr(addr)[0]
        except (OSError, UnicodeError):
            continue
        out[addr] = "%s (%s)" % (host.split(".")[0], addr)
    return out


def post_to_slack(text):
    if DRY_RUN:
        print("[DRY_RUN] would POST to Slack %s:\n%s" % (SLACK_CHANNEL, text))
        return
    body = json.dumps({"channel": SLACK_CHANNEL, "text": text}).encode("utf-8")
    req = urllib.request.Request(SLACK_WEBHOOK_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError("Slack POST failed: HTTP %d" % resp.status)


def push_metrics(text):
    if DRY_RUN:
        print("[DRY_RUN] would PUT to Pushgateway:\n%s" % text)
        return
    req = urllib.request.Request("%s/metrics/job/dns-digest" % PUSHGATEWAY_URL, data=text.encode("utf-8"),
                                 method="PUT", headers={"Content-Type": "text/plain; version=0.0.4"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError("Pushgateway PUT failed: HTTP %d" % resp.status)


def main():
    now = datetime.datetime.now(datetime.timezone.utc)
    hours = last_full_hours(now)
    since = None
    if COVERAGE_START:
        since = datetime.datetime.fromisoformat(COVERAGE_START.replace("Z", "+00:00"))
    try:
        feed = fetch_feed()
        check_feed(feed, now)

        names = london_names(now)
        london_hits = [n for n in names if feed_match(n, feed.domains)]
        sofia = parse_sofia_lookups(psql_copy(SOFIA_LOOKUPS))
        threats = find_threats(london_rows(london_hits, now) + sofia, feed.domains)

        overflow = sum(int(float(r["value"][1])) for r in _instant(OVERFLOW_24H, now))
        errors = errors_worth_posting(fetch_errors(now), overflow)
        dpi = _per_client(_by_client(_instant(DPI_24H, now)))

        gaps = []
        sofia_cov = parse_sofia_coverage(psql_copy(SOFIA_COVERAGE % hours[0].strftime("%Y-%m-%d %H:%M:%S+00")))
        for inst, missing in sorted(coverage_gaps(sofia_cov, SOFIA_INSTANCES, hours, since).items()):
            gaps.append(("Sofia query log", inst, missing))
        london_missing = [h for h in london_gaps(now, hours) if since is None or h >= since]
        if london_missing:
            gaps.append(("London query log", None, london_missing))

        devices = build_device_map(_lines(NEIGH_RAW, now - datetime.timedelta(hours=24), now, limit=500))
        devices.update(reverse_names({t[1] for t in threats if t[0] == "Sofia"}))
    except (FeedError, RuntimeError, OSError, ValueError, KeyError) as e:
        # Feed, Loki or Postgres unavailable or wrong: send nothing rather than a
        # partial report, and push no success metric, so DNSDigestStale fires.
        sys.stderr.write("dns-digest: %s: %s; sending nothing\n" % (type(e).__name__, e))
        sys.exit(1)

    msg = build_digest(errors, overflow, dpi, threats, gaps, devices, now.strftime("%a %d %b %Y"))
    if msg is None:
        sys.stderr.write("dns-digest: nothing to report\n")
    else:
        post_to_slack(msg)
    sofia_names = len({r[2] for r in sofia})
    push_metrics(metrics_text({"London": len(names), "Sofia": sofia_names},
                              len(feed.domains), sum(t[4] for t in threats), now))


if __name__ == "__main__":
    main()
