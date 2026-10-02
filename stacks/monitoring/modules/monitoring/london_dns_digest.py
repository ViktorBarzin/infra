#!/usr/bin/env python3
"""Daily London DNS digest -> Slack #alerts.

Once a day, reads the London Flint's dnsmasq query log from Loki
({job="syslog", host="flint-london"}, --log-queries=extra lines) and posts what
a person may need to act on:

  * DNS errors: lookups answered SERVFAIL or REFUSED, per device and name, and
    how often dnsmasq hit its concurrent-query limit.
  * Newly blocked by AdGuard: names answered 0.0.0.0 / :: in the last 24 h that
    were not blocked in the 30 days before. Empty for the first 7 days after
    LOG_START, while there is no history to compare against.
  * Blocked by GL content protection: names dnsmasq added to the GL_DPI_BLOCK
    ipset with a real address.

Nothing is posted when every section is empty. Client addresses become device
names through the probe's {job="london-neigh"} snapshots (neighbour tables and
DHCP leases), because most lookups arrive from rotating IPv6 privacy addresses.

Design: infra docs/plans/2026-10-02-london-dns-block-monitoring.md. Same shape
as proxy_visit_digest.py: pure builders + thin Loki/Slack I/O, pure stdlib.

Env (all have in-cluster defaults):
  LOKI_URL           default http://loki.monitoring.svc.cluster.local:3100
  LOG_START          when the query log was turned on (ISO 8601 UTC)
  SLACK_WEBHOOK_URL  Slack incoming-webhook URL. Empty (or DRY_RUN) -> print.
  SLACK_CHANNEL      default "#alerts"
  DRY_RUN            if set, print instead of posting.
"""
import datetime
import json
import os
import re
import sys
import urllib.parse
import urllib.request

LOKI_URL = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100").rstrip("/")
LOG_START = os.environ.get("LOG_START", "2026-10-02T16:10:00Z")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "").strip()
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#alerts")
DRY_RUN = bool(os.environ.get("DRY_RUN", "")) or not SLACK_WEBHOOK_URL

LEARNING_DAYS = 7
HISTORY_DAYS = 30
MAX_PER_DEVICE = 10
MAX_DEVICES = 15
MAX_ERROR_LOOKUPS = 50

FLINT = '{job="syslog", host="flint-london"}'
# LogQL: blocked answers per (client, name). dnsmasq logs "reply" for an
# upstream answer and "cached" for one served from its cache.
BLOCKS_24H = (
    'sum by (client, domain) (count_over_time(' + FLINT +
    ' |~ " (reply|cached) [^ ]+ is (0\\\\.0\\\\.0\\\\.0|::)$"'
    ' | regexp "^[0-9]+ (?P<client>[^/ ]+)/[0-9]+ (reply|cached) (?P<domain>[^ ]+) is " [24h]))'
)
BLOCKED_DOMAINS_24H = (
    'sum by (domain) (count_over_time(' + FLINT +
    ' |~ " (reply|cached) [^ ]+ is (0\\\\.0\\\\.0\\\\.0|::)$"'
    ' | regexp "^[0-9]+ [^ ]+ (reply|cached) (?P<domain>[^ ]+) is " [24h]))'
)
# A real address only: when AdGuard has already answered 0.0.0.0 the ipset
# gets 0.0.0.0 too, and that block is AdGuard's.
DPI_24H = (
    'sum by (client, domain) (count_over_time(' + FLINT +
    ' |= " ipset add GL_DPI_BLOCK " != " GL_DPI_BLOCK 0.0.0.0 " != " GL_DPI_BLOCK :: "'
    ' | regexp "^[0-9]+ (?P<client>[^/ ]+)/[0-9]+ ipset add GL_DPI_BLOCK [^ ]+ (?P<domain>[^ ]+)$" [24h]))'
)
OVERFLOW_24H = 'sum(count_over_time(' + FLINT + ' |= "Maximum number of concurrent DNS queries reached" [24h]))'
ERRORS_RAW = FLINT + ' |~ " reply error is (SERVFAIL|REFUSED)$"'
NEIGH_RAW = '{job="london-neigh"}'

_ERROR_RE = re.compile(r"^(\d+) ([^/ ]+)/(\d+) reply error is (SERVFAIL|REFUSED)$")
_QUERY_RE = re.compile(r"^(\d+) ([^/ ]+)/(\d+) query\[[A-Z0-9]+\] (\S+) from ")
_NEIGH_RE = re.compile(r"^(\S+) dev \S+ .*lladdr ([0-9a-f:]{17})")
_ROUTER = {"127.0.0.1", "::1"}


# --- pure seams ------------------------------------------------------------

def parse_error_line(line):
    """'<serial> <client>/<port> reply error is SERVFAIL' -> (serial, client, port, rcode)."""
    m = _ERROR_RE.match(line.strip())
    return m.groups() if m else None


def parse_query_line(line):
    """'<serial> <client>/<port> query[A] <name> from ...' -> (serial, client, port, name)."""
    m = _QUERY_RE.match(line.strip())
    return m.groups() if m else None


def error_query_regex(keys):
    """A LogQL/RE2 regex matching the query[] lines of the given (serial, client, port).

    dnsmasq logs an upstream error as 'reply error is SERVFAIL' without the
    name; the name is on the query line with the same serial and client/port.
    """
    alts = "|".join(re.escape("%s %s/%s" % k) for k in keys)
    return "^(%s) query\\[" % alts


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


def new_blocks(today, history):
    """{(client, domain): count} minus domains in `history` -> {client: [(domain, count)]}."""
    out = {}
    for (client, domain), count in today.items():
        if domain not in history:
            out.setdefault(client, []).append((domain, count))
    for client in out:
        out[client].sort(key=lambda dc: (-dc[1], dc[0]))
    return out


