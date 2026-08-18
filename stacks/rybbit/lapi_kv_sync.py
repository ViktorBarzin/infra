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

# Write backoff ladder, in seconds. Cloudflare rejects Lists WRITES with HTTP
# 429 / code 10040 for long stretches (measured 2026-08-16: 1.6 days unbroken,
# and a 2.4-day stretch the week before) while READS keep working and the
# published rate-limit headers report a nearly-full budget — `r=1199` of
# `q=1200;w=300` on the very request being rejected. So the limiter doing the
# rejecting is NOT the one it advertises, and it is not counting our requests
# per five minutes. What it does track, per Cloudflare's own support guidance,
# is the number of list CHANGES over time.
#
# The failure mode that follows is self-sustaining: a fixed retry cadence keeps
# presenting the same change, and if attempts count toward that budget the
# budget never refills. At the old */2 that was ~720 attempts a day to move a
# five-entry list. This ladder makes each failure buy quiet instead of another
# attempt, and resets the moment a write lands.
#
# Ladder raised 2026-08-18 (was 30m/1h/2h/4h/6h). Measured that day: over the
# trailing 240h there were 1,852 rate-limited attempts and exactly ONE
# successful write. Three attempts spaced ~6h apart went 429, 429, then
# succeeded, so the shorter rungs were spending attempts at intervals the
# limiter does not accept; only the 6h rung was near the useful range. Starting
# at 2h and capping at 12h keeps write attempts to a couple a day.
#
# Also established 2026-08-18: the limiter is per-ACCOUNT, not per-token — the
# least-privilege sync token and the global API key are rejected alike, so
# there is no credential to switch to. Reads are a separate, unthrottled bucket
# (read_segments_list_items), which is why measuring drift on every run is free
# and the schedule can stay well ahead of the write cadence.
BACKOFF_LADDER = [7200, 21600, 43200]  # 2h, 6h, 12h (cap)
PGW_JOB = "crowdsec-cf-list-sync"


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
    except (TimeoutError, OSError) as e:
        # urlopen(timeout=) raises a bare TimeoutError, which is NOT a subclass
        # of URLError — so before 2026-08-16 a slow Cloudflare response escaped
        # as an uncaught traceback and exited 1. With backoff_limit=0 that marks
        # the Job Failed AND skips push_metrics entirely, leaving
        # crowdsec_cf_list_sync_success frozen at its last value: the freshness
        # alerts would have been looking at a stale sample. Treat it as an
        # ordinary API failure so the run reports itself.
        raise CFError(f"{method} {url} -> {e!r}") from e
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


def cf_replace_items(list_id, ips):
    """PUT the full desired set — ONE bulk operation. Returns the operation_id.

    Replaces the previous POST-then-DELETE pair. Cloudflare counts list CHANGES,
    and a sync that both adds and removes used to spend two bulk operations to
    express one reconciliation; PUT expresses it in one. It also removes the
    serialize-and-poll dance between the two, which existed only because
    Cloudflare permits a single pending bulk op per account.

    PUT is documented as "removes all existing items from the list and adds the
    provided items" — safe here because `desired` is always the complete set we
    want, never a delta. The caller must therefore never pass a partial set; the
    LAPI fail-safe in main() is what guarantees that (an unreadable LAPI skips
    the run rather than reconciling toward an empty desired state).
    """
    res = _cf(
        f"{CF_API}/accounts/{CF_ACCOUNT_ID}/rules/lists/{list_id}/items",
        method="PUT",
        payload=[{"ip": ip, "comment": "crowdsec ban"} for ip in sorted(ips)],
    )
    return _op_id(res)


def measure_drift(label, list_id, desired):
    """Read the list and report how far it is from `desired`.

    Returns (drift, to_add, to_remove). Reads are cheap and never throttled, so
    this runs on EVERY path — including while we are backing off and while a
    write has just been refused. Knowing the drift is the whole point: a run can
    succeed at doing nothing while the edge quietly disagrees with CrowdSec.
    """
    existing_ips = set(cf_list_items(list_id))
    to_add = sorted(desired - existing_ips)
    to_remove = sorted(existing_ips - desired)
    drift = len(to_add) + len(to_remove)
    if drift:
        print(f"[info] {label}: drift={drift} (+{len(to_add)} / -{len(to_remove)}) "
              f"add={to_add} remove={to_remove}")
    else:
        print(f"[ok] {label}: in sync ({len(desired)} items), no write needed")
    return drift, to_add, to_remove


