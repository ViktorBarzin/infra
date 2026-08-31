#!/usr/bin/env python3
"""GPU VRAM watchdog — recycle the biggest OVER-BUDGET tenant under contention.

Soft runtime enforcement of the per-tenant gpumem budget (ADR-0016). Loops:
  1. who is over contract? among GPU pods that DECLARE viktorbarzin.me/gpumem,
     find those whose actual use exceeds their declared budget.
  2. does anyone actually WANT the card right now?
       - a declaring tenant sits Pending on gpumem, or
       - a seatless tenant hit CUDA OOM (Loki alert via Alertmanager), or
       - free VRAM fell under FLOOR_MIB (emergency backstop).
  3. if both, recycle the biggest offender (its arena clears on restart).
     Contract enforcement, not priority — co-tenants often share the
     gpu-workload PriorityClass.

Why contention and not free space alone (changed 2026-08-31): a free-space
trigger cannot tell "this tenant has retained garbage" from "this tenant is
doing legitimately large work". immich-ml's onnxruntime BFC arena ratchets
upward with the size of the job and never releases, so a batch whose real
working set exceeds its budget would be recycled, retried, and recycled again
without ever finishing. Waiting for evidence that something else is blocked
keeps the burst-into-slack behaviour ADR-0016 deliberately allowed.

The CUDA-OOM signal exists because the tenants most likely to be starved carry
no seat to go Pending on: llama-swap declares no gpumem by design and fails
inside an already-running pod, and frigate fails the same way. The Loki ruler
already watches those log lines; this reads the resulting alert from
Alertmanager rather than querying Loki, so the guard's only dependencies stay
HTTP endpoints it can reach by ClusterIP.

Pure helpers (parse_gpumem_quantity, select_offender, contention_reason,
parse_pending_gpumem, parse_cuda_oom_alerts) are import-safe with no side
effects so they can be unit-tested (watchdog_test.py); all env/token/SSL I/O is
initialised inside main().
"""
import json
import os
import ssl
import time
import urllib.parse
import urllib.request

MIB = 1024 * 1024

# Kubernetes canonicalises resource quantities, so an integer gpumem like 5000
# comes back from the API as "5k" (and 2000->"2k", 14000->"14k"). A bare int()
# on that raises ValueError; the old code caught + dropped it, silently
# excluding every round-thousand tenant from the offender set. Parse the full
# quantity grammar (decimal-SI k/M/G/T + binary Ki/Mi/Gi/Ti + bare integer).
_SUFFIX_MULT = {
    "": 1,
    "k": 10**3, "M": 10**6, "G": 10**9, "T": 10**12,
    "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40,
}


def parse_gpumem_quantity(v):
    """Parse a Kubernetes quantity string to its integer value, or None.

    "1800"->1800, "5k"->5000, "14k"->14000, "1Ki"->1024, "2Mi"->2097152.
    Malformed / unsupported (e.g. milli "m", empty, None) -> None.
    """
    if v is None:
        return None
    s = str(v).strip()
    if not s:
        return None
    i = 0
    while i < len(s) and (s[i].isdigit() or s[i] in ".+-"):
        i += 1
    num, suffix = s[:i], s[i:]
    if not num:
        return None
    mult = _SUFFIX_MULT.get(suffix)
    if mult is None:
        return None
    try:
        return int(float(num) * mult)
    except ValueError:
        return None


def select_offender(used, budgets):
    """Pick the biggest over-budget tenant, or None if everyone is within budget.

    Answers "who is over contract", not "should we act" — that is
    contention_reason()'s job. Only tenants that DECLARE a budget can be
    offenders: a seatless tenant (llama-swap) has no contract to breach and is
    never a target no matter how much it uses.

    Returns (overshoot, (ns, pod), used, budget).
    """
    offenders = []
    for key, budget in budgets.items():
        u = used.get(key, 0.0)
        if u > budget:
            offenders.append((u - budget, key, u, budget))
    if not offenders:
        return None
    offenders.sort(reverse=True)
    return offenders[0]


def contention_reason(free_mib, floor_mib, pending, cuda_oom):
    """Why we should reclaim VRAM now, or None to let a tenant keep bursting.

    Checked in order of directness: a pod the scheduler could not place, then a
    tenant that failed a CUDA allocation, then the emergency floor. The floor
    stays as a backstop so a starvation that produces neither signal still
    self-heals.
    """
    if pending:
        return "pending on gpumem: %s" % ", ".join(sorted(pending))
    if cuda_oom:
        return "cuda-oom reported in: %s" % ", ".join(sorted(cuda_oom))
    if free_mib < floor_mib:
        return "free %.0fMiB below emergency floor %dMiB" % (free_mib, floor_mib)
    return None


