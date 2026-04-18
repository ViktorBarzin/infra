variable "nfs_server" { type = string }

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "broker-sync image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

resource "kubernetes_namespace" "broker_sync" {
  metadata {
    name = "broker-sync"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
    }
  }
}

# Secrets for all providers. Seeded in Vault at `secret/broker-sync`:
#   wf_base_url         — e.g. https://wealthfolio.viktorbarzin.me
#   wf_username         — Wealthfolio login username
#   wf_password         — Wealthfolio login password (cleartext; server stores Argon2id)
#   trading212_api_keys — JSON array of {account_id, account_type, api_key, name, currency}
#   imap_host, imap_user, imap_password, imap_directory — for InvestEngine + Schwab email ingest
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "broker-sync-secrets"
      namespace = kubernetes_namespace.broker_sync.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "broker-sync-secrets"
      }
      dataFrom = [{
        extract = {
          key = "broker-sync"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.broker_sync]
}

# Canonical data dir — SQLite watermarks, FX cache, CSV drop/archive, Wealthfolio session cache.
# Encrypted because we're storing brokerage tokens, session cookies, and transaction history.
resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "broker-sync-data-encrypted"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "1Gi" }
    }
  }
}

locals {
  broker_sync_image = "viktorbarzin/broker-sync:${var.image_tag}"

  # Shared env block for every CronJob: auth into Wealthfolio + data path.
  common_env = [
    { name = "BROKER_SYNC_DATA_DIR", value = "/data", from = null },
    { name = "WF_SESSION_PATH", value = "/data/wealthfolio_session.json", from = null },
    { name = "WF_BASE_URL", value = null, from = "wf_base_url" },
    { name = "WF_USERNAME", value = null, from = "wf_username" },
    { name = "WF_PASSWORD", value = null, from = "wf_password" },
  ]
}

# Phase 0 liveness: proves the image + namespace + PVC + ESO wiring end-to-end.
# Suspended by default; toggle to false to run.
resource "kubernetes_cron_job_v1" "version_probe" {
  metadata {
    name      = "broker-sync-version"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "version-probe" }
  }
  spec {
    schedule                      = "0 1 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {
            labels = { app = "broker-sync", component = "version-probe" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name    = "broker-sync"
              image   = local.broker_sync_image
              command = ["broker-sync", "version"]
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "128Mi" }
              }
            }
          }
        }
      }
    }
  }
}

# Trading212 steady-state daily sync. Phase 1 deliverable.
resource "kubernetes_cron_job_v1" "trading212" {
  metadata {
    name      = "broker-sync-trading212"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "trading212" }
  }
  spec {
    schedule                      = "0 2 * * *" # 02:00 UK
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 300
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "broker-sync", component = "trading212" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name    = "broker-sync"
              image   = local.broker_sync_image
              command = ["broker-sync", "trading212", "--mode", "steady"]

              env {
                name  = "BROKER_SYNC_DATA_DIR"
                value = "/data"
              }
              env {
                name  = "WF_SESSION_PATH"
                value = "/data/wealthfolio_session.json"
              }
              env {
                name = "WF_BASE_URL"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_base_url"
                  }
                }
              }
              env {
                name = "WF_USERNAME"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_username"
                  }
                }
              }
              env {
                name = "WF_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_password"
                  }
                }
              }
              env {
                name = "T212_API_KEYS_JSON"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "trading212_api_keys"
                  }
                }
              }

              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = { cpu = "20m", memory = "128Mi" }
                limits   = { memory = "256Mi" }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

