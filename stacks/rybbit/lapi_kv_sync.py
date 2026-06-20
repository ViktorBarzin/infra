#!/usr/bin/env python3
"""Sync CrowdSec LAPI decisions -> Cloudflare Workers KV.

The rybbit edge Worker enforces CrowdSec bans/captchas for Cloudflare-PROXIED
hosts by reading an edge-local KV entry (`ip:<addr>` -> `ban`|`captcha`) on each
request. This job is the control plane that keeps that KV in sync with LAPI:
the request path NEVER calls LAPI (no per-request hop) — exactly the nginx
"tail logs -> inject rules" model, just projected onto Workers KV instead of
nftables.

Design notes:
  * Pure Python stdlib (no pip/apk at runtime) — runs on stock python:3.12-alpine
    mounted from a ConfigMap, the alert_digest pattern (avoids the disk
    anti-pattern of installing packages every run).
  * FULL RECONCILE each run: read the complete current decision set from LAPI,
    compute the desired KV state, then upsert present keys and delete stale ones.
    This makes an un-ban (cscli decisions delete) clear from the edge within one
    interval instead of lingering until the original TTL — important for getting
    a false-positive un-blocked fast.
  * FAIL-SAFE: if LAPI can't be read, we SKIP the run (leave KV untouched) rather
    than wipe every ban. Existing KV entries then simply expire by their TTL, so
    a LAPI outage degrades toward fail-OPEN, never toward a stale all-block.
  * Only Ip-scope ban/captcha decisions are projected. Range-scope and other
    remediations are ignored (the Worker keys on a single IP).
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LAPI_URL = os.environ.get("LAPI_URL", "http://crowdsec-service.crowdsec.svc.cluster.local:8080").rstrip("/")
LAPI_KEY = os.environ["LAPI_KEY"]  # kvsync bouncer key, registered in LAPI
CF_ACCOUNT_ID = os.environ["CF_ACCOUNT_ID"]
CF_NAMESPACE_ID = os.environ["CF_KV_NAMESPACE_ID"]
CF_API_TOKEN = os.environ["CF_API_TOKEN"]  # scoped: Workers KV Storage:Edit
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "").rstrip("/")  # optional
KEY_PREFIX = "ip:"
# CrowdSec remediation type -> KV value the Worker understands.
TYPE_MAP = {"ban": "ban", "captcha": "captcha"}
CF_API = "https://api.cloudflare.com/client/v4"
MIN_TTL = 60  # Cloudflare KV minimum expiration_ttl (seconds)


def _req(url, *, method="GET", headers=None, data=None, timeout=20):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    return json.loads(body) if body else None


def parse_duration_seconds(dur):
    """Parse a Go duration string (e.g. '167h59m51.5s') into whole seconds.

    LAPI returns the REMAINING duration of each decision here. We floor to the
    second and clamp to Cloudflare's 60s minimum so the edge entry outlives the
    next sync interval.
    """
    if not dur:
        return MIN_TTL
    dur = dur.strip().lstrip("+")
    if dur.startswith("-"):  # already expired; give it the floor and move on
        return MIN_TTL
    total = 0.0
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)(h|m|s|ms|us|µs|ns)", dur):
        v = float(value)
        total += {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "µs": 1e-6, "ns": 1e-9}[unit] * v
    return max(MIN_TTL, int(total))


def fetch_decisions():
    """Return desired KV state {('ip:<addr>'): (value, ttl_seconds)} from LAPI.

    Raises on transport/HTTP error so the caller can SKIP the run (fail-safe).
    """
    out = {}
    data = _req(f"{LAPI_URL}/v1/decisions", headers={"X-Api-Key": LAPI_KEY, "Accept": "application/json"})
    for d in data or []:
        if (d.get("scope") or "").lower() != "ip":
            continue
        value = TYPE_MAP.get((d.get("type") or "").lower())
        if not value:
            continue
        ip = d.get("value")
        if not ip:
            continue
        key = KEY_PREFIX + ip
        ttl = parse_duration_seconds(d.get("duration"))
        # If the same IP carries multiple decisions, ban beats captcha and the
        # longest TTL wins.
        if key in out:
            prev_val, prev_ttl = out[key]
            value = "ban" if "ban" in (value, prev_val) else value
            ttl = max(ttl, prev_ttl)
        out[key] = (value, ttl)
    return out


def cf_list_keys():
    """List existing `ip:` keys currently in the KV namespace (paginated)."""
    keys = []
    cursor = ""
    while True:
        url = f"{CF_API}/accounts/{CF_ACCOUNT_ID}/storage/kv/namespaces/{CF_NAMESPACE_ID}/keys?prefix={KEY_PREFIX}&limit=1000"
        if cursor:
            url += f"&cursor={urllib.parse.quote(cursor)}"
        res = _req(url, headers={"Authorization": f"Bearer {CF_API_TOKEN}"})
        keys.extend(k["name"] for k in (res.get("result") or []))
        cursor = (res.get("result_info") or {}).get("cursor") or ""
        if not cursor:
            return keys


def cf_bulk_put(items):
    """items: list of (key, value, ttl). Cloudflare bulk PUT (<=10000/call)."""
    for i in range(0, len(items), 10000):
        chunk = [{"key": k, "value": v, "expiration_ttl": t} for k, v, t in items[i:i + 10000]]
        _req(
            f"{CF_API}/accounts/{CF_ACCOUNT_ID}/storage/kv/namespaces/{CF_NAMESPACE_ID}/bulk",
            method="PUT",
            headers={"Authorization": f"Bearer {CF_API_TOKEN}", "Content-Type": "application/json"},
            data=json.dumps(chunk).encode(),
        )


def cf_bulk_delete(keys):
    for i in range(0, len(keys), 10000):
        _req(
            f"{CF_API}/accounts/{CF_ACCOUNT_ID}/storage/kv/namespaces/{CF_NAMESPACE_ID}/bulk/delete",
            method="POST",
            headers={"Authorization": f"Bearer {CF_API_TOKEN}", "Content-Type": "application/json"},
            data=json.dumps(list(keys)).encode(),
        )


def push_metrics(synced, deleted, ok):
    if not PUSHGATEWAY:
        return
    payload = (
        "# TYPE crowdsec_kv_sync_decisions gauge\n"
        f"crowdsec_kv_sync_decisions {synced}\n"
        "# TYPE crowdsec_kv_sync_deleted gauge\n"
        f"crowdsec_kv_sync_deleted {deleted}\n"
        "# TYPE crowdsec_kv_sync_success gauge\n"
        f"crowdsec_kv_sync_success {1 if ok else 0}\n"
        "# TYPE crowdsec_kv_sync_last_run_seconds gauge\n"
        f"crowdsec_kv_sync_last_run_seconds {int(time.time())}\n"
    )
    try:
        _req(f"{PUSHGATEWAY}/metrics/job/crowdsec-kv-sync", method="PUT",
             headers={"Content-Type": "text/plain"}, data=payload.encode(), timeout=10)
    except Exception as e:  # metrics are best-effort, never fail the job
        print(f"[warn] pushgateway: {e}", file=sys.stderr)


def main():
    # 1. Desired state from LAPI. Any failure here = SKIP (fail-safe, leave KV).
    try:
        desired = fetch_decisions()
    except Exception as e:
        print(f"[skip] LAPI unreadable ({e}); leaving KV untouched so existing "
              f"bans expire by TTL (fail-open).", file=sys.stderr)
        push_metrics(0, 0, ok=False)
        return 0

    # 2. Current edge state.
    existing = set(cf_list_keys())
    desired_keys = set(desired)

    upserts = [(k, v, t) for k, (v, t) in desired.items()]
    stale = existing - desired_keys

    if upserts:
        cf_bulk_put(upserts)
    if stale:
        cf_bulk_delete(stale)

    print(f"[ok] synced {len(upserts)} decision(s) to KV, removed {len(stale)} stale; "
          f"{sum(1 for _, v, _ in upserts if v == 'ban')} ban / "
          f"{sum(1 for _, v, _ in upserts if v == 'captcha')} captcha")
    push_metrics(len(upserts), len(stale), ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