def parse_pending_gpumem(payload, resource):
    """Return {"ns/pod"} for pods the scheduler rejected for want of `resource`.

    The scheduler reports this as a PodScheduled=False/Unschedulable condition
    whose message names the resource, e.g.
    "0/6 nodes are available: 1 Insufficient viktorbarzin.me/gpumem."
    """
    out = set()
    for p in (payload or {}).get("items", []):
        status = p.get("status") or {}
        if status.get("phase") != "Pending":
            continue
        for c in status.get("conditions") or []:
            if c.get("type") != "PodScheduled" or c.get("status") != "False":
                continue
            if resource in (c.get("message") or ""):
                md = p.get("metadata") or {}
                ns, name = md.get("namespace"), md.get("name")
                if ns and name:
                    out.add("%s/%s" % (ns, name))
    return out


def parse_cuda_oom_alerts(payload, alertname):
    """Return the set of namespaces with an ACTIVE `alertname` in Alertmanager.

    Suppressed (inhibited/silenced) and resolved alerts are not evidence that
    something is being starved right now, so only "active" counts.
    """
    out = set()
    for a in payload or []:
        labels = a.get("labels") or {}
        if labels.get("alertname") != alertname:
            continue
        if ((a.get("status") or {}).get("state")) != "active":
            continue
        ns = labels.get("namespace")
        if ns:
            out.add(ns)
    return out


