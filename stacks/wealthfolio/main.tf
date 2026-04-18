variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "wealthfolio" {
  metadata {
    name = "wealthfolio"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "wealthfolio-secrets"
      namespace = "wealthfolio"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "wealthfolio-secrets"
      }
      dataFrom = [{
        extract = {
          key = "wealthfolio"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.wealthfolio]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.wealthfolio.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "wealthfolio-data-proxmox"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "wealthfolio" {
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    labels = {
      app  = "wealthfolio"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "wealthfolio"
      }
    }
    template {
      metadata {
        labels = {
          app = "wealthfolio"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v?\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "afadil/wealthfolio:3.2"
          name  = "wealthfolio"
          port {
            container_port = 8080
          }
          env {
            name  = "WF_LISTEN_ADDR"
            value = "0.0.0.0:8080"
          }
          env {
            name = "WF_AUTH_PASSWORD_HASH"
            value_from {
              secret_key_ref {
                name = "wealthfolio-secrets"
                key  = "password_hash"
              }
            }
          }
          env {
            name  = "WF_DB_PATH"
            value = "/data/wealthfolio.db"
          }
          env {
            name  = "WF_CORS_ALLOW_ORIGINS"
            value = "https://authentik.viktorbarzin.me"
          }
          env {
            name  = "WF_AUTH_TOKEN_TTL_MINUTES"
            value = "10080"
          }
          env {
            name  = "WF_SECRET_KEY"
            value = random_string.random.result
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # 2026-04-18 OOM after broker-sync Phase 3 landed (~700 activities
          # across 6 accounts including Fidelity + matched cash flows). The
          # /api/v1/net-worth + /valuations/history endpoints materialise the
          # full history in memory for the chart; 64Mi was a Phase-0 guess
          # that fit a 10-activity demo DB and nothing bigger.
          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        # Backup sidecar — see the big comment further down. Shares the WF
        # data PVC (read-only) + the NFS backup target. busybox crond fires
        # a nightly sqlite3 .backup so we have an off-cluster copy.
        container {
          name  = "backup"
          image = "alpine:3.20"
          command = ["/bin/sh", "-c", <<-EOT
          set -eu
          apk add --no-cache --quiet sqlite busybox-suid
          mkdir -p /etc/crontabs
          cat >/etc/crontabs/root <<'CRON'
          30 4 * * * /scripts/backup.sh >>/proc/1/fd/1 2>&1
          CRON
          mkdir -p /scripts
          cat >/scripts/backup.sh <<'SCRIPT'
          #!/bin/sh
          set -eu
          TS=$(date +%Y-%m-%dT%H-%M-%S)
          DIR=/backup/$TS
          mkdir -p "$DIR"
          sqlite3 /data/wealthfolio.db ".backup $DIR/wealthfolio.db"
          cp /data/secrets.json "$DIR/" 2>/dev/null || true
          # Retention — keep 30 days.
          find /backup -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
          echo "wealthfolio-backup: $DIR ($(du -sh $DIR | cut -f1))"
          SCRIPT
          chmod +x /scripts/backup.sh
          echo "wealthfolio-backup sidecar ready; next 04:30 UTC"
          exec crond -f -l 8
          EOT
          ]
          volume_mount {
            name       = "data"
            mount_path = "/data"
            read_only  = true
          }
          volume_mount {
            name       = "backup"
            mount_path = "/backup"
          }
          resources {
            requests = { cpu = "5m", memory = "16Mi" }
            limits   = { memory = "64Mi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = "wealthfolio-data-encrypted"
          }
        }
        volume {
          name = "backup"
          nfs {
            server = var.nfs_server
            path   = "/srv/nfs/wealthfolio-backup"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wealthfolio" {
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    labels = {
      "app" = "wealthfolio"
    }
  }

  spec {
    selector = {
      app = "wealthfolio"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.wealthfolio.metadata[0].name
  name            = "wealthfolio"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Wealthfolio"
    "gethomepage.dev/description"  = "Investment portfolio tracker"
    "gethomepage.dev/icon"         = "mdi-finance"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

resource "kubernetes_cron_job_v1" "wealthfolio_sync" {
  metadata {
    name      = "wealthfolio-sync"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }
  spec {
    schedule                      = "0 8 1 * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "sync"
              image = "registry.viktorbarzin.me/wealthfolio-sync:latest"
              env {
                name = "IMAP_HOST"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_host"
                  }
                }
              }
              env {
                name = "IMAP_USER"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_user"
                  }
                }
              }
              env {
                name = "IMAP_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_password"
                  }
                }
              }
              env {
                name = "IMAP_DIRECTORY"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_directory"
                  }
                }
              }
              env {
                name = "TRADING212_API_KEYS"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "trading212_api_keys"
                  }
                }
              }
              env {
                name  = "DB_PATH"
                value = "/data/wealthfolio.db"
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = "wealthfolio-data-encrypted"
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
}

############################################################################
# Backup — sidecar approach
#
# Wealthfolio has no PG/MySQL support (Diesel ORM hard-wired to SQLite per
# upstream README). The data lives on an RWO PVC that's held 24/7 by the
# main WF pod, so a separate backup CronJob would hit a Multi-Attach error
# (confirmed 2026-04-18 test).
#
# Instead, the WF Deployment gets a backup sidecar:
# - Shares the data PVC read-only + the NFS backup target.
# - Runs busybox `crond` with a 04:30-daily entry.
# - Uses `sqlite3 .backup` (WAL-safe, no downtime) to snapshot into an
#   NFS dated folder + retains 30 days.
#
# See `resource "kubernetes_deployment" "wealthfolio"` above — the sidecar
# is wired in via the deployment's container/volume blocks.
############################################################################
