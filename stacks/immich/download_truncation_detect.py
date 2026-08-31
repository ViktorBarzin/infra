#!/usr/bin/env python3
"""Measure whether Immich original-asset downloads actually finish.

Traefik logs a 200 and then writes however many bytes it manages before the
connection goes away, so a truncated download is indistinguishable from a
healthy one by status code alone. The only reliable test is to compare the
bytes Traefik logged against the asset's true size in Postgres, which is the
join this does.

It reports two different things, and the distinction is the whole point:

  cut          a single response that carried fewer bytes than the file holds.
               Expected at some rate on mobile clients, and NOT itself a
               problem: HTTP range requests exist for exactly this, and a
               client that resumes ends up with the whole file.

  unrecovered  an asset where the best single response fell short AND the
               range requests in the window do not cover the remainder. This
               is the user-visible failure — someone is left holding a partial
               JPEG, which renders as a correct image on top and flat grey
               below the cut.

Alerting on `cut` would page for someone riding a train. `unrecovered` is the
one worth waking up for.

Approximation worth knowing about: recovery is judged per asset within the
query window, not per client session. A resume that lands after the window
closes reads as unrecovered once and then clears. Erring that way is
deliberate — the opposite error hides real breakage.

Stdlib only, by house rule: no pip install at runtime.
"""

import collections
import json
import os
import re
import sys
import urllib.parse
import urllib.request

# One Traefik CLF access-log line for a GET of an original asset. The asset id
# is taken from a FIXED position in the request line rather than by searching
# the whole line, because User-Agent and Referer are attacker-controlled and a
# loose pattern would let a visitor choose which asset a metric is filed under.
LINE = re.compile(
    r'^(?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] '
    r'"GET /api/assets/(?P<aid>[0-9a-f-]{36})/original\S* HTTP/[\d.]+" '
    r'(?P<status>\d{3}) (?P<bytes>\d+) "[^"]*" "(?P<ua>[^"]*)"'
)

# Traffic from inside the cluster/LAN is diagnostics, probes and this repo's own
# tooling, never a person whose download we care about. It must be excluded, not
# merely ignored: a full-size fetch from here would otherwise mark somebody
# else's partial download as recovered. That happened live on 2026-08-31 — a
# curl from the devvm cleared a genuinely-truncated asset.
INTERNAL = re.compile(r'^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')


def parse_lines(lines):
    """Traefik access-log lines -> [(ip, asset_id, status, bytes)]."""
    out = []
    for line in lines:
        m = LINE.match(line)
        if m:
            if INTERNAL.match(m.group("ip")):
                continue
            out.append((
                m.group("ip"),
                m.group("aid"),
                int(m.group("status")),
                int(m.group("bytes")),
                m.group("ua"),
            ))
    return out


def analyse(records, sizes):
    """Fold parsed records into per-(asset, client) outcomes.

    records: [(ip, asset_id, status, bytes, user_agent)]
    sizes:   {asset_id: true_size_bytes}

    KEYED ON CLIENT, NOT JUST ASSET. Aggregating per asset alone is wrong:
    one person's successful download silently marks a different person's
    truncated copy as recovered. Observed live on 2026-08-31, when a diagnostic
    curl from the devvm cleared an asset that was genuinely still partial on a
    phone.

    The client key is the USER-AGENT, not the IP. A mobile client legitimately
    resumes from a different address than it started on — the same phone was
    seen starting on 185.139.138.221 and resuming from 92.63.205.141 — so
    keying on IP would report those recoveries as failures. The user-agent is
    stable across that address change while still separating genuinely
    different clients.

    Residual limit, accepted: two different people running byte-identical
    user-agent strings still merge into one client. That errs toward
    under-reporting for a shared photo library, which is the safer direction
    than the alternative of alerting on every mobile client that resumes.

    An asset with no known size is skipped rather than guessed at.
    """
    best_200 = collections.defaultdict(int)   # (asset, client) -> largest 200
    ranged = collections.defaultdict(int)     # (asset, client) -> total 206 bytes
    seen = set()
    clients = collections.Counter()
    ip_of = {}

    for ip, aid, status, nbytes, ua in records:
        if aid not in sizes:
            continue
        key = (aid, ua)
        seen.add(key)
        ip_of.setdefault(key, ip)
        if status == 200:
            best_200[key] = max(best_200[key], nbytes)
        elif status == 206:
            ranged[key] += nbytes

    cut, unrecovered, complete = [], [], []
    for key in seen:
        aid, _ua = key
        size = sizes[aid]
        best = best_200.get(key, 0)
        if best == size:
            complete.append(aid)
            continue
        if best == 0:
            # No full-body attempt by this client in the window, so there is
            # nothing to have been cut short. Range-only traffic is ordinary:
            # video seeking works this way, and so does a resume whose original
            # response fell outside the window. Counting either as truncation
            # would make the metric fire on healthy playback.
            continue
        cut.append(aid)
        # The remainder after this client's best full-body attempt. If ITS OWN
        # range requests cover at least that much, it got the file.
        if ranged.get(key, 0) < size - best:
            unrecovered.append(aid)
            clients[ip_of[key]] += 1

    return {
        "assets": len({a for a, _ in seen}),
        "complete": len(set(complete)),
        "cut": len(set(cut)),
        "unrecovered": len(set(unrecovered)),
        "unrecovered_assets": sorted(set(unrecovered)),
        "worst_client": clients.most_common(1)[0][0] if clients else "",
    }