def in_learning(log_start, now):
    return now - log_start < datetime.timedelta(days=LEARNING_DAYS)


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


def build_digest(errors, overflow, blocks, dpi, learning, devices, date_label):
    """Pure: the day's findings -> Slack text, or None when there is nothing to report.

    errors:  [(client, name, rcode, count)]
    overflow: times dnsmasq hit its concurrent-query limit
    blocks:  {client: [(domain, count)]} newly blocked by AdGuard
    dpi:     {client: [(domain, count)]} added to GL_DPI_BLOCK
    learning: True during the first LEARNING_DAYS, which hides `blocks`
    """
    if learning:
        blocks = {}
    if not errors and not overflow and not blocks and not dpi:
        return None
    out = ["*London DNS, %s*" % date_label]
    if errors or overflow:
        out.append("*DNS errors*")
        merged = {}
        for client, name, rcode, count in errors:
            key = (device_name(client, devices), name, rcode)
            merged[key] = merged.get(key, 0) + count
        for (device, name, rcode), count in sorted(merged.items(), key=lambda kv: (-kv[1], kv[0])):
            out.append("• %s: %s %s x%d" % (device, name, rcode, count))
        if overflow:
            out.append("• dnsmasq hit its concurrent-query limit %d times" % overflow)
    if blocks:
        out.append("*Newly blocked by AdGuard* (not blocked in the previous %d days)" % HISTORY_DAYS)
        out.extend(_device_lines(blocks, devices))
        out.append(
            "_Unblock one name on the Flint: `uci add_list dhcp.@dnsmasq[0].server='/<domain>/94.140.14.140'"
            " && uci commit dhcp && /etc/init.d/dnsmasq restart`. Devices may keep the cached block for up to an hour._"
        )
    if dpi:
        out.append("*Blocked by GL content protection*")
        out.extend(_device_lines(dpi, devices))
        out.append("_Unblock through the content-protection allowlist in the GL admin UI._")
    return "\n".join(out)


# --- Loki / Slack I/O ------------------------------------------------------

def _get_json(path, params, timeout=120):
    url = "%s%s?%s" % (LOKI_URL, path, urllib.parse.urlencode(params))
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _instant(query, at):
    data = _get_json("/loki/api/v1/query", {"query": query, "time": str(int(at.timestamp() * 1e9))})
    return data.get("data", {}).get("result", [])


def _lines(query, start, end, limit=5000):
    data = _get_json("/loki/api/v1/query_range", {
        "query": query, "start": str(int(start.timestamp() * 1e9)),
        "end": str(int(end.timestamp() * 1e9)), "limit": str(limit), "direction": "forward",
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


def fetch_history(now, log_start):
    """Domains blocked in each 24 h window before the last one, back to LOG_START."""
    seen = set()
    for day in range(1, HISTORY_DAYS + 1):
        at = now - datetime.timedelta(days=day)
        if at <= log_start:
            break
        for r in _instant(BLOCKED_DOMAINS_24H, at):
            domain = r.get("metric", {}).get("domain")
            if domain:
                seen.add(domain)
    return seen


def fetch_errors(now):
    start = now - datetime.timedelta(hours=24)
    found = [e for e in (parse_error_line(l) for l in _lines(ERRORS_RAW, start, now)) if e]
    names = {}
    keys = sorted({(s, c, p) for s, c, p, _ in found})[:MAX_ERROR_LOOKUPS]
    if keys:
        query = FLINT + ' |~ "' + error_query_regex(keys).replace("\\", "\\\\") + '"'
        for line in _lines(query, start, now):
            q = parse_query_line(line)
            if q:
                names[q[:3]] = q[3]
    counts = {}
    for serial, client, port, rcode in found:
        name = names.get((serial, client, port), "(unknown name)")
        counts[(client, name, rcode)] = counts.get((client, name, rcode), 0) + 1
    return [(c, n, r, k) for (c, n, r), k in counts.items()]


def post_to_slack(text):
    if DRY_RUN:
        print("[DRY_RUN] would POST to Slack %s:\n%s" % (SLACK_CHANNEL, text))
        return
    body = json.dumps({"channel": SLACK_CHANNEL, "text": text}).encode("utf-8")
    req = urllib.request.Request(SLACK_WEBHOOK_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status >= 300:
            raise RuntimeError("Slack POST failed: HTTP %d" % resp.status)


def main():
    now = datetime.datetime.now(datetime.timezone.utc)
    log_start = datetime.datetime.fromisoformat(LOG_START.replace("Z", "+00:00"))
    learning = in_learning(log_start, now)
    try:
        errors = fetch_errors(now)
        overflow = sum(int(float(r["value"][1])) for r in _instant(OVERFLOW_24H, now))
        dpi = _per_client(_by_client(_instant(DPI_24H, now)))
        blocks = {}
        if not learning:
            blocks = new_blocks(_by_client(_instant(BLOCKS_24H, now)), fetch_history(now, log_start))
        devices = build_device_map(_lines(NEIGH_RAW, now - datetime.timedelta(hours=24), now, limit=500))
    except Exception as e:
        # Loki unreachable or a query failed: send nothing rather than a partial report.
        sys.stderr.write("london-dns-digest: Loki query failed (%s); sending nothing\n" % e)
        sys.exit(1)
    date_label = now.strftime("%a %d %b %Y")
    msg = build_digest(errors, overflow, blocks, dpi, learning, devices, date_label)
    if msg is None:
        sys.stderr.write("london-dns-digest: nothing to report (learning=%s)\n" % learning)
        return
    post_to_slack(msg)


if __name__ == "__main__":
    main()
