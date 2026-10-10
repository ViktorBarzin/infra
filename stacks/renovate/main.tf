# Renovate: lands third-party version bumps on viktor/infra master, one per run.
#
# Software-currency design (docs/plans/2026-10-09-software-currency-design.md,
# "Phase 3") and ADR-0030. Renovate reads renovate.json5 at the repo root and
# the rails' ignore list in renovate/ignored-versions.json, pushes one bump as
# the renovate-bot Forgejo account, and the Woodpecker pipeline applies it.
# Runbook: docs/runbooks/renovate.md.
#
# Out of band (Forgejo admin API, 2026-10-10, not Terraform-managed, same as
# the infra-agent bot): the renovate-bot account, its write access on
# viktor/infra, its entry on master's push whitelist, and the PAT stored at
# secret/renovate (forgejo_token).
#
# Kyverno: the image is referenced as docker.io/renovate/renovate, which the
# existing "docker.io/*" entry in require-trusted-registries already admits.

variable "suspended" {
  type        = bool
  description = "Kill switch. true sets the CronJob to suspend: no Renovate run starts until it is false."
  default     = true
}

variable "schedule" {
  type    = string
  default = "*/30 * * * *"
}

locals {
  namespace = "renovate"
  # Slim image: datasource lookups are plain HTTP inside Node, and infra has
  # no lock files, so the 2.6 GB -full image adds nothing. Renovate bumps this
  # pin itself, at most once a week (renovate.json5).
  image = "docker.io/renovate/renovate:44.115.9@sha256:2327f790a2faf49aafc42cb3b5233f4f52b18fd3081c850f1adc17d2a9af584e"
  labels = {
    app = "renovate"
  }
}

resource "kubernetes_namespace" "renovate" {
  metadata {
    name = local.namespace
    labels = {
      # Aux tier: tier-4-aux priority, aux quota (2 CPU / 3Gi requests).
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "renovate-env"
      namespace = kubernetes_namespace.renovate.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "renovate-env"
      }
      data = [
        {
          # renovate-bot's PAT: repo rw, user r, issue rw, organization r.
          secretKey = "RENOVATE_TOKEN"
          remoteRef = { key = "renovate", property = "forgejo_token" }
        },
        {
          # read:packages only, no write scope. Used for github.com release
          # notes and the authenticated GitHub API rate limit.
          secretKey = "RENOVATE_GITHUB_COM_TOKEN"
          remoteRef = { key = "viktor", property = "ghcr_pull_token" }
        },
      ]
    }
  }
}

resource "kubernetes_config_map" "renovate" {
  metadata {
    name      = "renovate"
    namespace = kubernetes_namespace.renovate.metadata[0].name
  }
  data = {
    "config.js"       = file("${path.module}/files/config.js")
    "run-renovate.sh" = file("${path.module}/files/run-renovate.sh")
  }
}

# Repo clone (persistRepoData), repository cache and package lookup cache, so
# a 30-minute run does not re-clone or re-query every registry. Holds only
# public data (the infra repo is public, secrets in it are git-crypt
# ciphertext) and is rebuilt by the next run if lost, so it has no backup.
resource "kubernetes_persistent_volume_claim" "cache" {
  wait_until_bound = false
  metadata {
    name      = "renovate-cache"
    namespace = kubernetes_namespace.renovate.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "5Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer grows this PVC; do not shrink it back on apply.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_cron_job_v1" "renovate" {
  metadata {
    name      = "renovate"
    namespace = kubernetes_namespace.renovate.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = var.schedule
    suspend                       = var.suspended
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 0
        active_deadline_seconds    = 1500
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy = "Never"
            security_context {
              # The image runs as uid 12021; fsGroup makes the cache PVC writable.
              fs_group = 12021
            }
            container {
              name  = "renovate"
              image = local.image
              # The image entrypoint (renovate-entrypoint.sh) initialises
              # containerbase and execs this script, which calls renovate.
              # Extra args are passed through to renovate, e.g. --dry-run=full.
              args = ["/opt/renovate/run-renovate.sh"]
              env_from {
                secret_ref {
                  name = "renovate-env"
                }
              }
              env {
                name  = "RENOVATE_CONFIG_FILE"
                value = "/opt/renovate/config.js"
              }
              env {
                name  = "LOG_LEVEL"
                value = "info"
              }
              env {
                # Skip the run while an infra pipeline is running or queued.
                name  = "WOODPECKER_REPO_ID"
                value = "82"
              }
              env {
                name  = "RENOVATE_INSTANCE"
                value = "infra"
              }
              volume_mount {
                name       = "config"
                mount_path = "/opt/renovate"
                read_only  = true
              }
              volume_mount {
                name       = "cache"
                mount_path = "/tmp/renovate"
              }
              resources {
                requests = {
                  cpu    = "250m"
                  memory = "768Mi"
                }
                limits = {
                  memory = "3Gi"
                }
              }
            }
            volume {
              name = "config"
              config_map {
                name         = kubernetes_config_map.renovate.metadata[0].name
                default_mode = "0755"
              }
            }
            volume {
              name = "cache"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.cache.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_manifest.external_secret]
}
