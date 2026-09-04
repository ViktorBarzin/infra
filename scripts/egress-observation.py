#!/usr/bin/env python3
"""Read the banked Calico egress observation data into a per-namespace external
destination map.

Background
----------
The `wave1-egress-observe-tier34` GlobalNetworkPolicy (stacks/calico/main.tf)
runs `[action: Log, action: Allow]` over every tier 3-edge / 4-aux namespace.
The Log action emits one iptables LOG line per packet; journald picks it up and
Alloy ships it to Loki as `{job="node-journal"} |~ "calico-packet"`. It has run
since 2026-05-19 and banks roughly 1.1M lines a day.

The line carries a pod IP, not a namespace:

    calico-packet: IN=cali.. OUT=eth0 MAC=.. SRC=10.10.195.217 DST=176.213.154.23
    LEN=93 TOS=0x04 PREC=0x00 TTL=63 ID=14229 PROTO=UDP SPT=50000 DPT=17488 LEN=73

Reading it back needs two things this script supplies.

1. A historical pod IP -> namespace map. `kube_pod_info` in Prometheus carries
   both labels and is retained 26 weeks, so `count_over_time(kube_pod_info[W]
   offset O)` reconstructs the map for any past window without needing anything
   to have been saved at observation time.

2. A way around Loki's 500-series cap. Measured 2026-09-04: an unfiltered
   `sum by (src, dst, proto, dpt)` over one hour returns HTTP 400, and so does
   the same query wrapped in `count()` or `topk(400, ...)` -- the cap applies to
   the inner series, so the usual aggregation escape hatch does not help. A bare
   30d scan times out outright. This script instead pushes the source pod IPs
   into a line filter, which both prunes before the regexp parser runs and bounds
   the fan-out, and bisects the IP batch whenever a query still overflows.

Output is the set of EXTERNAL destinations each namespace actually reached.
The namespace-to-namespace half is deliberately out of scope: the goldmane edge
aggregator already answers it from a table built for the purpose
(docs/runbooks/goldmane-flow-trail.md,
`SELECT DISTINCT dst_ns FROM edge WHERE src_ns = '<ns>' AND action = 'allow'`).
Internal destinations are counted here only as a coarse volume cross-check.

Attribution and pod IP reuse
----------------------------
Calico hands a freed pod IP straight back out, so one IP can belong to several
namespaces inside a single bucket. Measured 2026-09-04 over a live window:

    bucket   pod IPs seen   IPs claimed by >1 namespace
    5m       348            25
    15m      357            30
    1h       384            54
    6h       468            130

An IP that is ambiguous within a bucket is EXCLUDED from attribution rather than
assigned to a guess, and reported under `pod_ip_collisions` plus each affected
namespace's `pods_unattributed`. Shrinking --bucket recovers coverage at the
cost of more queries. The high-churn namespaces (claude-agent, woodpecker,
tripit) are the ones that lose the most, and they are also the ones least
suitable for a static egress allowlist, so the trade lands in the right place.

Usage
-----
    # quick look, a few minutes
    scripts/egress-observation.py --window 24h --bucket 1h --resolve

    # the real pass, roughly 700 Loki queries at ~2s each
    scripts/egress-observation.py --window 7d --bucket 1h \
        --out-json egress.json --out-md egress.md --resolve

    # one namespace, fine grained
    scripts/egress-observation.py --window 6h --bucket 15m --namespace servarr
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from typing import Iterable

# --------------------------------------------------------------------------
# Address classification. Anything outside these ranges is external, and
# external is what an egress allowlist has to name.
#   pod     10.10.0.0/16   default-ipv4-ippool (the only Calico IPPool)
#   service 10.96.0.0/12   ClusterIP range (apiserver 10.96.0.1, DNS 10.96.0.10)
#   node    10.0.20.0/24   k8s-master + k8s-node1-5
#   lan     other RFC1918  NFS 192.168.1.127, pfSense, Proxmox, home devices
# --------------------------------------------------------------------------
POD_CIDR = ipaddress.ip_network("10.10.0.0/16")
SERVICE_CIDR = ipaddress.ip_network("10.96.0.0/12")
NODE_CIDR = ipaddress.ip_network("10.0.20.0/24")
PRIVATE_CIDRS = [
    ipaddress.ip_network(c)
    for c in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")
]

# The same ranges as a Loki matcher, so internal traffic is dropped inside Loki
# rather than dragged back over the wire. Written for a backtick raw string:
# LogQL double-quoted strings use Go escaping and reject a bare \. as an
# invalid char escape.
INTERNAL_DST_RE = (
    r"10\.10\..*|10\.96\..*|10\.0\.20\..*|192\.168\..*"
    r"|172\.(1[6-9]|2[0-9]|3[01])\..*|169\.254\..*|224\..*|255\..*"
)

# DPT is optional because ICMP lines carry TYPE/CODE instead of ports.
LINE_RE = (
    r"SRC=(?P<src>[0-9.]+) DST=(?P<dst>[0-9.]+)"
    r".*?PROTO=(?P<proto>[A-Z0-9]+)"
    r"(?: SPT=[0-9]+ DPT=(?P<dpt>[0-9]+))?"
)

DEFAULT_TIERS = ("3-edge", "4-aux")
SERIES_CAP_MARKER = "maximum number of series"
BATCH_IPS = 150  # measured: 200 IPs over 1h returns ~330 series in ~1.4s

_DURATION_RE = re.compile(r"^(\d+)([smhdw])$")
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def parse_duration(text: str) -> int:
    """'6h' -> 21600. Raises ValueError on anything else."""
    m = _DURATION_RE.match(text.strip())
    if not m:
        raise ValueError(f"bad duration {text!r}; want an integer plus s/m/h/d/w")
    return int(m.group(1)) * _UNIT_SECONDS[m.group(2)]


def format_duration(seconds: int) -> str:
    """Inverse of parse_duration, largest unit that divides evenly."""
    for unit in ("w", "d", "h", "m"):
        size = _UNIT_SECONDS[unit]
        if seconds >= size and seconds % size == 0:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def classify(addr: str) -> str:
    """Bucket a destination IP. An unparseable address counts as external so it
    stays visible in the report instead of being dropped."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return "external"
    if ip in POD_CIDR:
        return "pod"
    if ip in SERVICE_CIDR:
        return "service"
    if ip in NODE_CIDR:
        return "node"
    if any(ip in c for c in PRIVATE_CIDRS):
        return "lan"
    if ip.is_loopback or ip.is_multicast or ip.is_reserved:
        return "lan"
    return "external"


