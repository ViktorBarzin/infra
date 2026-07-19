# =============================================================================
# Post-boot dependency-init reconcile — restart pods that MISSED Kyverno injection
# =============================================================================
# See memory #10050. The ClusterPolicy `inject-dependency-init-containers`
# (dependency-init-containers.tf) injects a busybox `wait-for-<host>`
# initContainer for every entry in a pod's `dependency.kyverno.io/wait-for`
# annotation, so the pod blocks until its DB/redis/etc. is reachable.
#
# That policy is CREATE-only (operations = ["CREATE"]) with failurePolicy=Ignore.
# So a pod created during a COLD BOOT — while the Kyverno admission webhook is
# still down — is admitted WITHOUT the initContainer and starts before its
# dependencies exist, then wedges (CrashLoop / stuck app) and never self-heals.
#
# This CronJob runs every 10 min and, ONLY once Kyverno is healthy again, deletes
# such wedged pods. Their controller recreates them; this time the (now-up)
# webhook injects the initContainer and they wait for their deps correctly.
#
# SAFETY (this controller DELETES pods cluster-wide):
#   1. GATE   — never act unless the Kyverno admission controller has >=1 ready
#               replica (else we'd loop-recreate un-injected pods). Any failure
#               to determine readiness is treated as "not ready" -> skip.
#   2. FLAG   — a pod is a candidate only if it DECLARES the annotation AND has NO
#               initContainer whose name starts with "wait-for-" (missed injection).
#   3. FILTER — skip unless owned (ownerReferences; never delete bare pods), not
#               already terminating, older than GRACE_SECONDS, phase Running/Pending.
#   4. SCOPE  — skip namespaces Kyverno itself excludes from admission
#               (SKIP_NAMESPACES; kube-system/kube-public/kube-node-lease/kyverno):
#               pods there can NEVER be injected, so deleting them loops forever.
#   5. CAP    — delete at most MAX_RESTARTS_PER_RUN per run; log + leave the rest.
#   6. DRY_RUN — log the delete it WOULD do without deleting.
#
# ROLLOUT: reconcile_dry_run defaults to TRUE — the job observes and logs
# "WOULD delete ..." without deleting. Watch a few runs + the pushed metrics,
# then flip reconcile_dry_run=false to arm. BEFORE arming, add
# `system:serviceaccount:kyverno:post-boot-reconcile` to the K8sMassDelete
# exclusion regex (stacks/monitoring/.../loki.tf) — done in the same change —
# else a >5-delete cold-boot recovery run trips that critical alert.
#
# Structure mirrors stacks/nvidia/modules/nvidia/gpu_memory_budget.tf. Pure-stdlib
# Python on stock python:3.12-alpine (no pip/apk at runtime). The in-cluster
# apiserver is reached via the mounted SA token + CA bundle; this pod runs in the
# `kyverno` namespace where cluster DNS works, so the default target is
# https://kubernetes.default.svc.
#
# NOTE (verified live 2026-07-19): the Pushgateway Service is
# `prometheus-prometheus-pushgateway.monitoring` (ClusterIP). The name
# `prometheus-pushgateway.monitoring.svc.cluster.local` is NXDOMAIN — do not use it.
# =============================================================================

variable "reconcile_grace_seconds" {
  type        = number
  default     = 300
  description = "A missed-injection pod is only eligible for deletion once it is older than this (now - creationTimestamp), so a just-created pod mid-startup is left alone."
}

variable "reconcile_max_restarts_per_run" {
  type        = number
  default     = 15
  description = "Max pods deleted per run; the rest are logged and left for the next run. NOTE: K8sMassDelete fires at >5 pod deletes/60s by one user; the SA is added to its exclusion regex in stacks/monitoring/.../loki.tf so a legit cold-boot recovery run does not trip it."
}

variable "reconcile_dry_run" {
  type        = bool
  default     = true
  description = "Default TRUE: the job logs the delete it WOULD do but does not delete. Observe a few runs, then set false to arm."
}