def api(k8s, method, path):
    base, token, ctx = k8s
    req = urllib.request.Request(
        base + path,
        method=method,
        headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
        return json.loads(r.read().decode()) if method == "GET" else None


def scrape_used_mib(exporter_url):
    """Return {(namespace, pod): used_mib} from the host-PID exporter, or None."""
    try:
        with urllib.request.urlopen(exporter_url, timeout=10) as r:
            text = r.read().decode()
    except Exception as e:  # noqa: BLE001
        print("WARN: exporter scrape failed: %s" % e, flush=True)
        return None
    used = {}
    for line in text.splitlines():
        if not line.startswith("gpu_pod_memory_used_bytes{"):
            continue
        labels = line[line.index("{") + 1 : line.index("}")]
        try:
            val = float(line.rsplit(" ", 1)[1])
        except ValueError:
            continue
        d = {}
        for kv in labels.split(","):
            if "=" in kv:
                k, v = kv.split("=", 1)
                d[k] = v.strip('"')
        key = (d.get("namespace"), d.get("pod"))
        used[key] = used.get(key, 0.0) + val / MIB
    return used


def fetch_active_alerts(alertmanager_url):
    """Return Alertmanager's alert list, or None if it could not be read.

    None is distinct from []: the caller must not treat "we could not ask" as
    "nothing is starved".
    """
    try:
        with urllib.request.urlopen(alertmanager_url, timeout=10) as r:
            return json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001
        print("WARN: alertmanager read failed: %s" % e, flush=True)
        return None


def gpu_node(k8s, node_label):
    items = api(
        k8s, "GET", "/api/v1/nodes?labelSelector=" + urllib.parse.quote(node_label)
    ).get("items", [])
    return items[0]["metadata"]["name"] if items else None


def declared_budgets(k8s, resource, node):
    """Return {(namespace, pod): declared_gpumem_mib} for pods on the GPU node."""
    pods = api(k8s, "GET", "/api/v1/pods?fieldSelector=spec.nodeName=" + node).get(
        "items", []
    )
    budgets = {}
    for p in pods:
        ns = p["metadata"]["namespace"]
        name = p["metadata"]["name"]
        total = 0
        for c in p["spec"].get("containers", []):
            v = c.get("resources", {}).get("limits", {}).get(resource)
            mib = parse_gpumem_quantity(v)
            if mib is not None:
                total += mib
        if total:
            budgets[(ns, name)] = total
    return budgets


def tick(cfg, k8s):
    used = scrape_used_mib(cfg["exporter"])
    if used is None:
        return  # fail-safe: no metrics -> no action
    total_used = sum(used.values())
    free = cfg["total"] - total_used
    print(
        "VRAM used=%.0fMiB free=%.0fMiB floor=%dMiB total=%dMiB"
        % (total_used, free, cfg["floor"], cfg["total"]),
        flush=True,
    )
    node = gpu_node(k8s, cfg["node_label"])
    if not node:
        print("no GPU node found -> no action", flush=True)
        return

    # Step 1: who is over contract? Cheap, and usually nobody.
    budgets = declared_budgets(k8s, cfg["resource"], node)
    chosen = select_offender(used, budgets)
    if chosen is None:
        return

    # Step 2: does anything actually want the card? Only ask once we know there
    # IS an offender, so a healthy card costs one exporter scrape and two API
    # reads per tick rather than an Alertmanager round-trip as well.
    pods = api(k8s, "GET", "/api/v1/pods?fieldSelector=spec.nodeName=" + node)
    pending = parse_pending_gpumem(pods, cfg["resource"])
    alerts = fetch_active_alerts(cfg["alertmanager"])
    if alerts is None:
        # Could not ask. Fall back to the floor alone rather than assuming calm.
        cuda_oom = set()
    else:
        cuda_oom = parse_cuda_oom_alerts(alerts, cfg["cuda_oom_alertname"])

    reason = contention_reason(free, cfg["floor"], pending, cuda_oom)
    overshoot, (ns, pod), u, budget = chosen
    if reason is None:
        print(
            "%s/%s over budget (used=%.0fMiB > %dMiB) but nothing is blocked "
            "-> allowing the burst, no recycle" % (ns, pod, u, budget),
            flush=True,
        )
        return
    print(
        "CONTENTION (%s): recycling %s/%s "
        "(used=%.0fMiB > budget=%dMiB, overshoot=%.0fMiB)%s"
        % (reason, ns, pod, u, budget, overshoot,
           " [DRY_RUN]" if cfg["dry_run"] else ""),
        flush=True,
    )
    if cfg["dry_run"]:
        return
    try:
        api(k8s, "DELETE", "/api/v1/namespaces/%s/pods/%s" % (ns, pod))
        print("recycled %s/%s" % (ns, pod), flush=True)
    except Exception as e:  # noqa: BLE001
        print("ERROR deleting %s/%s: %s" % (ns, pod, e), flush=True)


def _load_config():
    return {
        "resource": os.environ["GPUMEM_RESOURCE"],
        "total": int(os.environ["GPU_TOTAL_MIB"]),
        "floor": int(os.environ["FLOOR_MIB"]),
        "interval": int(os.environ.get("CHECK_INTERVAL_SECONDS", "60")),
        "dry_run": os.environ.get("DRY_RUN", "true").lower() == "true",
        "exporter": os.environ.get(
            "EXPORTER_URL",
            "http://gpu-pod-exporter.nvidia.svc.cluster.local:80/metrics",
        ),
        # Same broken nvidia-ns DNS as K8S/EXPORTER: pass a ClusterIP from TF.
        "alertmanager": os.environ.get(
            "ALERTMANAGER_URL",
            "http://prometheus-alertmanager.monitoring.svc.cluster.local:80"
            "/api/v2/alerts",
        ),
        "cuda_oom_alertname": os.environ.get("CUDA_OOM_ALERTNAME", "GpuCudaOom"),
        "node_label": "nvidia.com/gpu.present=true",
    }


def _connect_k8s():
    # nvidia-ns cluster DNS is broken (getaddrinfo fails for kubernetes.default.svc
    # and *.svc.cluster.local from every nvidia pod — not a NetworkPolicy; 2026-07-06),
    # so reach the apiserver by the always-injected KUBERNETES_SERVICE_HOST ClusterIP
    # (its cert SAN 10.96.0.1 verifies against the mounted cluster CA) instead of DNS.
    host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    base = "https://" + host + ":" + port
    token = open(
        "/var/run/secrets/kubernetes.io/serviceaccount/token"
    ).read().strip()
    ctx = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    )
    return base, token, ctx


def main():
    cfg = _load_config()
    k8s = _connect_k8s()
    print(
        "gpu-vram-watchdog starting (interval=%ss dry_run=%s emergency_floor=%dMiB "
        "contention=pending+%s) "
        % (cfg["interval"], cfg["dry_run"], cfg["floor"], cfg["cuda_oom_alertname"]),
        flush=True,
    )
    while True:
        try:
            tick(cfg, k8s)
        except Exception as e:  # noqa: BLE001
            print("ERROR in tick: %s" % e, flush=True)
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    main()
