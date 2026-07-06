# =============================================================================
# GPU VRAM protection — scheduler extended-resource budget + runtime watchdog
# =============================================================================
# See docs/adr/0016-gpu-vram-extended-resource-budget.md. The T4 is time-sliced
# (nvidia.com/gpu = a scheduling turn, NOT memory), so the scheduler is blind to
# VRAM and tenants can overallocate the card (post-mortem 2026-06-02: immich-ml's
# onnxruntime arena 2->10.7 GiB starved llama-swap). MIG is impossible on Turing;
# HAMi/MPS were rejected (ADR-0016). Instead, two repo-native layers, NO
# device-plugin/driver change, time-slicing untouched:
#   1. Budget  — advertise a node extended resource `viktorbarzin.me/gpumem`;
#                each GPU tenant declares resources.limits gpumem; the scheduler
#                refuses to co-schedule past the card (overflow -> Pending).
#   2. Watchdog — when ACTUAL free VRAM < floor, recycle the biggest tenant that
#                is OVER its declared budget (contract enforcement; the teeth the
#                schedule-time budget lacks).
# =============================================================================

variable "gpumem_resource" {
  type        = string
  default     = "viktorbarzin.me/gpumem"
  description = "Custom node extended-resource name advertised for GPU memory budgeting (integer MiB)."
}

variable "gpumem_total_mib" {
  type        = number
  default     = 14000
  description = "Schedulable GPU-memory budget advertised on the GPU node = ~15360 MiB physical minus ~1.4 GiB driver/CUDA-context/exporter slack. Sum of all tenants' declared gpumem must stay <= this."
}

variable "watchdog_gpu_total_mib" {
  type        = number
  default     = 15360
  description = "PHYSICAL T4 framebuffer (MiB). The watchdog computes free = this - sum(gpu_pod_memory_used_bytes); distinct from gpumem_total_mib (the scheduler budget)."
}

variable "watchdog_floor_mib" {
  type        = number
  default     = 1536
  description = "The watchdog acts only when actual free VRAM drops below this floor (genuine pressure), so a tenant may burst into real slack without being recycled."
}

variable "watchdog_dry_run" {
  type        = bool
  default     = true
  description = "When true the watchdog logs the recycle it WOULD do but does not delete the pod. Ships true (observe-then-enforce); flip to false once a few cycles look right."
}

locals {
  gpumem_json_pointer = "/status/capacity/${replace(var.gpumem_resource, "/", "~1")}"
}

# --- 1a. Advertise the extended resource at apply time (immediate) ------------
# Mirrors the gpu_node_config null_resource (local-exec kubectl). Runs from the
# apply environment, dynamic over GPU-labelled nodes so it follows the card.
# `op:add` on an existing key replaces -> idempotent. wait/ordering: this MUST
# succeed before any consumer stack declares gpumem, or those pods are
# unschedulable (extended resource not advertised by any node).
resource "null_resource" "advertise_gpumem" {
  provisioner "local-exec" {
    # bash, not the default /bin/sh: dash (Ubuntu sh) rejects `set -o pipefail`
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      for node in $(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}'); do
        echo "advertising ${var.gpumem_resource}=${var.gpumem_total_mib} on $node"
        kubectl patch node "$node" --subresource=status --type=json \
          -p="[{\"op\":\"add\",\"path\":\"${local.gpumem_json_pointer}\",\"value\":\"${var.gpumem_total_mib}\"}]"
      done
    EOT
  }
  triggers = {
    gpumem_total = var.gpumem_total_mib
    resource     = var.gpumem_resource
    command_hash = "advertise-gpumem-v1"
  }
  depends_on = [helm_release.nvidia-gpu-operator]
}

