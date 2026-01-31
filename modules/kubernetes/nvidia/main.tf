variable "tls_secret_name" {}
variable "tier" { type = string }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.nvidia.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "nvidia" {
  metadata {
    name = "nvidia"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

# Apply GPU taint to ensure only GPU workloads run on GPU node
resource "null_resource" "gpu_node_taint" {
  provisioner "local-exec" {
    command = "kubectl taint nodes k8s-node1 nvidia.com/gpu=true:NoSchedule --overwrite"
  }

  # Re-run if namespace changes (proxy for cluster changes)
  triggers = {
    namespace = kubernetes_namespace.nvidia.metadata[0].name
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
              replicas: 20
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
  #   version    = "0.9.3"
  timeout = 6000

  values     = [templatefile("${path.module}/values.yaml", {})]
  depends_on = [kubernetes_config_map.time_slicing_config]
}

resource "kubernetes_deployment" "nvidia-exporter" {
  metadata {
    name      = "nvidia-exporter"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels = {
      app  = "nvidia-exporter"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "nvidia-exporter"
      }
    }
    template {
      metadata {
        labels = {
          app = "nvidia-exporter"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          image = "nvidia/dcgm-exporter:latest"
          name  = "nvidia-exporter"
          port {
            container_port = 9400
          }
          security_context {
            privileged = true
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.nvidia-gpu-operator]
}

resource "kubernetes_service" "nvidia-exporter" {
  metadata {
    name      = "nvidia-exporter"
    namespace = kubernetes_namespace.nvidia.metadata[0].name
    labels = {
      "app" = "nvidia-exporter"
    }
  }

  spec {
    selector = {
      app = "nvidia-exporter"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 9400
    }
  }
}


module "ingress" {
  source                  = "../ingress_factory"
  namespace               = kubernetes_namespace.nvidia.metadata[0].name
  name                    = "nvidia-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
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
from http.server import HTTPServer, BaseHTTPRequestHandler

METRICS_PORT = 9401
SCRAPE_INTERVAL = 15

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
                # e.g., /kubepods/pod.../containerid or /docker/containerid
                match = re.search(r'[:/]([a-f0-9]{64})', line)
                if match:
                    return match.group(1)[:12]  # Return short container ID
                # Also check for cri-containerd pattern
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
        metrics.append({
            'container_id': container_id,
            'pid': proc['pid'],
            'process_name': proc['process_name'],
            'memory_bytes': proc['memory_bytes']
        })

    current_metrics = metrics

def format_metrics():
    """Format metrics in Prometheus exposition format."""
    lines = [
        "# HELP gpu_pod_memory_used_bytes GPU memory used by container",
        "# TYPE gpu_pod_memory_used_bytes gauge"
    ]

    for m in current_metrics:
        labels = f'container_id="{m["container_id"]}",pid="{m["pid"]}",process_name="{m["process_name"]}"'
        lines.append(f"gpu_pod_memory_used_bytes{{{labels}}} {m['memory_bytes']}")

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
    collect_metrics()  # Initial collection
    background_collector()

    server = HTTPServer(('', METRICS_PORT), MetricsHandler)
    server.serve_forever()
EOF
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
        host_pid = true

        node_selector = {
          "gpu" : "true"
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
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu              = "200m"
              memory           = "256Mi"
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