def apply_desired(label, list_id, desired):
    """Push `desired` to the list as ONE bulk operation. Raises CFError."""
    op = cf_replace_items(list_id, desired)
    if _wait_for_op(op):
        print(f"[ok] {label}: replaced list with {len(desired)} items")
    else:
        # The op was accepted but has not reached a terminal state inside our
        # budget. It is in flight, so it counts as a write either way — do not
        # re-issue; the next run reads the result and decides afresh.
        print(f"[warn] {label}: replace op accepted but not confirmed in "
              f"{POLL_TIMEOUT}s; next run verifies", file=sys.stderr)


# --------------------------------------------------------------------------- #
# Metrics + cross-run backoff state (both live in Pushgateway)
# --------------------------------------------------------------------------- #
# CronJob pods are stateless, so the backoff has to survive somewhere. It lives
# in the Pushgateway alongside the metrics: the job already writes there, the
# values never expire (which is a trap for freshness alerts but exactly right
# for state), and it needs no RBAC, no volume and no second datastore.
#
# If the Pushgateway is unreadable we fall back to "no backoff" — one write
# attempt per run. That is deliberately the permissive direction: the cost is a
# handful of extra attempts, whereas failing closed would silently stop syncing
# bans whenever the metrics stack blipped.
def read_state():
    """Return (fail_streak, backoff_until, last_ban_count, last_drift).

    The last two exist so a run that could not MEASURE them can re-publish the
    previous values rather than overwrite them with zeros — see the LAPI
    fail-safe in main().
    """
    if not PUSHGATEWAY:
        return 0, 0.0, 0, 0
    try:
        req = urllib.request.Request(f"{PUSHGATEWAY}/metrics")
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode(errors="replace")
    except Exception as e:
        print(f"[warn] pushgateway unreadable ({e}); assuming no backoff",
              file=sys.stderr)
        return 0, 0.0, 0, 0

    def _get(name):
        # Pushed samples always come back labelled {instance="",job="..."}, and
        # timestamps come back in scientific notation (1.786e+09) which int()
        # rejects — so match on the name prefix and go via float().
        for line in body.splitlines():
            if line.startswith("#") or not line.startswith(name):
                continue
            rest = line[len(name):]
            if rest and rest[0] not in "{ ":
                continue  # a longer metric name that merely shares the prefix
            if PGW_JOB not in line and rest.startswith("{"):
                continue
            try:
                return float(line.rsplit(" ", 1)[1])
            except (IndexError, ValueError):
                continue
        return 0.0

    return (
        int(_get("crowdsec_cf_list_write_fail_streak")),
        _get("crowdsec_cf_list_write_backoff_until_seconds"),
        int(_get("crowdsec_cf_list_ban_count")),
        int(_get("crowdsec_cf_list_drift_items")),
    )


def push_metrics(block_n, ok, drift=0, fail_streak=0, backoff_until=0.0):
    if not PUSHGATEWAY:
        return
    payload = (
        "# TYPE crowdsec_cf_list_ban_count gauge\n"
        f"crowdsec_cf_list_ban_count {block_n}\n"
        "# TYPE crowdsec_cf_list_sync_success gauge\n"
        f"crowdsec_cf_list_sync_success {1 if ok else 0}\n"
        "# TYPE crowdsec_cf_list_sync_last_run_seconds gauge\n"
        f"crowdsec_cf_list_sync_last_run_seconds {int(time.time())}\n"
        # How far the edge list is from LAPI right now. This is the honest
        # health signal: sync_success says "did this run write cleanly", drift
        # says "is the edge actually enforcing what CrowdSec decided". A run can
        # succeed at doing nothing while drift sits at 2 for days.
        "# TYPE crowdsec_cf_list_drift_items gauge\n"
        f"crowdsec_cf_list_drift_items {drift}\n"
        "# TYPE crowdsec_cf_list_write_fail_streak gauge\n"
        f"crowdsec_cf_list_write_fail_streak {fail_streak}\n"
        "# TYPE crowdsec_cf_list_write_backoff_until_seconds gauge\n"
        f"crowdsec_cf_list_write_backoff_until_seconds {int(backoff_until)}\n"
    )
    try:
        _req(
            f"{PUSHGATEWAY}/metrics/job/{PGW_JOB}",
            method="PUT",
            headers={"Content-Type": "text/plain"},
            data=payload.encode(),
            timeout=10,
        )
    except Exception as e:  # metrics are best-effort, never fail the job
        print(f"[warn] pushgateway: {e}", file=sys.stderr)


