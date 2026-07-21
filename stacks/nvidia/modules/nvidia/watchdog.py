#!/usr/bin/env python3
"""GPU VRAM watchdog — recycle the biggest OVER-BUDGET tenant under pressure.

Soft runtime enforcement of the per-tenant gpumem budget (ADR-0016). Loops:
  free = PHYSICAL_TOTAL - sum(gpu_pod_memory_used_bytes)
  if free >= FLOOR: nothing (tenants may burst into genuine slack)
  else: among GPU pods that DECLARE viktorbarzin.me/gpumem, find those whose
        actual use exceeds their declared budget, and recycle the biggest
        offender (its arena clears on restart). Contract enforcement, not
        priority — co-tenants often share the gpu-workload PriorityClass.

Pure helpers (parse_gpumem_quantity, select_offender) are import-safe with no
side effects so they can be unit-tested (watchdog_test.py); all env/token/SSL
I/O is initialised inside main().
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


def select_offender(used, budgets, free_mib, floor_mib):
    """Pick the tenant to recycle, or None.

    None when free VRAM is at/above the floor (tenants may burst into genuine
    slack) or when no declaring tenant is over its budget. Otherwise the
    biggest-overshoot over-budget tenant, as (overshoot, (ns,pod), used, budget).
    """
    if free_mib >= floor_mib:
        return None
    offenders = []
    for key, budget in budgets.items():
        u = used.get(key, 0.0)
        if u > budget:
            offenders.append((u - budget, key, u, budget))
    if not offenders:
        return None
    offenders.sort(reverse=True)
    return offenders[0]


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
    if free >= cfg["floor"]:
        return
    node = gpu_node(k8s, cfg["node_label"])
    if not node:
        print("PRESSURE but no GPU node found -> no action", flush=True)
        return
    budgets = declared_budgets(k8s, cfg["resource"], node)
    chosen = select_offender(used, budgets, free, cfg["floor"])
    if chosen is None:
        print(
            "PRESSURE but no tenant over its declared budget -> alert-only, no recycle",
            flush=True,
        )
        return
    overshoot, (ns, pod), u, budget = chosen
    print(
        "PRESSURE: recycling %s/%s (used=%.0fMiB > budget=%dMiB, overshoot=%.0fMiB)%s"
        % (ns, pod, u, budget, overshoot, " [DRY_RUN]" if cfg["dry_run"] else ""),
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
        "gpu-vram-watchdog starting (interval=%ss dry_run=%s floor=%dMiB)"
        % (cfg["interval"], cfg["dry_run"], cfg["floor"]),
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