# IMAP ingest — InvestEngine + Schwab email parsers, one combined pod.
# Phase 2 deliverable. Defined ahead of implementation so the rollout is
# one `tf apply` once the image supports the CLI subcommand.
resource "kubernetes_cron_job_v1" "imap" {
  metadata {
    name      = "broker-sync-imap"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "imap" }
  }
  spec {
    schedule                      = "30 2 * * *" # 02:30 UK, 30min after T212
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    suspend                       = true # enable in Phase 2
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "broker-sync", component = "imap" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name    = "broker-sync"
              image   = local.broker_sync_image
              command = ["broker-sync", "imap"]

              env {
                name  = "BROKER_SYNC_DATA_DIR"
                value = "/data"
              }
              env {
                name  = "WF_SESSION_PATH"
                value = "/data/wealthfolio_session.json"
              }
              env {
                name = "WF_BASE_URL"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_base_url"
                  }
                }
              }
              env {
                name = "WF_USERNAME"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_username"
                  }
                }
              }
              env {
                name = "WF_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_password"
                  }
                }
              }
              env {
                name = "IMAP_HOST"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "imap_host"
                  }
                }
              }
              env {
                name = "IMAP_USER"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "imap_user"
                  }
                }
              }
              env {
                name = "IMAP_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "imap_password"
                  }
                }
              }
              env {
                name = "IMAP_DIRECTORY"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "imap_directory"
                  }
                }
              }

              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "256Mi" }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

# CSV drop-folder processor — Scottish Widows, Fidelity quarterly, Freetrade, etc.
# Phase 3 deliverable. Suspended until CLI subcommand lands.
resource "kubernetes_cron_job_v1" "csv_drop" {
  metadata {
    name      = "broker-sync-csv"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "csv" }
  }
  spec {
    schedule                      = "0 3 * * *" # 03:00 UK
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    suspend                       = true
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "broker-sync", component = "csv" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name    = "broker-sync"
              image   = local.broker_sync_image
              command = ["broker-sync", "csv-drop"]

              env {
                name  = "BROKER_SYNC_DATA_DIR"
                value = "/data"
              }
              env {
                name  = "WF_SESSION_PATH"
                value = "/data/wealthfolio_session.json"
              }
              env {
                name = "WF_BASE_URL"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_base_url"
                  }
                }
              }
              env {
                name = "WF_USERNAME"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_username"
                  }
                }
              }
              env {
                name = "WF_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_password"
                  }
                }
              }

              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

# Monthly HMRC FX reconciliation — rewrites last-month activities with official
# HMRC rates once they publish. Phase 1 tail / Phase 2 deliverable.
resource "kubernetes_cron_job_v1" "fx_reconcile" {
  metadata {
    name      = "broker-sync-fx-reconcile"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "fx-reconcile" }
  }
  spec {
    schedule                      = "5 5 7 * *" # 05:05 UK on the 7th
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    suspend                       = true
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "broker-sync", component = "fx-reconcile" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name    = "broker-sync"
              image   = local.broker_sync_image
              command = ["broker-sync", "fx-reconcile"]

              env {
                name  = "BROKER_SYNC_DATA_DIR"
                value = "/data"
              }
              env {
                name  = "WF_SESSION_PATH"
                value = "/data/wealthfolio_session.json"
              }
              env {
                name = "WF_BASE_URL"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_base_url"
                  }
                }
              }
              env {
                name = "WF_USERNAME"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_username"
                  }
                }
              }
              env {
                name = "WF_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_password"
                  }
                }
              }

              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

