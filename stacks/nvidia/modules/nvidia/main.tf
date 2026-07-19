variable "tls_secret_name" {}
variable "tier" { type = string }

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.nvidia.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "nvidia" {
  metadata {
    name = "nvidia"
    labels = {
      "istio-injection" : "disabled"
      tier                                    = var.tier
      "resource-governance/custom-quota"      = "true"
      "resource-governance/custom-limitrange" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Custom LimitRange — overrides Kyverno tier-2-gpu default (1Gi per container)
# which was inflating NVIDIA operator init container requests by ~2.5Gi total.
# Init containers do quick validation checks and need minimal memory.
resource "kubernetes_limit_range" "nvidia_defaults" {
  metadata {
    name      = "tier-defaults"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "128Mi"
      }
      default_request = {
        cpu    = "50m"
        memory = "128Mi"
      }
      max = {
        memory = "16Gi"
      }
    }
  }
}

resource "kubernetes_resource_quota" "nvidia_quota" {
  metadata {
    name      = "tier-quota"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
  spec {
    hard = {
      "limits.memory"   = "48Gi"
      "requests.cpu"    = "8"
      "requests.memory" = "12Gi"
      pods              = "40"
    }
  }
}

# Apply GPU taint dynamically based on NFD-discovered GPU nodes. The
# NFD label `feature.node.kubernetes.io/pci-10de.present=true` is
# auto-applied on any node with an NVIDIA PCI device (vendor 0x10de),
# so the taint follows the card if it moves between nodes. Workload
# nodeSelectors key off `nvidia.com/gpu.present=true` (applied by
# gpu-feature-discovery once the operator is up).
resource "null_resource" "gpu_node_config" {
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      for node in $(kubectl get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{.items[*].metadata.name}'); do
        # `kubectl taint --overwrite` keys on key+EFFECT, so setting NoSchedule
        # does NOT replace an existing nvidia.com/gpu:PreferNoSchedule taint —
        # they'd COEXIST (both effects on the node). Remove any stale
        # PreferNoSchedule first, then set NoSchedule. Both idempotent.
        kubectl taint nodes "$node" nvidia.com/gpu:PreferNoSchedule- 2>/dev/null || true
        kubectl taint nodes "$node" nvidia.com/gpu=true:NoSchedule --overwrite
      done
    EOT
  }

  # reboot-self-heal Phase 2 (code-j3tx): flipped PreferNoSchedule -> NoSchedule
  # so non-GPU pods CANNOT pack the GPU node on a reboot reschedule and starve
  # frigate/llama-swap (the 2026-07-18 ~3h Pending). NoSchedule does NOT evict
  # running pods — it only shapes future scheduling — so this is safe to apply
  # live; it takes effect on the next reschedule/reboot. PREREQUISITE (done): the
  # 8 non-tolerating system DaemonSets gained an nvidia.com/gpu toleration first
  # (proxmox-csi-node etc.), else NoSchedule would keep them off node1. GPU
  # tenants + those DaemonSets tolerate; everything else (immich-postgresql,
  # CNPG, authentik, ...) has no gpu toleration so NoSchedule alone excludes it
  # (dedicated anti-affinity would be redundant — omitted).
  triggers = {
    namespace    = kubernetes_namespace.nvidia.metadata[0].name
    command_hash = "dynamic-taint-v3-noschedule-remove-prefer"
  }
}

# [not needed anymore; part of the chart values] Apply to operator with:
# kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'

resource "kubernetes_config_map" "time_slicing_config" {
  metadata {
    name      = "time-slicing-config"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }

  data = {
    any = <<-EOF
      flags:
        migStrategy: none
      sharing:
        timeSlicing:
          renameByDefault: false
          failRequestsGreaterThanOne: false
          resources:
            - name: nvidia.com/gpu
              replicas: 100
    EOF
  }
  depends_on = [kubernetes_namespace.nvidia]
}

resource "helm_release" "nvidia-gpu-operator" {
  namespace = kubernetes_namespace.nvidia.metadata[0].name
  name      = "nvidia-gpu-operator"

  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  atomic     = true
  # Pinned 2026-05-17. v26.3.1's operator auto-detects the host OS via NFD
  # and constructs `driver:<version>-ubuntu26.04` image tags, but NVIDIA
  # has not published any ubuntu26.04 driver images yet. v25.10.1 falls
  # back to ubuntu24.04 (which exists), so we stay here until NVIDIA ships
  # 26.04 builds (or until the host kernel is rolled back to a 24.04 line
  # one). See post-mortem 2026-05-17-gpu-driver-ubuntu2604-mismatch.md.
  version = "v25.10.1"
  timeout = 6000

  values     = [templatefile("${path.module}/values.yaml", {})]
  depends_on = [kubernetes_config_map.time_slicing_config]
}

# CONSOLIDATED 2026-07-18 (Viktor: "fix the nvidia issues, consolidate tf"):
# the standalone `nvidia-exporter` dcgm-exporter Deployment was REMOVED. It was
# redundant with the GPU-operator's own `nvidia-dcgm-exporter` (both dcgm-exporter
# on the same time-sliced T4) and crashlooped fighting over DCGM's exclusive
# profiling module after the 2026-07-18 reboot changed init order
# ("Profiling module returned an unrecoverable error"; post-mortem
# docs/post-mortems/2026-07-18-sofia-power-outage-unclean-shutdown.md, bead
# code-9d5p). The Service below now points at the operator's dcgm-exporter pods
# (app=nvidia-dcgm-exporter, :9400), which serve the same device-level metrics
# incl. the four HA-Sofia tesla_t4_gpu_* fields (GPU_TEMP/POWER_USAGE/GPU_UTIL/
# FB_USED, verified live). The Service + ingress keep the stable endpoint so the
# HA REST sensors + the Prometheus scrape need no repointing.

resource "kubernetes_service" "nvidia-exporter" {
  metadata {
    name      = "nvidia-exporter"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels = {
      "app" = "nvidia-exporter"
    }
  }

  spec {
    # Points at the GPU-operator's dcgm-exporter pods (see consolidation note
    # above), not a standalone deployment. Overlapping the operator's own
    # Service selector is fine — a pod can back multiple Services.
    selector = {
      app = "nvidia-dcgm-exporter"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 9400
    }
  }
}


module "ingress" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # Auth disabled — HA Sofia REST sensors poll /metrics; the OIDC flow
  # would 302 every request. Same pattern as idrac-redfish-exporter +
  # snmp-exporter (commit 5c594291).
  # auth = "none": HA Sofia REST sensors poll /metrics programmatically; OIDC flow would 302 every request breaking automation.
  auth                    = "none"
  namespace               = kubernetes_namespace.nvidia.metadata[0].name
  name                    = "nvidia-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  extra_annotations = {
    "gethomepage.dev/icon" = "nvidia.png"
  }
}

