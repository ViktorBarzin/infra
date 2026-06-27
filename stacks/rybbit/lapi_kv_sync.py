#!/usr/bin/env python3
"""Sync CrowdSec LAPI decisions -> ONE Cloudflare account IP List (block-only).

Cloudflare-PROXIED hosts terminate at the CF edge, so the in-cluster CrowdSec
bouncer (which keys on the client IP Traefik sees) never decides on them. We
push the decisions into the edge instead: a zone-scoped WAF custom rule blocks
`(ip.src in $crowdsec_ban)` across EVERY proxied host in the zone (the Authentik
auth hosts are carved out in crowdsec_edge.tf so a ban can't break login). This
job is the control plane that keeps that one IP List in sync with LAPI.

Enforcement is BAN-ONLY: only scope=="ip" decisions of type "ban" are synced.
"captcha" decisions are deliberately NOT pushed — the CF account allows only ONE
Rules List with a single block action, so folding captcha in would hard-block a
soft challenge across every proxied host. Captcha remediation stays at the
in-cluster Traefik bouncer (Turnstile) for non-proxied apps. (Changed 2026-06-20
from the prior ban+captcha fold that downgraded captcha to a hard edge block.)

(Filename kept as lapi_kv_sync.py for path/ConfigMap continuity with the prior
Workers-KV design; it no longer touches KV — it reconciles a CF Rules List.)

Design notes:
  * Pure Python stdlib (no pip/apk at runtime) — runs on stock python:3.12-alpine
    mounted from a ConfigMap, the alert_digest pattern.
  * FULL RECONCILE each run: read the complete decision set from LAPI, take the
    UNION of ban + captcha (scope=="ip") as the single desired set, then compute
    add (desired - existing) and remove (existing - desired) against the one
    crowdsec_ban list and apply both. A `cscli decisions delete` therefore
    clears from the edge within one interval (<=2 min).
  * FAIL-SAFE on LAPI: if LAPI can't be read we SKIP the run (list untouched,
    exit 0). A LAPI outage thus freezes the edge state rather than wiping the
    block list — degrade toward the last-known-good block set, never toward
    all-block or a thundering un-ban. (Decisions linger only until the next
    successful sync, not their TTL — we reconcile to LAPI truth, we don't
    expire entries.)
  * FAIL-LOUD on Cloudflare: any CF API error is logged and the job exits
    non-zero so the failure is visible (CronJob backoff + missing success
    metric + the next run retries).

Cloudflare Rules-Lists API (account-level IP list items), verified against the
official API reference (developers.cloudflare.com, 2026):
  * GET    /accounts/{acct}/rules/lists/{list}/items   -> paginated; next page
           cursor at result_info.cursors.after, passed back as ?cursor=. Each
           item = {"id","ip","created_on",...}.
  * POST   /accounts/{acct}/rules/lists/{list}/items   -> body JSON ARRAY
           [{"ip":"1.2.3.4"},...]. APPENDS/upserts (does NOT replace the list).
           ASYNCHRONOUS: returns {"result":{"operation_id":...}}.
  * DELETE /accounts/{acct}/rules/lists/{list}/items   -> body {"items":[{"id":
           "<item_id>"},...]} (delete by item id, not ip). ASYNCHRONOUS.
  * GET    /accounts/{acct}/rules/lists/bulk_operations/{op_id} -> status in
           {pending,running,completed,failed} (failed carries `error`).
  ASYNC HANDLING: Cloudflare allows only ONE pending bulk operation per ACCOUNT.
  So we must NOT fire add+delete concurrently — we serialize and poll each
  operation_id to a terminal state (short bounded timeout) before the next
  mutation. If a poll times out we stop mutating for this run and report
  partial success (the next 2-min run reconciles the rest); we never abandon an
  in-flight op and immediately issue another (that would 409/reject).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LAPI_URL = os.environ.get(
    "LAPI_URL", "http://crowdsec-service.crowdsec.svc.cluster.local:8080"
).rstrip("/")
LAPI_KEY = os.environ["LAPI_KEY"]  # kvsync bouncer key, registered in LAPI
CF_ACCOUNT_ID = os.environ["CF_ACCOUNT_ID"]
CF_API_TOKEN = os.environ["CF_API_TOKEN"]  # scoped: Account Filter Lists Edit
CF_BAN_LIST_ID = os.environ["CF_BAN_LIST_ID"]
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "").rstrip("/")  # optional

CF_API = "https://api.cloudflare.com/client/v4"
# Cloudflare item objects expose the ip differently between list and create
# responses; for an IP-kind list each GET item carries a top-level "ip".
# Batch sizes: no official per-request cap is documented, so keep batches
# generous but bounded (well under the global 1200 req / 5 min limit).
BATCH = 1000
# Async op polling: 1 pending bulk op per account, so poll to terminal state.
POLL_TIMEOUT = 25  # seconds to wait for one bulk op (the run has ~110s budget)
POLL_INTERVAL = 1.0


class CFError(Exception):
    """Cloudflare API failure. Carries the HTTP status so the caller can treat a
    429 rate-limit as a soft-skip (retry next run) instead of a hard failure."""

    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def _req(url, *, method="GET", headers=None, data=None, timeout=20):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    return json.loads(body) if body else None


def _cf(url, *, method="GET", payload=None, timeout=20):
    """Call the CF API with the bearer token; raise CFError on any failure."""
    headers = {"Authorization": f"Bearer {CF_API_TOKEN}"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    try:
        res = _req(url, method=method, headers=headers, data=data, timeout=timeout)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode(errors="replace")[:500]
        except Exception:
            pass
        raise CFError(f"{method} {url} -> HTTP {e.code} {detail}", status=e.code) from e
    except urllib.error.URLError as e:
        raise CFError(f"{method} {url} -> {e}") from e
    if res is not None and not res.get("success", True):
        raise CFError(f"{method} {url} -> not success: {res.get('errors')}")
    return res


# --------------------------------------------------------------------------- #
# LAPI
# --------------------------------------------------------------------------- #
def fetch_decisions():
    """Return the desired set of IPs to BLOCK at the edge.

    Only scope=="ip" decisions of type "ban" are projected (the WAF rule keys on
    ip.src). "captcha" decisions are deliberately NOT pushed to the edge: the CF
    account allows only ONE Rules List with a single block action, so folding
    captcha in would HARD-BLOCK a soft challenge across every proxied host (and,
    before the auth-host carve-out in crowdsec_edge.tf, could lock a user out of
    Authentik itself). Edge enforcement is therefore ban-only; captcha
    remediation stays at the in-cluster Traefik bouncer (Turnstile) for
    non-proxied apps. Raises on transport/HTTP error so the caller can SKIP the
    run (fail-safe). 2026-06-20.
    """
    data = _req(
        f"{LAPI_URL}/v1/decisions",
        headers={"X-Api-Key": LAPI_KEY, "Accept": "application/json"},
    )
    block = set()
    skipped_capi = 0
    for d in data or []:
        if (d.get("scope") or "").lower() != "ip":
            continue
        # EXCLUDE the CAPI community blocklist: ~31k IPs, far over a CF IP
        # List's capacity, and ALREADY enforced in-kernel for direct hosts by
        # the cs-firewall-bouncer DaemonSet. The edge list carries only our
        # HIGH-SIGNAL local + curated decisions (own scenarios, cscli-import,
        # subscribed lists).
        if (d.get("origin") or "").upper() == "CAPI":
            skipped_capi += 1
            continue
        ip = d.get("value")
        if not ip:
            continue
        dtype = (d.get("type") or "").lower()
        if dtype == "ban":
            block.add(ip)
        # captcha / throttle / other remediation types are ignored at the edge
        # (ban-only enforcement — see the docstring above)
    if skipped_capi:
        print(f"[info] excluded {skipped_capi} CAPI decisions (enforced at L3 by "
              f"the firewall-bouncer; too many for a CF list)")
    # Safety cap: a CF IP List can't hold unbounded entries. Never push more
    # than this — keep a bounded, deterministic subset and warn.
    MAX_ITEMS = 9000
    if len(block) > MAX_ITEMS:
        print(f"[warn] desired {len(block)} exceeds {MAX_ITEMS} cap; truncating "
              f"(consider a CF plan with a higher list limit)", file=sys.stderr)
        block = set(sorted(block)[:MAX_ITEMS])
    return block


# --------------------------------------------------------------------------- #
# Cloudflare list items
# --------------------------------------------------------------------------- #
def cf_list_items(list_id):
    """Return {ip: item_id} for every item currently in the list (paginated)."""
    out = {}
    cursor = ""
    while True:
        # per_page max for the list-items endpoint is 500; 1000 returns a
        # misleading HTTP 400 "invalid or expired cursor" (CF error 10027).
        url = f"{CF_API}/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items?per_page=500"
        if cursor:
            url += f"&cursor={urllib.parse.quote(cursor)}"
        res = _cf(url)
        for it in (res.get("result") or []):
            ip = it.get("ip")
            if ip:
                out[ip] = it.get("id")
        cursor = (((res.get("result_info") or {}).get("cursors") or {}).get("after")) or ""
        if not cursor:
            return out


def _wait_for_op(op_id):
    """Poll a bulk operation to a terminal state. Returns True if completed,
    False if it timed out (still pending/running). Raises CFError if it failed.

    We must reach a terminal state before issuing the next mutation: CF allows
    only one pending bulk op per account, so firing another while this is
    in-flight would be rejected.
    """
    if not op_id:
        return True
    deadline = time.time() + POLL_TIMEOUT
    url = f"{CF_API}/accounts/{CF_ACCOUNT_ID}/rules/lists/bulk_operations/{op_id}"
    while time.time() < deadline:
        res = _cf(url)
        status = ((res.get("result") or {}).get("status") or "").lower()
        if status == "completed":
            return True
        if status == "failed":
            raise CFError(f"bulk op {op_id} failed: {(res.get('result') or {}).get('error')}")
        time.sleep(POLL_INTERVAL)
    print(f"[warn] bulk op {op_id} still {status or 'pending'} after {POLL_TIMEOUT}s; "
          f"stopping further mutations this run (next run reconciles)", file=sys.stderr)
    return False


def _op_id(res):
    return ((res or {}).get("result") or {}).get("operation_id")


def cf_add_items(list_id, ips):
    """POST new IPs to the list (append). Returns the operation_id (async)."""
    # If callers ever exceed one batch, each POST is a separate bulk op and the
    # single-pending-op rule forces us to wait between them.
    last_op = None
    for i in range(0, len(ips), BATCH):
        chunk = [{"ip": ip} for ip in ips[i : i + BATCH]]
        res = _cf(
            f"{CF_API}/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items",
            method="POST",
            payload=chunk,
        )
        last_op = _op_id(res)
        if i + BATCH < len(ips):  # more chunks coming -> serialize
            if not _wait_for_op(last_op):
                return last_op  # timed out; bail (partial), next run continues
    return last_op


def cf_delete_items(list_id, item_ids):
    """DELETE items by id. Returns the operation_id (async)."""
    last_op = None
    for i in range(0, len(item_ids), BATCH):
        chunk = {"items": [{"id": iid} for iid in item_ids[i : i + BATCH]]}
        res = _cf(
            f"{CF_API}/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items",
            method="DELETE",
            payload=chunk,
        )
        last_op = _op_id(res)
        if i + BATCH < len(item_ids):
            if not _wait_for_op(last_op):
                return last_op
    return last_op


def reconcile(label, list_id, desired):
    """Reconcile one list to `desired` (a set of IPs).

    Returns (added, removed). Serializes add->wait->delete so we respect the
    one-pending-bulk-op-per-account limit. Raises CFError on hard failure.
    """
    existing = cf_list_items(list_id)  # {ip: item_id}
    existing_ips = set(existing)
    to_add = sorted(desired - existing_ips)
    to_remove_ids = [existing[ip] for ip in (existing_ips - desired)]

    added = removed = 0
    if to_add:
        op = cf_add_items(list_id, to_add)
        if _wait_for_op(op):
            added = len(to_add)
        else:
            # add op didn't finish; skip the delete this run to avoid stacking a
            # second pending op, and report what we attempted.
            print(f"[warn] {label}: add op not confirmed; deferring deletes", file=sys.stderr)
            return added, removed
    if to_remove_ids:
        op = cf_delete_items(list_id, to_remove_ids)
        if _wait_for_op(op):
            removed = len(to_remove_ids)
    print(f"[ok] {label}: +{added} / -{removed} (desired={len(desired)}, was={len(existing_ips)})")
    return added, removed


# --------------------------------------------------------------------------- #
# Metrics (best-effort)
# --------------------------------------------------------------------------- #
def push_metrics(block_n, ok):
    if not PUSHGATEWAY:
        return
    payload = (
        "# TYPE crowdsec_cf_list_ban_count gauge\n"
        f"crowdsec_cf_list_ban_count {block_n}\n"
        "# TYPE crowdsec_cf_list_sync_success gauge\n"
        f"crowdsec_cf_list_sync_success {1 if ok else 0}\n"
        "# TYPE crowdsec_cf_list_sync_last_run_seconds gauge\n"
        f"crowdsec_cf_list_sync_last_run_seconds {int(time.time())}\n"
    )
    try:
        _req(
            f"{PUSHGATEWAY}/metrics/job/crowdsec-cf-list-sync",
            method="PUT",
            headers={"Content-Type": "text/plain"},
            data=payload.encode(),
            timeout=10,
        )
    except Exception as e:  # metrics are best-effort, never fail the job
        print(f"[warn] pushgateway: {e}", file=sys.stderr)


# --------------------------------------------------------------------------- #
def main():
    # 1. Desired state from LAPI. Any failure here = SKIP (fail-safe).
    try:
        block = fetch_decisions()
    except Exception as e:
        print(
            f"[skip] LAPI unreadable ({e}); leaving the CF list untouched "
            f"(fail-safe: freeze last-known edge state).",
            file=sys.stderr,
        )
        push_metrics(0, ok=False)
        return 0

    print(f"[info] LAPI desired: {len(block)} block (ban-only, ip-scope)")

    # 2. Reconcile the single block list. A 429 rate-limit is a SOFT-SKIP (exit
    # 0, retry next */2 run) — like the LAPI fail-safe above — so a transient
    # Cloudflare Lists-API throttle never marks the job Failed or triggers a k8s
    # retry-storm (rapid re-attempts only deepen the throttle until it stops
    # clearing). Any OTHER CF error still fails loud (non-zero exit).
    try:
        reconcile("block", CF_BAN_LIST_ID, block)
    except CFError as e:
        if e.status == 429:
            print(
                f"[skip] Cloudflare rate-limited ({e}); leaving the list "
                f"untouched this run, will retry next cycle (fail-safe).",
                file=sys.stderr,
            )
            push_metrics(len(block), ok=False)
            return 0
        print(f"[error] Cloudflare API failure: {e}", file=sys.stderr)
        push_metrics(len(block), ok=False)
        return 1

    push_metrics(len(block), ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