# --------------------------------------------------------------------------
# Instruments. Everything goes through the homelab CLI rather than a hand-rolled
# Loki/Prometheus client, so endpoints, auth and retries stay in one place.
# --------------------------------------------------------------------------
class QueryError(RuntimeError):
    pass


class SeriesCapError(QueryError):
    """Loki refused the query because it fanned out past max_query_series."""


def _run(cmd: list[str], timeout: int) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout).strip()
        if SERIES_CAP_MARKER in err:
            raise SeriesCapError(err)
        raise QueryError(err)
    return proc.stdout


def _series(payload: str) -> list[dict]:
    """Normalise a Loki matrix or a Prometheus vector to [{labels, value}]."""
    doc = json.loads(payload)
    if doc.get("status") != "success":
        raise QueryError(json.dumps(doc)[:400])
    out = []
    for s in doc.get("data", {}).get("result", []):
        if "values" in s:  # matrix: the last sample covers the whole range
            if not s["values"]:
                continue
            value = float(s["values"][-1][1])
        elif "value" in s:  # instant vector
            value = float(s["value"][1])
        else:
            continue
        out.append({"labels": s.get("metric", {}), "value": value})
    return out


def promql(expr: str, timeout: int = 120) -> list[dict]:
    return _series(_run(["homelab", "metrics", "query", expr, "--json"], timeout))


def logql(expr: str, timeout: int = 600) -> list[dict]:
    # --since 2m keeps the query_range window tiny. The range selector inside
    # the expression selects the data, and the final matrix sample covers it.
    return _series(
        _run(["homelab", "logs", "query", expr, "--since", "2m", "--json"], timeout)
    )


def offset_clause(seconds: int) -> str:
    """PromQL and LogQL both reject `offset 0s`, so bucket 0 gets no clause."""
    return f" offset {format_duration(seconds)}" if seconds > 0 else ""


# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
def namespace_tiers() -> dict[str, str]:
    """Live namespace -> tier label; namespaces with no tier label map to ''."""
    doc = json.loads(
        _run(["homelab", "k8s", "get", "default", "namespaces", "-o", "json"], 60)
    )
    return {
        item["metadata"]["name"]: item["metadata"].get("labels", {}).get("tier", "")
        for item in doc.get("items", [])
    }