def query_loki(base, query, since):
    url = base.rstrip("/") + "/loki/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": query, "since": since, "limit": "5000", "direction": "backward"}
    )
    with urllib.request.urlopen(url, timeout=60) as resp:
        payload = json.load(resp)
    lines = []
    for stream in payload.get("data", {}).get("result", []):
        for _ts, line in stream.get("values", []):
            lines.append(line)
    return lines


def load_sizes(path):
    sizes = {}
    with open(path) as fh:
        for row in fh:
            aid, _, size = row.strip().partition("|")
            if aid and size.isdigit():
                sizes[aid] = int(size)
    return sizes


def render(result, ok):
    g = []
    def add(name, help_, value):
        g.append(f"# HELP {name} {help_}")
        g.append(f"# TYPE {name} gauge")
        g.append(f"{name} {value}")

    add("immich_original_downloads_assets",
        "Distinct assets downloaded in the window.", result["assets"])
    add("immich_original_downloads_complete",
        "Assets whose download finished in a single response.", result["complete"])
    add("immich_original_downloads_cut",
        "Assets where at least one response carried fewer bytes than the file.",
        result["cut"])
    add("immich_original_downloads_unrecovered",
        "Assets left partial: short response, and range requests did not cover "
        "the remainder. This is the user-visible failure.",
        result["unrecovered"])
    add("immich_download_truncation_probe_success",
        "1 when this probe completed its own run.", 1 if ok else 0)
    return "\n".join(g) + "\n"


def main():
    loki = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
    since = os.environ.get("WINDOW", "1h")
    sizes_path = os.environ.get("SIZES_FILE", "/work/sizes.csv")
    out_path = os.environ.get("OUT_FILE", "/work/metrics.prom")
    query = os.environ.get(
        "LOKI_QUERY", '{namespace="traefik"} |= "/api/assets" |= "/original"'
    )

    try:
        sizes = load_sizes(sizes_path)
        if not sizes:
            raise RuntimeError(f"no asset sizes loaded from {sizes_path}")
        records = parse_lines(query_loki(loki, query, since))
        result = analyse(records, sizes)
        ok = True
    except Exception as exc:  # noqa: BLE001 - probe must publish its own failure
        print(f"probe failed: {exc}", file=sys.stderr)
        result = {"assets": 0, "complete": 0, "cut": 0, "unrecovered": 0,
                  "unrecovered_assets": [], "worst_client": ""}
        ok = False

    with open(out_path, "w") as fh:
        fh.write(render(result, ok))

    print(json.dumps({k: v for k, v in result.items()
                      if k != "unrecovered_assets"}, sort_keys=True))
    if result["unrecovered_assets"]:
        print("unrecovered assets: " + ", ".join(result["unrecovered_assets"][:20]),
              file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