# --------------------------------------------------------------------------- #
def main():
    streak, backoff_until, last_bans, last_drift = read_state()

    # 1. Desired state from LAPI. Any failure here = SKIP (fail-safe).
    try:
        block = fetch_decisions()
    except Exception as e:
        print(
            f"[skip] LAPI unreadable ({e}); leaving the CF list untouched "
            f"(fail-safe: freeze last-known edge state).",
            file=sys.stderr,
        )
        # Carry the previous ban_count and drift forward rather than pushing
        # zeros. Without a desired set we measured NEITHER, and a pushed 0 is
        # not "no drift" — it is a falsely reassuring value that would resolve
        # CrowdSecEdgeListDrifted while the edge is still stale. Same failure
        # shape as the -1 sentinel fixed in 94f19073, in the opposite
        # direction: do not publish a number you did not measure.
        push_metrics(last_bans, ok=False, drift=last_drift,
                     fail_streak=streak, backoff_until=backoff_until)
        return 0

    print(f"[info] LAPI desired: {len(block)} block (ban-only, ip-scope)")

    now = time.time()

    # 2. Measure first, always. The read is never throttled, and the drift is
    #    what tells us whether the edge is actually enforcing what CrowdSec
    #    decided — independent of whether this particular run got to write.
    try:
        drift, _, _ = measure_drift("block", CF_BAN_LIST_ID, block)
    except CFError as e:
        print(f"[error] Cloudflare list unreadable: {e}", file=sys.stderr)
        push_metrics(len(block), ok=False, fail_streak=streak,
                     backoff_until=backoff_until)
        return 1

    if not drift:
        # Nothing to do, and nothing spent. This is the common case and it is
        # why a frequent schedule is affordable at all.
        push_metrics(len(block), ok=True, drift=0, fail_streak=0,
                     backoff_until=0)
        return 0

    # 3. There IS drift. Write, unless we are deliberately holding off.
    if backoff_until > now:
        mins = int((backoff_until - now) / 60)
        print(
            f"[hold] write backoff active for another {mins}m "
            f"(fail streak {streak}); drift={drift}. Reading only.",
            file=sys.stderr,
        )
        push_metrics(len(block), ok=False, drift=drift, fail_streak=streak,
                     backoff_until=backoff_until)
        return 0

    # A 429 is a soft-skip (exit 0) — a Cloudflare throttle is not a job
    # failure and must never become a k8s retry-storm. It also BUYS QUIET: the
    # next write moves up the ladder, so a throttled stretch costs a handful of
    # attempts a day rather than one per run.
    try:
        apply_desired("block", CF_BAN_LIST_ID, block)
    except CFError as e:
        if e.status == 429:
            streak += 1
            wait = BACKOFF_LADDER[min(streak, len(BACKOFF_LADDER)) - 1]
            backoff_until = now + wait
            print(
                f"[skip] Cloudflare rate-limited ({e}); list left untouched. "
                f"Fail streak {streak}, next write attempt in {wait // 60}m "
                f"(fail-safe).",
                file=sys.stderr,
            )
            # Report the drift we MEASURED, not a sentinel. An earlier version
            # pushed -1 here, which silently made CrowdSecEdgeListDrifted
            # (expr: > 0) unable to fire on the one path where drift matters
            # most — a refused write is exactly when the edge is out of date.
            push_metrics(len(block), ok=False, drift=drift, fail_streak=streak,
                         backoff_until=backoff_until)
            return 0
        print(f"[error] Cloudflare API failure: {e}", file=sys.stderr)
        push_metrics(len(block), ok=False, drift=drift, fail_streak=streak,
                     backoff_until=backoff_until)
        return 1

    # The write landed: drift is closed and the ladder resets.
    push_metrics(len(block), ok=True, drift=0, fail_streak=0, backoff_until=0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
