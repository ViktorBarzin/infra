variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }
variable "cloudflare_proxied_names" { type = list(string) }

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

locals {
  # Services that don't respond to standard HTTP health checks
  non_http_services = toset(["xray-vless", "xray-ws", "xray-grpc"])

  external_monitor_targets = [
    for name in var.cloudflare_proxied_names : {
      name     = name
      hostname = name == "viktorbarzin.me" ? "viktorbarzin.me" : "${name}.viktorbarzin.me"
      url      = name == "viktorbarzin.me" ? "https://viktorbarzin.me" : "https://${name}.viktorbarzin.me"
    }
    if !contains(local.non_http_services, name)
  ]
}

resource "kubernetes_namespace" "uptime-kuma" {
  metadata {
    name = "uptime-kuma"
    labels = {
      tier = var.tier
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.uptime-kuma.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "uptime-kuma-data-proxmox"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
    labels = {
      app  = "uptime-kuma"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "uptime-kuma"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "latest"
        }
        labels = {
          app = "uptime-kuma"
        }
      }
      spec {
        container {
          image = "louislam/uptime-kuma:2"
          name  = "uptime-kuma"

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          port {
            container_port = 3001
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3001
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3001
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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
}
resource "kubernetes_service" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
    labels = {
      "app" = "uptime-kuma"
    }
  }

  spec {
    selector = {
      app = "uptime-kuma"
    }
    port {
      port        = "80"
      target_port = "3001"
    }
  }
}
module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.uptime-kuma.metadata[0].name
  name            = "uptime"
  tls_secret_name = var.tls_secret_name
  service_name    = "uptime-kuma"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Uptime monitor"
    "gethomepage.dev/group"       = "Core Platform"
    "gethomepage.dev/icon" : "uptime-kuma.png"
    "gethomepage.dev/name"         = "Uptime Kuma"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "uptimekuma"
    "gethomepage.dev/widget.url"   = "http://uptime-kuma.uptime-kuma.svc.cluster.local"
    "gethomepage.dev/widget.slug"  = "infra"
  }
  rybbit_site_id = "8fef77b1f7fe"
}

# CronJob for daily SQLite backups # no longer needed as we're using the mysql
# resource "kubernetes_cron_job_v1" "sqlite-backup" {
#   metadata {
#     name      = "backup"
#    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
#   }
#   spec {
#     concurrency_policy        = "Replace"
#     failed_jobs_history_limit = 5
#     schedule                  = "0 0 * * *"
#     # schedule                      = "* * * * *"
#     starting_deadline_seconds     = 10
#     successful_jobs_history_limit = 3
#     job_template {
#       metadata {}
#       spec {
#         active_deadline_seconds    = 600 # should finish in 10 minutes
#         backoff_limit              = 3
#         ttl_seconds_after_finished = 10
#         template {
#           metadata {}
#           spec {
#             container {
#               name  = "backup"
#               image = "alpine/sqlite:latest"
#               command = ["/bin/sh", "-c", <<-EOT
#                 set -e
#                 export now=$(date +"%Y_%m_%d_%H_%M")
#                 echo "Backing up SQLite database to /app/data/backup/backup_$now.sqlite"
#                 sqlite3 /app/data/kuma.db ".backup /app/data/backup/backup_$now.sqlite"
#                 echo "Backup completed. Deleting old backups..."

#                 # Rotate - delete last log file
#                 cd /app/data/backup
#                 find . -name "*.sqlite" -type f -mtime +7 -delete # 7 day retention of backups
#                 echo "Old backups deleted."
#               EOT
#               ]
#               volume_mount {
#                 name       = "data"
#                 mount_path = "/app/data"
#               }
#             }
#             volume {
#               name = "data"
#               nfs {
#                 server = var.nfs_server
#                 path   = "/mnt/main/uptime-kuma"
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }

# =============================================================================
# External Monitor Sync
# Ensures Uptime Kuma has external HTTPS monitors for all Cloudflare-proxied services.
# Reads targets from a Terraform-generated ConfigMap, creates/deletes monitors to match.
# =============================================================================
resource "kubernetes_config_map_v1" "external_monitor_targets" {
  metadata {
    name      = "external-monitor-targets"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
  }
  data = {
    "targets.json" = jsonencode(local.external_monitor_targets)
  }
}

resource "kubernetes_cron_job_v1" "external_monitor_sync" {
  metadata {
    name      = "external-monitor-sync"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/10 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "sync"
              image = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check uptime-kuma-api
                python3 << 'PYEOF'
import os, json, time
from uptime_kuma_api import UptimeKumaApi, MonitorType

UPTIME_KUMA_URL = "http://uptime-kuma.uptime-kuma.svc.cluster.local"
UPTIME_KUMA_PASS = os.environ["UPTIME_KUMA_PASSWORD"]
TARGETS_FILE = "/config/targets.json"
PREFIX = "[External] "

with open(TARGETS_FILE) as f:
    targets = json.load(f)

print(f"Loaded {len(targets)} external monitor targets")

api = UptimeKumaApi(UPTIME_KUMA_URL, timeout=120, wait_events=0.2)
api.login("admin", UPTIME_KUMA_PASS)

monitors = api.get_monitors()
existing_external = {}
for m in monitors:
    if m["name"].startswith(PREFIX):
        existing_external[m["name"]] = m

target_names = set()
created = 0
for t in targets:
    monitor_name = f"{PREFIX}{t['name']}"
    target_names.add(monitor_name)
    if monitor_name not in existing_external:
        print(f"Creating monitor: {monitor_name} -> {t['url']}")
        api.add_monitor(
            type=MonitorType.HTTP,
            name=monitor_name,
            url=t["url"],
            interval=300,
            maxretries=3,
            accepted_statuscodes=["200-299", "300-399", "400-499"],
        )
        created += 1
        time.sleep(0.3)

# Remove monitors for services no longer in the list
deleted = 0
for name, m in existing_external.items():
    if name not in target_names:
        print(f"Deleting orphaned monitor: {name}")
        api.delete_monitor(m["id"])
        deleted += 1
        time.sleep(0.3)

api.disconnect()
print(f"Sync complete: {created} created, {deleted} deleted, {len(target_names) - created} unchanged")
PYEOF
              EOT
              ]
              env {
                name  = "UPTIME_KUMA_PASSWORD"
                value = data.vault_kv_secret_v2.viktor.data["uptime_kuma_admin_password"]
              }
              volume_mount {
                name       = "config"
                mount_path = "/config"
                read_only  = true
              }
              resources {
                requests = {
                  memory = "128Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map_v1.external_monitor_targets.metadata[0].name
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
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
