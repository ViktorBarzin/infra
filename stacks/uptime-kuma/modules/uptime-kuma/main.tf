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
              cpu    = "100m"
              memory = "128Mi"
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
  dns_type        = "proxied"
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
# Ensures Uptime Kuma has external HTTPS monitors for every ingress annotated
# with `uptime.viktorbarzin.me/external-monitor=true`. Falls back to a
# Terraform-generated ConfigMap when API discovery is unavailable.
#
# Discovery modes (the script tries them in order):
#   1. K8s API — list ingresses cluster-wide, filter by annotation
#   2. ConfigMap fallback — read /config/targets.json (legacy list from
#      cloudflare_proxied_names)
# =============================================================================

resource "kubernetes_service_account_v1" "external_monitor_sync" {
  metadata {
    name      = "external-monitor-sync"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "external_monitor_sync" {
  metadata {
    name = "external-monitor-sync"
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["list", "get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "external_monitor_sync" {
  metadata {
    name = "external-monitor-sync"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.external_monitor_sync.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.external_monitor_sync.metadata[0].name
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
  }
}

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
            service_account_name = kubernetes_service_account_v1.external_monitor_sync.metadata[0].name
            container {
              name  = "sync"
              image = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check uptime-kuma-api
                python3 << 'PYEOF'
import os, json, ssl, time, urllib.request, urllib.error
from uptime_kuma_api import UptimeKumaApi, MonitorType

UPTIME_KUMA_URL = "http://uptime-kuma.uptime-kuma.svc.cluster.local"
UPTIME_KUMA_PASS = os.environ["UPTIME_KUMA_PASSWORD"]
FALLBACK_FILE = "/config/targets.json"
PREFIX = "[External] "
ANNOTATION_ENABLE = "uptime.viktorbarzin.me/external-monitor"
ANNOTATION_NAME = "uptime.viktorbarzin.me/external-monitor-name"
ANNOTATION_PATH = "uptime.viktorbarzin.me/external-monitor-path"
DEFAULT_PATH = "/"
# Homepages often serve 200/30x/40x even when backends are degraded.
# When an explicit probe path is set we expect a real healthz: tighten codes.
STATUSCODES_LENIENT = ["200-299", "300-399", "400-499"]
STATUSCODES_STRICT = ["200-299"]
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API_SERVER = f"https://{os.environ.get('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc.cluster.local')}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"


def load_from_api():
    """List ingresses via in-cluster API. Opt-OUT by default:
    every ingress whose host matches *.viktorbarzin.me gets a monitor,
    UNLESS its annotation `uptime.viktorbarzin.me/external-monitor` is `"false"`.
    This covers Helm-managed ingresses (authentik, grafana, vault, forgejo, ntfy)
    that don't go through ingress_factory."""
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    url = f"{API_SERVER}/apis/networking.k8s.io/v1/ingresses"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        body = json.loads(resp.read())

    targets = []
    seen = set()
    for ing in body.get("items", []):
        anns = (ing.get("metadata") or {}).get("annotations") or {}
        if anns.get(ANNOTATION_ENABLE, "").lower() == "false":
            continue  # explicit opt-out
        tls = (ing.get("spec") or {}).get("tls") or []
        host = None
        if tls and tls[0].get("hosts"):
            host = tls[0]["hosts"][0]
        else:
            rules = (ing.get("spec") or {}).get("rules") or []
            if rules:
                host = rules[0].get("host")
        if not host or not host.endswith(".viktorbarzin.me"):
            continue  # skip internal-only or non-public hosts
        label = anns.get(ANNOTATION_NAME) or host.split(".")[0]
        monitor_name = f"{PREFIX}{label}"
        if monitor_name in seen:
            continue  # dedupe by final monitor name, not hostname (fixes duplicate creation)
        seen.add(monitor_name)
        path = anns.get(ANNOTATION_PATH, "").strip()
        if path and not path.startswith("/"):
            path = "/" + path
        # Omit trailing slash when no explicit path — matches pre-existing monitor URLs
        # and avoids every sync re-updating unchanged monitors.
        url = f"https://{host}{path}" if path else f"https://{host}"
        statuscodes = STATUSCODES_STRICT if path else STATUSCODES_LENIENT
        targets.append({"name": label, "url": url, "statuscodes": statuscodes})
    return targets


def load_from_configmap():
    """Legacy fallback: read the ConfigMap list."""
    with open(FALLBACK_FILE) as f:
        raw = json.load(f)
    return [{"name": t["name"], "url": t["url"], "statuscodes": STATUSCODES_LENIENT} for t in raw]


try:
    targets = load_from_api()
    source = "k8s-api"
    if not targets:
        print("WARN: k8s-api returned 0 targets; falling back to ConfigMap")
        targets = load_from_configmap()
        source = "configmap"
except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
    print(f"WARN: k8s-api discovery failed ({e!r}); falling back to ConfigMap")
    targets = load_from_configmap()
    source = "configmap"

print(f"Loaded {len(targets)} external monitor targets (source={source})")

api = UptimeKumaApi(UPTIME_KUMA_URL, timeout=120, wait_events=0.2)
api.login("admin", UPTIME_KUMA_PASS)

monitors = api.get_monitors()
existing_external = {}
for m in monitors:
    if m["name"].startswith(PREFIX):
        existing_external[m["name"]] = m

target_names = set()
targets_by_name = {}
created = 0
for t in targets:
    monitor_name = f"{PREFIX}{t['name']}"
    target_names.add(monitor_name)
    targets_by_name[monitor_name] = t
    if monitor_name not in existing_external:
        print(f"Creating monitor: {monitor_name} -> {t['url']}")
        api.add_monitor(
            type=MonitorType.HTTP,
            name=monitor_name,
            url=t["url"],
            interval=300,
            maxretries=3,
            accepted_statuscodes=t["statuscodes"],
        )
        created += 1
        time.sleep(0.3)

# Update monitors whose target URL or accepted status codes drifted
# (e.g., new probe-path annotation added on an existing ingress).
updated = 0
for monitor_name, t in targets_by_name.items():
    existing = existing_external.get(monitor_name)
    if not existing:
        continue
    current_url = existing.get("url")
    current_codes = existing.get("accepted_statuscodes") or []
    if current_url == t["url"] and current_codes == t["statuscodes"]:
        continue
    print(f"Updating monitor {monitor_name}: {current_url} -> {t['url']} (codes {current_codes} -> {t['statuscodes']})")
    api.edit_monitor(
        existing["id"],
        url=t["url"],
        accepted_statuscodes=t["statuscodes"],
    )
    updated += 1
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
unchanged = len(target_names) - created - updated
print(f"Sync complete: {created} created, {updated} updated, {deleted} deleted, {unchanged} unchanged")
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

# =============================================================================
# Internal Monitor Sync
# Declaratively manages monitors for internal services (databases, non-HTTP
# endpoints) that can't be discovered from ingress annotations. Idempotent:
# looks up monitors by name, creates if missing, patches if drifted.
#
# Why a CronJob and not a one-shot Job:
# - louislam/uptime-kuma has no Terraform provider (only a CLI tool).
# - UK v2 stores monitors in MariaDB (`uptimekuma` on mysql.dbaas); if the DB
#   is wiped/restored we must re-create them.
# - CronJob self-heals drift (manual UI edits, UK restarts, DB restores).
#
# Managed monitors (name -> desired spec) are defined in local.internal_monitors
# below. Add new internal-service monitors there.
# =============================================================================

locals {
  internal_monitors = [
    {
      name                        = "MySQL Standalone (dbaas)"
      type                        = "mysql"
      database_connection_string  = "mysql://uptimekuma@mysql.dbaas.svc.cluster.local:3306"
      database_password_vault_key = "uptimekuma_db_password"
      interval                    = 60
      retry_interval              = 60
      max_retries                 = 2
    },
  ]
}

resource "kubernetes_secret" "internal_monitor_sync" {
  metadata {
    name      = "internal-monitor-sync"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
  }
  data = merge(
    { UPTIME_KUMA_PASSWORD = data.vault_kv_secret_v2.viktor.data["uptime_kuma_admin_password"] },
    {
      for m in local.internal_monitors :
      "DB_PASSWORD_${upper(replace(m.name, "/[^A-Za-z0-9]/", "_"))}" =>
      data.vault_kv_secret_v2.viktor.data[m.database_password_vault_key]
    },
  )
}

resource "kubernetes_config_map_v1" "internal_monitor_targets" {
  metadata {
    name      = "internal-monitor-targets"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
  }
  data = {
    "targets.json" = jsonencode([
      for m in local.internal_monitors : {
        name                       = m.name
        type                       = m.type
        database_connection_string = m.database_connection_string
        password_env               = "DB_PASSWORD_${upper(replace(m.name, "/[^A-Za-z0-9]/", "_"))}"
        interval                   = m.interval
        retry_interval             = m.retry_interval
        max_retries                = m.max_retries
      }
    ])
  }
}

resource "kubernetes_cron_job_v1" "internal_monitor_sync" {
  metadata {
    name      = "internal-monitor-sync"
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
import json, os, time
from uptime_kuma_api import UptimeKumaApi, MonitorType

UPTIME_KUMA_URL = "http://uptime-kuma.uptime-kuma.svc.cluster.local"
UPTIME_KUMA_PASS = os.environ["UPTIME_KUMA_PASSWORD"]

with open("/config/targets.json") as f:
    targets = json.load(f)

api = UptimeKumaApi(UPTIME_KUMA_URL, timeout=120, wait_events=0.2)
api.login("admin", UPTIME_KUMA_PASS)

existing = {m["name"]: m for m in api.get_monitors()}

for t in targets:
    name = t["name"]
    password = os.environ[t["password_env"]]
    # MYSQL monitors use `databaseConnectionString` + `radiusPassword`
    # (UK v2 re-uses the radiusPassword field for mysql auth — backwards compat).
    desired = {
        "type": MonitorType(t["type"]),
        "name": name,
        "databaseConnectionString": t["database_connection_string"],
        "radiusPassword": password,
        "interval": t["interval"],
        "retryInterval": t["retry_interval"],
        "maxretries": t["max_retries"],
    }
    if name not in existing:
        print(f"Creating monitor: {name}")
        api.add_monitor(**desired)
        continue
    m = existing[name]
    drifted = (
        m.get("databaseConnectionString") != desired["databaseConnectionString"]
        or m.get("radiusPassword") != desired["radiusPassword"]
        or m.get("interval") != desired["interval"]
        or m.get("retryInterval") != desired["retryInterval"]
        or m.get("maxretries") != desired["maxretries"]
    )
    if drifted:
        print(f"Updating monitor {name} (id={m['id']})")
        api.edit_monitor(
            m["id"],
            databaseConnectionString=desired["databaseConnectionString"],
            radiusPassword=desired["radiusPassword"],
            interval=desired["interval"],
            retryInterval=desired["retryInterval"],
            maxretries=desired["maxretries"],
        )
    else:
        print(f"Monitor {name} (id={m['id']}) already in desired state")
    time.sleep(0.3)

api.disconnect()
print("Internal monitor sync complete")
PYEOF
              EOT
              ]
              env_from {
                secret_ref {
                  name = kubernetes_secret.internal_monitor_sync.metadata[0].name
                }
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
                name = kubernetes_config_map_v1.internal_monitor_targets.metadata[0].name
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