# resource "kubernetes_ingress_v1" "nvidia-exporter" {
#   metadata {
#     name      = "nvidia-exporter"
#    namespace = kubernetes_namespace.nvidia.metadata[0].name
#     annotations = {
#       "kubernetes.io/ingress.class" = "nginx"
#       "nginx.ingress.kubernetes.io/whitelist-source-range" : "192.168.1.0/24, 10.0.0.0/8"
#       "nginx.ingress.kubernetes.io/ssl-redirect" : "false" # used only in LAN

#     }
#   }
#   spec {
#     tls {
#       hosts       = ["nvidia-exporter.viktorbarzin.lan"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "nvidia-exporter.viktorbarzin.lan"
#       http {
#         path {
#           backend {
#             service {
#               name = "nvidia-exporter"
#               port {
#                 number = 80
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }


# resource "kubernetes_deployment" "gpu-container" {
#   metadata {
#     name      = "gpu-container"
#     namespace = kubernetes_namespace.nvidia.metadata[0].name
#     labels = {
#       app = "gpu-container"
#     }
#   }
#   spec {
#     replicas = 1
#     selector {
#       match_labels = {
#         app = "gpu-container"
#       }
#     }
#     template {
#       metadata {
#         labels = {
#           app = "gpu-container"
#         }
#       }
#       spec {
#         node_selector = {
#           "gpu" : "true"
#         }
#         container {
#           image   = "ubuntu"
#           name    = "gpu-container"
#           command = ["/usr/bin/sleep", "3600"]
#           # security_context {
#           #   privileged = true
#           #   capabilities {
#           #     add = ["SYS_ADMIN"]
#           #   }
#           # }
#           resources {
#             limits = {
#               "nvidia.com/gpu" = "1"
#             }
#           }
#         }
#       }
#     }
#   }
#   depends_on = [helm_release.nvidia-gpu-operator]
# }