def pod_ip_map(window: int, offset: int) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Pod IP -> namespace for one bucket, reconstructed from kube_pod_info.

    host_network pods are excluded: their pod_ip is the node IP, so keeping them
    would attribute every node-sourced packet to whichever namespace happened to
    run a host-network pod there. Their traffic is not a Calico workload
    endpoint, so the observe policy never logs it either.

    Returns (unambiguous ip -> namespace, ambiguous ip -> [namespaces]).
    """
    expr = (
        "count by (pod_ip, namespace) (count_over_time("
        f'kube_pod_info{{host_network="false"}}'
        f"[{format_duration(window)}]{offset_clause(offset)}))"
    )
    owners: dict[str, set[str]] = defaultdict(set)
    for s in promql(expr):
        ip = s["labels"].get("pod_ip", "")
        ns = s["labels"].get("namespace", "")
        if ip and ns:
            owners[ip].add(ns)
    resolved = {ip: next(iter(nss)) for ip, nss in owners.items() if len(nss) == 1}
    ambiguous = {ip: sorted(nss) for ip, nss in owners.items() if len(nss) > 1}
    return resolved, ambiguous


def _ip_line_filter(ips: Iterable[str]) -> str:
    """`|~ \\`SRC=(?:a|b) \\`` -- a line filter, so Loki prunes before the regexp
    parser runs. Filtering after the parse is an order of magnitude slower."""
    alt = "|".join(ip.replace(".", r"\.") for ip in sorted(ips))
    return f"|~ `SRC=(?:{alt}) `"


def flows_for_ips(
    ips: list[str], window: int, offset: int, external_only: bool, stats: dict
) -> list[dict]:
    """(src, dst, proto, dpt) -> packet count for a batch of source pod IPs.

    Bisects on Loki's series cap: a batch whose fan-out exceeds 500 series is
    split in half by source IP until each half fits. A single pod past 500
    destinations in one bucket cannot be split further, so it is reported
    truncated rather than silently dropped.
    """
    if not ips:
        return []
    dst_filter = f" | dst !~ `{INTERNAL_DST_RE}`" if external_only else ""
    expr = (
        "sum by (src, dst, proto, dpt) (count_over_time("
        '{job="node-journal"} |~ "calico-packet" '
        f"{_ip_line_filter(ips)} | regexp `{LINE_RE}`{dst_filter}"
        f"[{format_duration(window)}]{offset_clause(offset)}))"
    )
    try:
        stats["queries"] = stats.get("queries", 0) + 1
        return [
            {
                "src": s["labels"].get("src", ""),
                "dst": s["labels"].get("dst", ""),
                "proto": s["labels"].get("proto", ""),
                "dpt": s["labels"].get("dpt", ""),
                "packets": int(s["value"]),
                "truncated": False,
            }
            for s in logql(expr)
        ]
    except SeriesCapError:
        if len(ips) == 1:
            sys.stderr.write(
                f"  ! {ips[0]} exceeds 500 destinations in this bucket, "
                "recording it as truncated\n"
            )
            stats["truncated_pods"] = stats.get("truncated_pods", 0) + 1
            return [{"src": ips[0], "dst": "<over-500-destinations>", "proto": "",
                     "dpt": "", "packets": 0, "truncated": True}]
        mid = len(ips) // 2
        stats["bisects"] = stats.get("bisects", 0) + 1
        return flows_for_ips(ips[:mid], window, offset, external_only, stats) + \
            flows_for_ips(ips[mid:], window, offset, external_only, stats)


# --------------------------------------------------------------------------
# Reverse DNS. Best effort and never fatal: an unresolvable IP still belongs in
# the report. Resolved in a thread pool because most external IPs have no PTR
# record and each miss costs the full resolver timeout. servarr alone reaches
# ~700 addresses in two hours, so serial lookups dominate the whole run.
# --------------------------------------------------------------------------
def reverse_dns_bulk(
    ips: set[str], workers: int = 32, cache_path: str | None = None
) -> dict[str, str]:
    """Resolve every address once, reusing a JSON cache across runs.

    A 7-day pass reaches roughly 12,000 external addresses and most have no PTR
    record, so each miss costs the full resolver timeout. The cache means a
    re-run of the same window costs seconds instead of ten minutes.
    """
    cached: dict[str, str] = {}
    if cache_path and os.path.exists(cache_path):
        try:
            with open(cache_path) as fh:
                cached = json.load(fh)
        except (OSError, ValueError):
            cached = {}

    todo = sorted(ips - cached.keys())
    if todo:
        socket.setdefaulttimeout(2.0)

        def one(ip: str) -> tuple[str, str]:
            try:
                return ip, socket.gethostbyaddr(ip)[0]
            except (OSError, socket.herror):
                return ip, ""

        with ThreadPoolExecutor(max_workers=workers) as pool:
            cached.update(dict(pool.map(one, todo)))
        if cache_path:
            try:
                with open(cache_path, "w") as fh:
                    json.dump(cached, fh)
            except OSError as exc:
                sys.stderr.write(f"! could not write PTR cache: {exc}\n")
    return {ip: cached.get(ip, "") for ip in ips}


# --------------------------------------------------------------------------
# Analysis
# --------------------------------------------------------------------------
def readiness(rows: list[dict], buckets_with_pods: int) -> tuple[list[str], int]:
    """Split a namespace's destinations into the ones an allowlist can name and
    the ones it cannot.

    A destination present in at least half the buckets where the namespace was
    actually running is a standing dependency: name it. A destination seen in a
    single bucket is either genuinely rare or a rotating CDN address, and a
    static rule built on it breaks the next time DNS answers differently.

    Between those sits the periodic dependency: a nightly sync or an hourly poll
    shows up in a handful of buckets out of hundreds and is every bit as real,
    so it gets counted separately rather than lumped in with the noise.

    Returns (sorted stable destinations, recurring count, one-off count). The
    three bands are disjoint by destination address, so they sum to the
    namespace's external destination count.
    """
    seen: dict[str, int] = {}
    for r in rows:
        seen[r["dst"]] = max(seen.get(r["dst"], 0), r["buckets_seen"])
    stable = {
        dst for dst, n in seen.items()
        if buckets_with_pods > 0 and n * 2 >= buckets_with_pods
    }
    one_off = {dst for dst, n in seen.items() if n == 1} - stable
    recurring = set(seen) - stable - one_off
    return sorted(stable), len(recurring), len(one_off)


def namespace_record(
    tier: str,
    rows: list[dict],
    pods: set,
    buckets_with_pods: int,
    unattributed: set,
    internal_packets: int,
) -> dict:
    """One namespace's entry in the result. Kept separate from analyse() so the
    shape is unit-testable without a live Loki behind it."""
    stable, recurring_count, one_off_count = readiness(rows, buckets_with_pods)
    return {
        "tier": tier,
        "pods_observed": len(pods),
        "buckets_with_pods": buckets_with_pods,
        "pods_unattributed": sorted(unattributed),
        "external_destinations": len({r["dst"] for r in rows}),
        "stable_destinations": stable,
        "recurring_destinations": recurring_count,
        "one_off_destinations": one_off_count,
        "external_flows": rows,
        "internal_packets": internal_packets,
        "had_traffic": bool(rows) or internal_packets > 0,
    }


def analyse(args) -> dict:
    window = parse_duration(args.window)
    bucket = min(parse_duration(args.bucket), window)
    buckets = max(1, window // bucket)

    tiers = namespace_tiers()
    wanted_tiers = {t.strip() for t in args.tiers.split(",") if t.strip()}
    if args.namespace:
        for ns in args.namespace:
            if ns not in tiers:
                sys.stderr.write(f"! namespace {ns} does not exist, skipping\n")
        scope = sorted(ns for ns in args.namespace if ns in tiers)
    else:
        scope = sorted(ns for ns, tier in tiers.items() if tier in wanted_tiers)
    scope_set = set(scope)

    dests: dict[str, dict[tuple, dict]] = defaultdict(dict)
    internal_packets: dict[str, int] = defaultdict(int)
    seen_pods: dict[str, set[str]] = defaultdict(set)
    buckets_with_pods: dict[str, int] = defaultdict(int)
    unattributed: dict[str, set[str]] = defaultdict(set)
    collisions: dict[str, set[str]] = defaultdict(set)
    stats: dict[str, int] = {}
    started = time.time()

    for b in range(buckets):
        offset = b * bucket
        label = f"-{format_duration(offset + bucket)}"
        ip_ns, ambiguous = pod_ip_map(bucket, offset)
        for ip, nss in ambiguous.items():
            collisions[ip].update(nss)
            for ns in nss:
                if ns in scope_set:
                    unattributed[ns].add(ip)

        in_scope_ips = sorted(ip for ip, ns in ip_ns.items() if ns in scope_set)
        for ns in {ip_ns[ip] for ip in in_scope_ips}:
            buckets_with_pods[ns] += 1
        for ip in in_scope_ips:
            seen_pods[ip_ns[ip]].add(ip)
        sys.stderr.write(
            f"[bucket {b + 1}/{buckets} ending {label}] "
            f"{len(in_scope_ips)} attributable pod IPs in {len(scope)} namespaces\n"
        )

        rows: list[dict] = []
        for i in range(0, len(in_scope_ips), BATCH_IPS):
            batch = in_scope_ips[i:i + BATCH_IPS]
            try:
                rows += flows_for_ips(
                    batch, bucket, offset, not args.include_internal, stats
                )
            except QueryError as exc:
                sys.stderr.write(f"  ! batch of {len(batch)} failed: {str(exc)[:160]}\n")

        # Fold this bucket's rows to one entry per (namespace, destination)
        # BEFORE touching the running totals. Several pods in a namespace
        # reaching the same address is one bucket's worth of evidence, not one
        # per pod; counting per pod inflated buckets_seen far past the number
        # of buckets and made every busy namespace look permanently connected.
        bucket_totals: dict[tuple, int] = defaultdict(int)
        for row in rows:
            ns = ip_ns.get(row["src"])
            if ns is None or ns not in scope_set:
                continue
            kind = "external" if row["truncated"] else classify(row["dst"])
            if kind != "external":
                internal_packets[ns] += row["packets"]
                continue
            bucket_totals[
                (ns, row["dst"], row["proto"], row["dpt"], row["truncated"])
            ] += row["packets"]

        for (ns, dst, proto, dpt, truncated), packets in bucket_totals.items():
            agg = dests[ns].setdefault(
                (dst, proto, dpt),
                {
                    "dst": dst, "proto": proto, "port": dpt,
                    "packets": 0, "buckets_seen": 0, "truncated": truncated,
                    "newest_bucket": label, "oldest_bucket": label,
                },
            )
            agg["packets"] += packets
            agg["buckets_seen"] += 1
            # Buckets run newest to oldest, so the last write is the oldest.
            agg["oldest_bucket"] = label

    result = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "window": args.window,
        "bucket": format_duration(bucket),
        "buckets": buckets,
        "tiers": sorted(wanted_tiers),
        "namespaces_in_scope": len(scope),
        "elapsed_seconds": round(time.time() - started, 1),
        "loki_queries": stats.get("queries", 0),
        "bisects": stats.get("bisects", 0),
        "truncated_pods": stats.get("truncated_pods", 0),
        "pod_ip_collisions": {ip: sorted(n) for ip, n in sorted(collisions.items())},
        "namespaces": {},
    }
    ptr: dict[str, str] = {}
    if args.resolve:
        targets = {
            r["dst"]
            for ns_dests in dests.values()
            for r in ns_dests.values()
            if not r["truncated"]
        }
        sys.stderr.write(f"resolving PTR for {len(targets)} external addresses\n")
        ptr = reverse_dns_bulk(targets, cache_path=args.ptr_cache)

    for ns in scope:
        rows = sorted(dests.get(ns, {}).values(), key=lambda r: (-r["packets"], r["dst"]))
        if args.resolve:
            for r in rows:
                r["ptr"] = ptr.get(r["dst"], "")
        result["namespaces"][ns] = namespace_record(
            tier=tiers.get(ns, ""),
            rows=rows,
            pods=seen_pods.get(ns, set()),
            buckets_with_pods=buckets_with_pods.get(ns, 0),
            unattributed=unattributed.get(ns, set()),
            internal_packets=internal_packets.get(ns, 0),
        )
    return result


def render_markdown(result: dict) -> str:
    quiet = [ns for ns, d in result["namespaces"].items() if d["pods_observed"] == 0]
    lines = [
        f"# Egress observation, {result['window']} to {result['generated_at']}",
        "",
        f"Window {result['window']} in {result['buckets']} x {result['bucket']} buckets, "
        f"tiers {', '.join(result['tiers'])}, {result['namespaces_in_scope']} namespaces "
        f"in scope. {result['loki_queries']} Loki queries, {result['bisects']} series-cap "
        f"bisects, {result['elapsed_seconds']}s.",
        "",
        "## Enforcement readiness",
        "",
        "`Live` is the number of buckets the namespace had an attributable pod "
        "in, out of " + str(result["buckets"]) + ". The three destination bands "
        "are disjoint and sum to `Ext dests`: `stable` is present in at least "
        "half the live buckets, `recurring` in more than one but fewer than half "
        "(a nightly sync or an hourly poll), `one-off` in exactly one, which is "
        "what a rotating CDN address looks like. `Unattributed` is pod IPs shared "
        "with another namespace inside a bucket and therefore skipped.",
        "",
        "| Namespace | Tier | Live | Pods | Ext dests | Stable | Recurring | One-off | Unattributed |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for ns, d in sorted(
        result["namespaces"].items(),
        key=lambda kv: (-kv[1]["buckets_with_pods"], kv[1]["external_destinations"], kv[0]),
    ):
        if d["buckets_with_pods"] == 0:
            continue
        lines.append(
            f"| {ns} | {d['tier']} | {d['buckets_with_pods']} | {d['pods_observed']} | "
            f"{d['external_destinations']} | {len(d['stable_destinations'])} | "
            f"{d['recurring_destinations']} | {d['one_off_destinations']} | "
            f"{len(d['pods_unattributed'])} |"
        )
    lines += [
        "",
        "## Per-namespace external fan-out",
        "",
        "| Namespace | Tier | Pods seen | External dests | Flows | Internal packets | Unattributed IPs |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for ns, d in sorted(
        result["namespaces"].items(),
        key=lambda kv: (-kv[1]["external_destinations"], kv[0]),
    ):
        lines.append(
            f"| {ns} | {d['tier']} | {d['pods_observed']} | "
            f"{d['external_destinations']} | {len(d['external_flows'])} | "
            f"{d['internal_packets']} | {len(d['pods_unattributed'])} |"
        )
    lines += ["", "## External destinations by namespace", ""]
    for ns, d in sorted(result["namespaces"].items()):
        if not d["external_flows"]:
            continue
        lines += [f"### {ns} ({d['tier']})", "",
                  "| Destination | PTR | Proto | Port | Packets | Buckets |",
                  "|---|---|---|---:|---:|---:|"]
        for r in d["external_flows"]:
            lines.append(
                f"| {r['dst']} | {r.get('ptr', '')} | {r['proto']} | "
                f"{r['port'] or '-'} | {r['packets']} | {r['buckets_seen']} |"
            )
        lines.append("")
    if quiet:
        lines += ["## Namespaces with no pods in the window", "",
                  "Nothing was running, so there is no egress profile to build and "
                  "enforcing here proves nothing.", "",
                  ", ".join(f"`{ns}`" for ns in sorted(quiet)), ""]
    if result["pod_ip_collisions"]:
        lines += ["## Pod IP reuse inside one bucket", "",
                  "Calico hands a freed pod IP straight back out. These IPs belonged "
                  "to more than one namespace within a single bucket, so their flows "
                  "are excluded from attribution rather than guessed at. A smaller "
                  "--bucket recovers most of them.", ""]
        for ip, nss in result["pod_ip_collisions"].items():
            lines.append(f"- `{ip}`: {', '.join(nss)}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(
        description="Per-namespace external egress from the banked Calico observe data."
    )
    p.add_argument("--window", default="24h", help="how far back to read (default 24h)")
    p.add_argument("--bucket", default="15m",
                   help="bucket size (default 15m; smaller means fewer pod IPs "
                        "ambiguous between namespaces, more queries)")
    p.add_argument("--tiers", default=",".join(DEFAULT_TIERS),
                   help="namespace tier labels in scope")
    p.add_argument("--namespace", action="append",
                   help="restrict to this namespace (repeatable)")
    p.add_argument("--resolve", action="store_true",
                   help="reverse-DNS the external destinations")
    p.add_argument("--include-internal", action="store_true",
                   help="also pull pod/service/LAN destinations; much larger fan-out, "
                        "and the goldmane edge table is the east-west source of truth")
    p.add_argument("--ptr-cache", default=None,
                   help="JSON file holding reverse-DNS results between runs")
    p.add_argument("--out-json", help="write the full result here")
    p.add_argument("--out-md", help="write a markdown summary here")
    args = p.parse_args()

    if not shutil.which("homelab"):
        sys.stderr.write("homelab CLI not on PATH\n")
        return 2
    try:
        result = analyse(args)
    except (QueryError, ValueError) as exc:
        sys.stderr.write(f"query failed: {exc}\n")
        return 1

    if args.out_json:
        with open(args.out_json, "w") as fh:
            json.dump(result, fh, indent=2, sort_keys=True)
        sys.stderr.write(f"wrote {args.out_json}\n")
    md = render_markdown(result)
    if args.out_md:
        with open(args.out_md, "w") as fh:
            fh.write(md)
        sys.stderr.write(f"wrote {args.out_md}\n")
    if not args.out_json and not args.out_md:
        print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