# --- 1b. Re-assert the extended resource periodically (drift / node rejoin) ---
# A node object that is deleted + re-registered loses manually-advertised
# extended resources. Hourly re-assert (low churn; node rejoin is rare).
resource "kubernetes_service_account" "gpumem_reconcile" {
  metadata {
    name      = "gpumem-reconcile"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "gpumem_reconcile" {
  metadata { name = "gpumem-reconcile" }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes/status"]
    verbs      = ["get", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding" "gpumem_reconcile" {
  metadata { name = "gpumem-reconcile" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.gpumem_reconcile.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gpumem_reconcile.metadata[0].name
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "gpumem_reconcile" {
  metadata {
    name      = "gpumem-reconcile"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels    = { app = "gpumem-reconcile", tier = var.tier }
  }
  spec {
    schedule                      = "0 * * * *" # hourly re-assert
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    job_template {
      metadata { labels = { app = "gpumem-reconcile" } }
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata { labels = { app = "gpumem-reconcile" } }
          spec {
            service_account_name = kubernetes_service_account.gpumem_reconcile.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "reconcile"
              image   = "bitnami/kubectl:latest"
              command = ["/bin/bash", "-c"]
              args = [<<-EOT
                set -euo pipefail
                for node in $(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}'); do
                  echo "re-asserting ${var.gpumem_resource}=${var.gpumem_total_mib} on $node"
                  kubectl patch node "$node" --subresource=status --type=json \
                    -p="[{\"op\":\"add\",\"path\":\"${local.gpumem_json_pointer}\",\"value\":\"${var.gpumem_total_mib}\"}]"
                done
              EOT
              ]
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "64Mi" }
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
  depends_on = [null_resource.advertise_gpumem]
}

# --- 2. Watchdog: recycle the biggest over-budget tenant under VRAM pressure --
resource "kubernetes_config_map" "gpu_vram_watchdog_script" {
  metadata {
    name      = "gpu-vram-watchdog-script"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
  data = {
    "watchdog.py" = <<-EOT
#!/usr/bin/env python3
"""GPU VRAM watchdog — recycle the biggest OVER-BUDGET tenant under pressure.

Soft runtime enforcement of the per-tenant gpumem budget (ADR-0016). Loops:
  free = PHYSICAL_TOTAL - sum(gpu_pod_memory_used_bytes)
  if free >= FLOOR: nothing (tenants may burst into genuine slack)
  else: among GPU pods that DECLARE viktorbarzin.me/gpumem, find those whose
        actual use exceeds their declared budget, and recycle the biggest
        offender (its arena clears on restart). Contract enforcement, not
        priority — co-tenants often share the gpu-workload PriorityClass.
"""
import json
import os
import ssl
import time
import urllib.parse
import urllib.request

RESOURCE = os.environ["GPUMEM_RESOURCE"]
PHYSICAL_TOTAL_MIB = int(os.environ["GPU_TOTAL_MIB"])
FLOOR_MIB = int(os.environ["FLOOR_MIB"])
INTERVAL = int(os.environ.get("CHECK_INTERVAL_SECONDS", "60"))
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
EXPORTER = os.environ.get(
    "EXPORTER_URL", "http://gpu-pod-exporter.nvidia.svc.cluster.local:80/metrics"
)
GPU_NODE_LABEL = "nvidia.com/gpu.present=true"

# nvidia-ns cluster DNS is broken (getaddrinfo fails for kubernetes.default.svc
# and *.svc.cluster.local from every nvidia pod — not a NetworkPolicy; 2026-07-06),
# so reach the apiserver by the always-injected KUBERNETES_SERVICE_HOST ClusterIP
# (its cert SAN 10.96.0.1 verifies against the mounted cluster CA) instead of DNS.
K8S = "https://" + os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc") + ":" + os.environ.get("KUBERNETES_SERVICE_PORT", "443")
TOKEN = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
_ctx = ssl.create_default_context(cafile=CA)
MIB = 1024 * 1024


def api(method, path):
    req = urllib.request.Request(
        K8S + path,
        method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=_ctx, timeout=15) as r:
        return json.loads(r.read().decode()) if method == "GET" else None


def scrape_used_mib():
    """Return {(namespace, pod): used_mib} from the host-PID exporter."""
    try:
        with urllib.request.urlopen(EXPORTER, timeout=10) as r:
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


def gpu_node():
    items = api(
        "GET", "/api/v1/nodes?labelSelector=" + urllib.parse.quote(GPU_NODE_LABEL)
    ).get("items", [])
    return items[0]["metadata"]["name"] if items else None


def declared_budgets(node):
    """Return {(namespace, pod): declared_gpumem_mib} for pods on the GPU node."""
    pods = api("GET", "/api/v1/pods?fieldSelector=spec.nodeName=" + node).get(
        "items", []
    )
    budgets = {}
    for p in pods:
        ns = p["metadata"]["namespace"]
        name = p["metadata"]["name"]
        total = 0
        for c in p["spec"].get("containers", []):
            v = c.get("resources", {}).get("limits", {}).get(RESOURCE)
            if v is not None:
                try:
                    total += int(v)
                except ValueError:
                    pass
        if total:
            budgets[(ns, name)] = total
    return budgets


def tick():
    used = scrape_used_mib()
    if used is None:
        return  # fail-safe: no metrics -> no action
    total_used = sum(used.values())
    free = PHYSICAL_TOTAL_MIB - total_used
    print(
        "VRAM used=%.0fMiB free=%.0fMiB floor=%dMiB total=%dMiB"
        % (total_used, free, FLOOR_MIB, PHYSICAL_TOTAL_MIB),
        flush=True,
    )
    if free >= FLOOR_MIB:
        return
    node = gpu_node()
    if not node:
        print("PRESSURE but no GPU node found -> no action", flush=True)
        return
    budgets = declared_budgets(node)
    offenders = []
    for key, budget in budgets.items():
        u = used.get(key, 0.0)
        if u > budget:
            offenders.append((u - budget, key, u, budget))
    if not offenders:
        print(
            "PRESSURE but no tenant over its declared budget -> alert-only, no recycle",
            flush=True,
        )
        return
    offenders.sort(reverse=True)
    overshoot, (ns, pod), u, budget = offenders[0]
    print(
        "PRESSURE: recycling %s/%s (used=%.0fMiB > budget=%dMiB, overshoot=%.0fMiB)%s"
        % (ns, pod, u, budget, overshoot, " [DRY_RUN]" if DRY_RUN else ""),
        flush=True,
    )
    if DRY_RUN:
        return
    try:
        api("DELETE", "/api/v1/namespaces/%s/pods/%s" % (ns, pod))
        print("recycled %s/%s" % (ns, pod), flush=True)
    except Exception as e:  # noqa: BLE001
        print("ERROR deleting %s/%s: %s" % (ns, pod, e), flush=True)


if __name__ == "__main__":
    print(
        "gpu-vram-watchdog starting (interval=%ss dry_run=%s floor=%dMiB)"
        % (INTERVAL, DRY_RUN, FLOOR_MIB),
        flush=True,
    )
    while True:
        try:
            tick()
        except Exception as e:  # noqa: BLE001
            print("ERROR in tick: %s" % e, flush=True)
        time.sleep(INTERVAL)
EOT
  }
}

resource "kubernetes_service_account" "gpu_vram_watchdog" {
  metadata {
    name      = "gpu-vram-watchdog"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "gpu_vram_watchdog" {
  metadata { name = "gpu-vram-watchdog" }
  rule {
    # find the GPU node — GET /api/v1/nodes?labelSelector=nvidia.com/gpu.present=true
    # (first api() call every tick; missing since ADR-0016, masked by the broken DNS)
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  # delete = the recycle. Broad (cluster-wide) but the script only ever targets
  # a GPU-node pod that is over its declared gpumem budget under VRAM pressure.
  # Far less privileged than existing cluster-admin tooling (woodpecker-agent).
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["delete"]
  }
}

resource "kubernetes_cluster_role_binding" "gpu_vram_watchdog" {
  metadata { name = "gpu-vram-watchdog" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.gpu_vram_watchdog.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gpu_vram_watchdog.metadata[0].name
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
}

# Long-running Deployment with an internal sleep loop (NOT an every-minute
# CronJob) to avoid etcd pod-churn — one pod, the gpu-pod-exporter pattern.
resource "kubernetes_deployment" "gpu_vram_watchdog" {
  metadata {
    name      = "gpu-vram-watchdog"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels    = { app = "gpu-vram-watchdog", tier = var.tier }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "gpu-vram-watchdog" } }
    strategy { type = "Recreate" }
    template {
      metadata { labels = { app = "gpu-vram-watchdog" } }
      spec {
        service_account_name = kubernetes_service_account.gpu_vram_watchdog.metadata[0].name
        container {
          name    = "watchdog"
          image   = "python:3.12-alpine"
          command = ["python3", "/scripts/watchdog.py"]
          env {
            name  = "GPUMEM_RESOURCE"
            value = var.gpumem_resource
          }
          env {
            name  = "GPU_TOTAL_MIB"
            value = tostring(var.watchdog_gpu_total_mib)
          }
          env {
            name  = "FLOOR_MIB"
            value = tostring(var.watchdog_floor_mib)
          }
          env {
            name  = "DRY_RUN"
            value = tostring(var.watchdog_dry_run)
          }
          env {
            # Same broken nvidia-ns DNS as K8S above — target the exporter by its
            # stable ClusterIP instead of the DNS name the script defaults to, so
            # scrape_used_mib() works (per-pod VRAM attribution) without resolution.
            name  = "EXPORTER_URL"
            value = "http://${kubernetes_service.gpu_pod_exporter.spec[0].cluster_ip}:80/metrics"
          }
          volume_mount {
            name       = "script"
            mount_path = "/scripts"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "96Mi" }
            limits   = { memory = "128Mi" }
          }
        }
        volume {
          name = "script"
          config_map {
            name         = kubernetes_config_map.gpu_vram_watchdog_script.metadata[0].name
            default_mode = "0755"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_cluster_role_binding.gpu_vram_watchdog]
}