# GPU Pod Memory Exporter - exposes per-pod GPU memory usage as Prometheus metrics
resource "kubernetes_config_map" "gpu_pod_exporter_script" {
  metadata {
    name      = "gpu-pod-exporter-script"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }

  data = {
    "exporter.py" = <<-EOF
#!/usr/bin/env python3
"""GPU Pod Memory Exporter - Collects per-pod GPU memory usage."""

import subprocess
import time
import re
import os
import json
import urllib.request
import ssl
from http.server import HTTPServer, BaseHTTPRequestHandler

METRICS_PORT = 9401
SCRAPE_INTERVAL = 15

# Kubernetes API configuration
K8S_API = "https://kubernetes.default.svc"
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# Cache for container ID to pod info mapping
container_cache = {}
cache_refresh_time = 0
CACHE_TTL = 60  # Refresh cache every 60 seconds

def get_k8s_token():
    """Read Kubernetes service account token."""
    try:
        with open(TOKEN_PATH, 'r') as f:
            return f.read().strip()
    except:
        return None

def refresh_container_cache():
    """Refresh the container ID to pod mapping from Kubernetes API."""
    global container_cache, cache_refresh_time

    token = get_k8s_token()
    if not token:
        return

    try:
        # Create SSL context with K8s CA
        ctx = ssl.create_default_context()
        if os.path.exists(CA_PATH):
            ctx.load_verify_locations(CA_PATH)

        # Get all pods on this node
        node_name = os.environ.get('NODE_NAME', '')
        url = f"{K8S_API}/api/v1/pods?fieldSelector=spec.nodeName={node_name}"

        req = urllib.request.Request(url, headers={
            'Authorization': f'Bearer {token}',
            'Accept': 'application/json'
        })

        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            data = json.loads(resp.read().decode())

        new_cache = {}
        for pod in data.get('items', []):
            pod_name = pod['metadata']['name']
            namespace = pod['metadata']['namespace']

            # Get container statuses
            for status in pod.get('status', {}).get('containerStatuses', []):
                container_id = status.get('containerID', '')
                # Extract the ID part (e.g., "containerd://abc123..." -> "abc123")
                if '://' in container_id:
                    container_id = container_id.split('://')[-1]
                if container_id:
                    short_id = container_id[:12]
                    new_cache[short_id] = {
                        'pod': pod_name,
                        'namespace': namespace,
                        'container': status.get('name', 'unknown')
                    }

        container_cache = new_cache
        cache_refresh_time = time.time()
        print(f"Refreshed container cache: {len(new_cache)} containers")

    except Exception as e:
        print(f"Error refreshing container cache: {e}")

def get_pod_info(container_id):
    """Look up pod info for a container ID."""
    global cache_refresh_time

    # Refresh cache if stale
    if time.time() - cache_refresh_time > CACHE_TTL:
        refresh_container_cache()

    return container_cache.get(container_id, {
        'pod': 'unknown',
        'namespace': 'unknown',
        'container': 'unknown'
    })

def get_gpu_processes():
    """Run nvidia-smi to get GPU process info."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,used_memory,process_name", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            print(f"nvidia-smi error: {result.stderr}")
            return []

        processes = []
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 3:
                pid, memory_mib, process_name = parts[0], parts[1], parts[2]
                processes.append({
                    'pid': pid,
                    'memory_bytes': int(memory_mib) * 1024 * 1024,
                    'process_name': process_name
                })
        return processes
    except Exception as e:
        print(f"Error running nvidia-smi: {e}")
        return []

def get_container_id(pid):
    """Map PID to container ID via cgroup."""
    cgroup_path = f"/host_proc/{pid}/cgroup"
    try:
        with open(cgroup_path, 'r') as f:
            for line in f:
                # Match container ID patterns (docker, containerd, cri-o)
                match = re.search(r'[:/]([a-f0-9]{64})', line)
                if match:
                    return match.group(1)[:12]
                match = re.search(r'cri-containerd-([a-f0-9]{64})', line)
                if match:
                    return match.group(1)[:12]
    except (FileNotFoundError, PermissionError):
        pass
    return "host"

# Global metrics storage
current_metrics = []

def collect_metrics():
    """Collect GPU memory metrics."""
    global current_metrics
    metrics = []
    processes = get_gpu_processes()

    for proc in processes:
        container_id = get_container_id(proc['pid'])
        pod_info = get_pod_info(container_id)
        metrics.append({
            'container_id': container_id,
            'pid': proc['pid'],
            'process_name': proc['process_name'],
            'memory_bytes': proc['memory_bytes'],
            'pod': pod_info['pod'],
            'namespace': pod_info['namespace'],
            'container': pod_info['container']
        })

    current_metrics = metrics

def format_metrics():
    """Format metrics in Prometheus exposition format."""
    lines = [
        "# HELP gpu_pod_memory_used_bytes GPU memory used by pod",
        "# TYPE gpu_pod_memory_used_bytes gauge"
    ]

    for m in current_metrics:
        labels = ','.join([
            f'namespace="{m["namespace"]}"',
            f'pod="{m["pod"]}"',
            f'container="{m["container"]}"',
            f'process_name="{m["process_name"]}"',
            f'pid="{m["pid"]}"'
        ])
        lines.append(f'gpu_pod_memory_used_bytes{{{labels}}} {m["memory_bytes"]}')

    return '\n'.join(lines) + '\n'

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            content = format_metrics()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(content.encode())
        elif self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress request logging

def background_collector():
    """Background thread to collect metrics periodically."""
    import threading
    def run():
        while True:
            collect_metrics()
            time.sleep(SCRAPE_INTERVAL)
    thread = threading.Thread(target=run, daemon=True)
    thread.start()

if __name__ == '__main__':
    print(f"Starting GPU Pod Memory Exporter on port {METRICS_PORT}")
    refresh_container_cache()  # Initial cache load
    collect_metrics()  # Initial collection
    background_collector()

    server = HTTPServer(('', METRICS_PORT), MetricsHandler)
    server.serve_forever()
EOF
  }
}

resource "kubernetes_service_account" "gpu_pod_exporter" {
  metadata {
    name      = "gpu-pod-exporter"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "gpu_pod_exporter" {
  metadata {
    name = "gpu-pod-exporter"
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_cluster_role_binding" "gpu_pod_exporter" {
  metadata {
    name = "gpu-pod-exporter"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.gpu_pod_exporter.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gpu_pod_exporter.metadata[0].name
    namespace = kubernetes_namespace.nvidia.metadata[0].name
  }
}

resource "kubernetes_daemonset" "gpu_pod_exporter" {
  metadata {
    name      = "gpu-pod-exporter"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels = {
      app  = "gpu-pod-exporter"
      tier = var.tier
    }
  }

  spec {
    selector {
      match_labels = {
        app = "gpu-pod-exporter"
      }
    }

    template {
      metadata {
        labels = {
          app = "gpu-pod-exporter"
        }
      }

      spec {
        host_pid             = true
        service_account_name = kubernetes_service_account.gpu_pod_exporter.metadata[0].name

        node_selector = {
          "nvidia.com/gpu.present" : "true"
        }

        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "exporter"
          image = "python:3.11-slim"

          command = ["/bin/bash", "-c"]
          args = [
            "python3 /scripts/exporter.py"
          ]

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          port {
            container_port = 9401
            name           = "metrics"
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          volume_mount {
            name       = "host-proc"
            mount_path = "/host_proc"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory           = "128Mi"
              "nvidia.com/gpu" = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 9401
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }
        }

        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.gpu_pod_exporter_script.metadata[0].name
            default_mode = "0755"
          }
        }

        volume {
          name = "host-proc"
          host_path {
            path = "/proc"
            type = "Directory"
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }

  depends_on = [helm_release.nvidia-gpu-operator]
}

resource "kubernetes_service" "gpu_pod_exporter" {
  metadata {
    name      = "gpu-pod-exporter"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels = {
      app = "gpu-pod-exporter"
    }
  }

  spec {
    selector = {
      app = "gpu-pod-exporter"
    }

    port {
      name        = "metrics"
      port        = 80
      target_port = 9401
    }
  }
}