# Backup: snapshot sync.db / fx.db / csv-archive into NFS daily, keep 30 days.
# Convention from infra/.claude/CLAUDE.md: every proxmox-lvm app needs a backup
# CronJob writing to /mnt/main/<app>-backup/ on the PVE host (served over NFS).
resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "broker-sync-backup"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "backup" }
  }
  spec {
    schedule                      = "15 4 * * *" # 04:15 UK — after all syncs
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "broker-sync", component = "backup" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "backup"
              image = "alpine:3.20"
              command = ["/bin/sh", "-c", <<-EOT
              set -eu
              TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
              BACKUP_DIR="/backup/$TIMESTAMP"
              mkdir -p "$BACKUP_DIR"
              cp -a /data/sync.db "$BACKUP_DIR/" 2>/dev/null || true
              cp -a /data/fx.db "$BACKUP_DIR/" 2>/dev/null || true
              if [ -d /data/csv-archive ]; then
                cp -a /data/csv-archive "$BACKUP_DIR/"
              fi
              # Retention: keep last 30 days.
              find /backup -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
              echo "Backup complete: $BACKUP_DIR"
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
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
            volume {
              name = "backup"
              nfs {
                server = var.nfs_server
                path   = "/srv/nfs/broker-sync-backup"
              }
            }
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Fidelity UK PlanViewer — monthly pension contribution sync
#
# Architecture notes:
# - The CLI (`broker-sync fidelity-ingest`) loads storage_state.json, boots
#   headless Chromium, scrapes the transaction history + valuation JSON, and
#   posts DEPOSIT activities to Wealthfolio. See
#   broker-sync/docs/providers/fidelity-planviewer.md for the seed workflow.
# - Storage_state is staged to Vault (`secret/broker-sync` →
#   `fidelity_storage_state`). ESO projects all broker-sync keys into the
#   shared `broker-sync-secrets` K8s Secret; an init container writes the
#   JSON blob to the PVC so the main container can load it.
# - Image needs Chromium baked in — add the `fidelity-capable: "true"` label
#   so the Dockerfile/CI treats this CronJob's pod spec as the Playwright
#   variant. Until the Playwright image ships, keep `suspend = true`.
# - Schedule: 05:00 UK on the 20th of each month — well after Viktor's mid-
#   month payroll contribution has settled (finance history shows credits
#   landing 13th-18th).
resource "kubernetes_cron_job_v1" "fidelity" {
  metadata {
    name      = "broker-sync-fidelity"
    namespace = kubernetes_namespace.broker_sync.metadata[0].name
    labels    = { app = "broker-sync", component = "fidelity" }
  }
  spec {
    schedule                      = "0 5 20 * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    # Suspended until the broker-sync image ships with Playwright + Chromium.
    suspend = true
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "broker-sync", component = "fidelity" }
          }
          spec {
            restart_policy = "OnFailure"
            # Materialise the JSON storage_state from the projected Secret
            # onto the PVC where Playwright expects to read it.
            init_container {
              name  = "stage-storage-state"
              image = "busybox:1.36"
              command = ["/bin/sh", "-c", <<-EOT
              set -eu
              mkdir -p /data
              cp /secrets/fidelity_storage_state /data/fidelity_storage_state.json
              chmod 600 /data/fidelity_storage_state.json
              EOT
              ]
              volume_mount {
                name       = "secrets"
                mount_path = "/secrets"
                read_only  = true
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = { cpu = "5m", memory = "8Mi" }
                limits   = { memory = "32Mi" }
              }
            }
            container {
              name    = "broker-sync"
              image   = local.broker_sync_image
              command = ["broker-sync", "fidelity-ingest"]

              env {
                name  = "BROKER_SYNC_DATA_DIR"
                value = "/data"
              }
              env {
                name  = "WF_SESSION_PATH"
                value = "/data/wealthfolio_session.json"
              }
              env {
                name  = "FIDELITY_STORAGE_STATE_PATH"
                value = "/data/fidelity_storage_state.json"
              }
              env {
                name = "FIDELITY_PLAN_ID"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "fidelity_plan_id"
                  }
                }
              }
              env {
                name = "WF_BASE_URL"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_base_url"
                  }
                }
              }
              env {
                name = "WF_USERNAME"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_username"
                  }
                }
              }
              env {
                name = "WF_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "broker-sync-secrets"
                    key  = "wf_password"
                  }
                }
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                # Chromium is hungry — headless shell + page rendering
                # comfortably under 1Gi, spike up to 1.2Gi during full-page
                # screenshots.
                requests = { cpu = "50m", memory = "512Mi" }
                limits   = { memory = "1280Mi" }
              }
            }
            volume {
              name = "secrets"
              secret {
                secret_name = "broker-sync-secrets"
                items {
                  key  = "fidelity_storage_state"
                  path = "fidelity_storage_state"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