variable "reconcile_skip_namespaces" {
  type        = string
  default     = "kube-system,kube-public,kube-node-lease,kyverno"
  description = "Comma-separated namespaces excluded from deletion. Defaults to exactly the namespaces Kyverno excludes from admission (resourceFilters + webhook namespaceSelector) — pods there can never be injected, so deleting them would loop forever."
}

resource "kubernetes_service_account" "post_boot_reconcile" {
  metadata {
    name      = "post-boot-reconcile"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "post_boot_reconcile" {
  metadata { name = "post-boot-reconcile" }
  # Readiness gate — GET the Kyverno admission-controller Deployment.
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get"]
  }
  # List candidates cluster-wide + delete the wedged ones (the recycle). The
  # script only ever deletes an owned, aged, Running/Pending pod that declared
  # dependency.kyverno.io/wait-for yet has no wait-for-* initContainer, and only
  # while Kyverno is healthy.
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "post_boot_reconcile" {
  metadata { name = "post-boot-reconcile" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.post_boot_reconcile.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.post_boot_reconcile.metadata[0].name
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
}

resource "kubernetes_config_map" "post_boot_reconcile_script" {
  metadata {
    name      = "post-boot-reconcile-script"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
  data = {
    "reconcile.py" = <<-EOT
#!/usr/bin/env python3
"""post-boot-reconcile — restart pods that MISSED Kyverno dependency-init injection.

The ClusterPolicy `inject-dependency-init-containers` is CREATE-only +
failurePolicy=Ignore, so a pod created while the Kyverno webhook is down (cold
boot) starts WITHOUT its wait-for-<host> initContainer and wedges. This job, run
every 10 min, deletes such pods ONLY once Kyverno is healthy so their controller
recreates them and the now-up webhook injects the initContainer. Pure stdlib.
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

APISERVER = os.environ.get("APISERVER", "https://kubernetes.default.svc")
KYVERNO_NAMESPACE = os.environ.get("KYVERNO_NAMESPACE", "kyverno")
KYVERNO_DEPLOYMENT = os.environ.get("KYVERNO_DEPLOYMENT", "kyverno-admission-controller")
GRACE_SECONDS = int(os.environ.get("GRACE_SECONDS", "300"))
MAX_RESTARTS_PER_RUN = int(os.environ.get("MAX_RESTARTS_PER_RUN", "15"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
SKIP_NAMESPACES = {
    ns.strip()
    for ns in os.environ.get(
        "SKIP_NAMESPACES", "kube-system,kube-public,kube-node-lease,kyverno"
    ).split(",")
    if ns.strip()
}
PUSHGATEWAY_URL = os.environ.get(
    "PUSHGATEWAY_URL", "http://prometheus-prometheus-pushgateway.monitoring:9091"
)
PUSH_JOB = os.environ.get("PUSH_JOB", "post-boot-reconcile")
WAIT_FOR_ANNOTATION = "dependency.kyverno.io/wait-for"

TOKEN = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
_ctx = ssl.create_default_context(cafile=CA)


def api(method, path):
    req = urllib.request.Request(
        APISERVER + path,
        method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=_ctx, timeout=30) as r:
        body = r.read().decode()
    return json.loads(body) if body else None


def kyverno_ready():
    """Return the admission-controller ready replica count. On any error return 0
    (fail-safe: we never delete when Kyverno's health is unknown)."""
    path = "/apis/apps/v1/namespaces/%s/deployments/%s" % (
        KYVERNO_NAMESPACE,
        KYVERNO_DEPLOYMENT,
    )
    try:
        dep = api("GET", path) or {}
    except Exception as e:  # noqa: BLE001
        print("WARN: could not read %s/%s: %s -> treating as NOT ready"
              % (KYVERNO_NAMESPACE, KYVERNO_DEPLOYMENT, e), flush=True)
        return 0
    return int((dep.get("status", {}) or {}).get("readyReplicas", 0) or 0)


def list_pods():
    """Paginated list of non-terminal pods cluster-wide (Succeeded/Failed dropped
    server-side — they are never wedged and this bounds memory)."""
    items = []
    cont = ""
    fs = urllib.parse.quote("status.phase!=Succeeded,status.phase!=Failed")
    while True:
        path = "/api/v1/pods?limit=500&fieldSelector=" + fs
        if cont:
            path += "&continue=" + urllib.parse.quote(cont)
        page = api("GET", path) or {}
        items.extend(page.get("items", []))
        cont = (page.get("metadata", {}) or {}).get("continue", "")
        if not cont:
            break
    return items


def age_seconds(pod):
    ts = (pod.get("metadata", {}) or {}).get("creationTimestamp")
    if not ts:
        return 0.0
    created = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - created).total_seconds()


def missed_injection(pod):
    ann = ((pod.get("metadata", {}) or {}).get("annotations") or {}).get(
        WAIT_FOR_ANNOTATION, ""
    )
    if not ann.strip():
        return False
    inits = (pod.get("spec", {}) or {}).get("initContainers") or []
    return not any((c.get("name") or "").startswith("wait-for-") for c in inits)


def is_safe(pod):
    md = pod.get("metadata", {}) or {}
    if not md.get("ownerReferences"):
        return False, "no ownerReferences (bare pod)"
    if md.get("deletionTimestamp"):
        return False, "already terminating"
    if age_seconds(pod) <= GRACE_SECONDS:
        return False, "younger than grace (%ds)" % GRACE_SECONDS
    phase = (pod.get("status", {}) or {}).get("phase")
    if phase not in ("Running", "Pending"):
        return False, "phase=%s" % phase
    return True, "ok"


def push_metrics(restarted, found, ready, capped, success):
    lines = [
        "# TYPE post_boot_reconcile_restarted gauge",
        "post_boot_reconcile_restarted %d" % restarted,
        "# TYPE post_boot_reconcile_missed_found gauge",
        "post_boot_reconcile_missed_found %d" % found,
        "# TYPE post_boot_reconcile_kyverno_ready gauge",
        "post_boot_reconcile_kyverno_ready %d" % ready,
        "# TYPE post_boot_reconcile_capped gauge",
        "post_boot_reconcile_capped %d" % capped,
        "# TYPE post_boot_reconcile_success gauge",
        "post_boot_reconcile_success %d" % success,
        "# TYPE post_boot_reconcile_last_run_timestamp gauge",
        "post_boot_reconcile_last_run_timestamp %d" % int(time.time()),
    ]
    payload = ("\n".join(lines) + "\n").encode()
    url = "%s/metrics/job/%s" % (PUSHGATEWAY_URL, PUSH_JOB)
    req = urllib.request.Request(
        url, data=payload, method="PUT", headers={"Content-Type": "text/plain"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            r.read()
        print("pushed metrics restarted=%d found=%d ready=%d capped=%d success=%d"
              % (restarted, found, ready, capped, success), flush=True)
    except Exception as e:  # noqa: BLE001
        print("WARN: pushgateway PUT failed: %s" % e, flush=True)


def main():
    ready = kyverno_ready()
    if ready < 1:
        print("kyverno not ready (readyReplicas=%d), skipping" % ready, flush=True)
        push_metrics(restarted=0, found=0, ready=0, capped=0, success=1)
        return
    pods = list_pods()
    candidates = []
    found = 0
    for pod in pods:
        md = pod.get("metadata", {}) or {}
        ns, name = md.get("namespace", ""), md.get("name", "")
        if not missed_injection(pod):
            continue
        found += 1
        if ns in SKIP_NAMESPACES:
            print("SKIP %s/%s: namespace excluded from Kyverno admission "
                  "(injection can never happen here)" % (ns, name), flush=True)
            continue
        ok, reason = is_safe(pod)
        if not ok:
            print("SKIP %s/%s: %s" % (ns, name, reason), flush=True)
            continue
        candidates.append((ns, name))
    capped = 1 if len(candidates) > MAX_RESTARTS_PER_RUN else 0
    print("missed-injection found=%d delete-eligible=%d cap=%d%s"
          % (found, len(candidates), MAX_RESTARTS_PER_RUN,
             " [DRY_RUN]" if DRY_RUN else ""), flush=True)
    if capped:
        print("CAP: %d eligible > %d; deleting %d this run, leaving %d for next run"
              % (len(candidates), MAX_RESTARTS_PER_RUN, MAX_RESTARTS_PER_RUN,
                 len(candidates) - MAX_RESTARTS_PER_RUN), flush=True)
    restarted = 0
    for ns, name in candidates[:MAX_RESTARTS_PER_RUN]:
        if DRY_RUN:
            print("WOULD delete %s/%s (missed wait-for injection)" % (ns, name),
                  flush=True)
            continue
        try:
            api("DELETE", "/api/v1/namespaces/%s/pods/%s" % (ns, name))
            restarted += 1
            print("deleted %s/%s (missed wait-for injection; controller recreates "
                  "with initContainer)" % (ns, name), flush=True)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print("SKIP %s/%s: already gone (404)" % (ns, name), flush=True)
            else:
                print("ERROR deleting %s/%s: %s" % (ns, name, e), flush=True)
        except Exception as e:  # noqa: BLE001
            print("ERROR deleting %s/%s: %s" % (ns, name, e), flush=True)
    push_metrics(restarted=restarted, found=found, ready=1, capped=capped, success=1)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print("FATAL: %s" % e, file=sys.stderr, flush=True)
        try:
            push_metrics(restarted=0, found=0, ready=0, capped=0, success=0)
        except Exception:  # noqa: BLE001
            pass
        sys.exit(1)
EOT
  }
}

resource "kubernetes_cron_job_v1" "post_boot_reconcile" {
  metadata {
    name      = "post-boot-reconcile"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
    labels    = { app = "post-boot-reconcile" }
  }
  spec {
    schedule                      = "*/10 * * * *"
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 300
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    job_template {
      metadata { labels = { app = "post-boot-reconcile" } }
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 240
        ttl_seconds_after_finished = 300
        template {
          metadata { labels = { app = "post-boot-reconcile" } }
          spec {
            service_account_name = kubernetes_service_account.post_boot_reconcile.metadata[0].name
            restart_policy       = "OnFailure"
            container {
              name    = "reconcile"
              image   = "python:3.12-alpine"
              command = ["python3", "/scripts/reconcile.py"]
              env {
                name  = "GRACE_SECONDS"
                value = tostring(var.reconcile_grace_seconds)
              }
              env {
                name  = "MAX_RESTARTS_PER_RUN"
                value = tostring(var.reconcile_max_restarts_per_run)
              }
              env {
                name  = "DRY_RUN"
                value = tostring(var.reconcile_dry_run)
              }
              env {
                name  = "SKIP_NAMESPACES"
                value = var.reconcile_skip_namespaces
              }
              env {
                name  = "KYVERNO_NAMESPACE"
                value = kubernetes_namespace.kyverno.metadata[0].name
              }
              env {
                name  = "KYVERNO_DEPLOYMENT"
                value = "kyverno-admission-controller"
              }
              env {
                # Verified live: the Service is prometheus-prometheus-pushgateway
                # (NOT prometheus-pushgateway, which is NXDOMAIN).
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = { cpu = "10m", memory = "128Mi" }
                limits   = { memory = "256Mi" }
              }
            }
            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map.post_boot_reconcile_script.metadata[0].name
                default_mode = "0755"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_cluster_role_binding.post_boot_reconcile]
}
