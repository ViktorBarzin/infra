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
    r'(?P<status>\d{3}) (?P<bytes>\d+) '
)


def parse_lines(lines):
    """Traefik access-log lines -> [(ip, asset_id, status, bytes)]."""
    out = []
    for line in lines:
        m = LINE.match(line)
        if m:
            out.append((
                m.group("ip"),
                m.group("aid"),
                int(m.group("status")),
                int(m.group("bytes")),
            ))
    return out


def analyse(records, sizes):
    """Fold parsed records into per-asset outcomes.

    records: [(ip, asset_id, status, bytes)]
    sizes:   {asset_id: true_size_bytes}

    An asset with no known size is skipped rather than guessed at.
    """
    best_200 = collections.defaultdict(int)   # asset -> largest full-body response
    ranged = collections.defaultdict(int)     # asset -> total bytes served as 206
    seen = set()
    clients = collections.Counter()

    for ip, aid, status, nbytes in records:
        if aid not in sizes:
            continue
        seen.add(aid)
        if status == 200:
            best_200[aid] = max(best_200[aid], nbytes)
        elif status == 206:
            ranged[aid] += nbytes

    cut, unrecovered, complete = [], [], []
    for aid in seen:
        size = sizes[aid]
        best = best_200.get(aid, 0)
        if best == size:
            complete.append(aid)
            continue
        if best == 0:
            # No full-body attempt in the window, so there is nothing to have
            # been cut short. Range-only traffic is ordinary: video seeking
            # works this way, and so does a resume whose original response
            # fell outside the window. Counting either as truncation would
            # make the metric fire on healthy playback.
            continue
        cut.append(aid)
        # The remainder after the best full-body attempt. If the range requests
        # in this window cover at least that much, the client got the file.
        if ranged.get(aid, 0) < size - best:
            unrecovered.append(aid)

    for ip, aid, status, nbytes in records:
        if aid in unrecovered and status == 200:
            clients[ip] += 1

    return {
        "assets": len(seen),
        "complete": len(complete),
        "cut": len(cut),
        "unrecovered": len(unrecovered),
        "unrecovered_assets": sorted(unrecovered),
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
