# Renovate: lands third-party version bumps on viktor/infra master, one per run,
# every 2 hours (skipped while an infra pipeline runs).
#
# A second CronJob, renovate-apps (bottom of this file), updates first-party app
# repos on the default app stack (app-kit docs/adr/0001-default-app-stack.md,
# "Delivery"): its own config (files/config-apps.js), repo list, run limit and
# cache. It shares the renovate-bot account, the renovate-env Secret and the
# wrapper script with the infra job, and changes nothing about that job.
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
# secret/renovate (forgejo_token). Added 2026-10-11 with Viktor's OK: its entry
# on master's merge whitelist, so the PR Renovate opens when a fast-forward
# loses a race with another push (PR #113) can be merged by Renovate itself.
#
# A third CronJob, renovate-cloud-apps (bottom of this file), updates Cloud
# Users' App repos (Cloud backlog B13, decision V13): repos found by the
# Forgejo topic cloud-app, every update in one weekly pull request, merged
# only when every commit status, Cloud's check build cloud/build among
# them, is success (files/config-cloud-apps.js). It runs as its own
# restricted Forgejo account, cloud-renovate, from its own Secret
# renovate-cloud-env, which holds that token only: Users enrol their own
# repos, so it must not hold renovate-bot's token or the GitHub and Docker
# Hub ones. It shares only the image and the wrapper.
#
# Kyverno: the image is referenced as docker.io/renovate/renovate, which the
# existing "docker.io/*" entry in require-trusted-registries already admits.

variable "suspended" {
  type        = bool
  description = "Kill switch. true sets the CronJob to suspend: no Renovate run starts until it is false."
  # Unsuspended 2026-10-11 (software-currency wave 6). Set back to true to stop Renovate.
  default = false
}

variable "apps_suspended" {
  type        = bool
  description = "Kill switch for the renovate-apps CronJob only. true suspends it; the infra job is unaffected."
  default     = false
}

variable "apps_schedule" {
  type = string
  # Every 6 hours, 30 minutes after the infra job (its runs end within 25
  # minutes, active_deadline_seconds), so the two never run at once.
  default = "47 */6 * * *"
}

variable "cloud_apps_suspended" {
  type        = bool
  description = "Kill switch for the renovate-cloud-apps CronJob only. true suspends it; the other jobs are unaffected."
  # Suspended until the Operator steps in docs/runbooks/cloud.md ("Renovate
  # on App repos") have made cloud-renovate and its token.
  default = true
}

variable "cloud_apps_schedule" {
  type = string
  # Every 2 hours at :07. Renovate opens or updates branches only inside its
  # own window (Monday 00:00-05:59 UTC, config-cloud-apps.js), so 3 runs a
  # week create the pull requests; the other runs merge the ones whose check
  # build passed since, within 2 hours. At :07 a run overlaps at most one of
  # the other two jobs, inside the namespace's 3Gi request quota.
  default = "7 */2 * * *"
}

variable "schedule" {
  type = string
  # Every hour (2026-11-05). At every 2 hours the queue held 29 to 34 updates
  # from 2026-10-21 to 2026-11-05 while landing 11 to 12 a day, the ceiling,
  # so it never drained and majors never reached the front. Hourly doubles the
  # ceiling to about 24 a day; RENOVATE_MIN_GAP (20 minutes after the last
  # Renovate pipeline), the calm gate and the busy-pipeline skip still hold
  # each bump to its own pipeline, so a run whose predecessor is still
  # settling lands nothing. Viktor chose this over grouping shared base images
  # across stacks, which would verify ~20 stacks per commit and revert them
  # all on one failing check.
  #
  # Every 2 hours (2026-10-21). Every 6 hours from 2026-10-15 left 34 updates
  # queued: at one bump per run that is at most 4 a day, fewer when the calm
  # gate skips a night run, and new releases arrived about as fast. Every 10
  # minutes from 2026-10-11 to 2026-10-15 cleared the first backlog but drove
  # node4's VM disk from 27-70 to 67-199 GB/day on the shared sdc HDD. The disk
  # load comes from the bumps that land, not from runs that land nothing (those
  # read the lookup cache), so 2 hours gives about 12 bumps a day while each
  # one keeps its own pipeline, backup, verify and RENOVATE_MIN_GAP. Viktor
  # chose this over raising prCommitsPerRunLimit, which would push several
  # bumps per run and let their pipelines cancel each other. The wrapper still
  # skips a run while an infra pipeline is running or queued.
  default = "17 * * * *"
}

locals {
  namespace = "renovate"
  # Slim image: datasource lookups are plain HTTP inside Node, and infra has
  # no lock files, so the 2.6 GB -full image adds nothing. Renovate bumps this
  # pin itself, at most once a week (renovate.json5).
  image = "docker.io/renovate/renovate:44.240.0@sha256:e33a3330128949311ebc9c4c2ffda7452ab58da8a04e17216a03755ca3449949"
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

# Same value as tier-3-edge, so the Woodpecker step pods a Renovate push starts
# (tier-3-edge) cannot preempt this pod mid-run, which happened twice on
# 2026-10-11 at tier-4-aux. preemption_policy Never: Renovate itself never
# evicts another pod to get scheduled; it waits for room instead.
resource "kubernetes_priority_class_v1" "renovate" {
  metadata {
    name = "renovate"
  }
  value             = 400000
  preemption_policy = "Never"
  global_default    = false
  description       = "Renovate CronJob: tier-3-edge value, never preempts (stacks/renovate)."
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
        {
          # The Docker Hub account the registry pull-through cache already
          # uses (playbooks/registry-cache.yml). Anonymous lookups share the
          # home IP's 100 manifest requests per hour; two dry runs used it up
          # on 2026-10-11. config.js adds a docker.io hostRule when both are set.
          secretKey = "DOCKERHUB_USERNAME"
          remoteRef = { key = "registry-cache", property = "dockerhub_username" }
        },
        {
          secretKey = "DOCKERHUB_TOKEN"
          remoteRef = { key = "registry-cache", property = "dockerhub_token" }
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
    "cve-priority.js" = file("${path.module}/files/cve-priority.js")
    # After each successful run: pending fixes for images with CVEs, read from
    # Renovate's report, for the UpgradeFixNotLanded alert (2026-11-10).
    "cve-fix-pending.js" = file("${path.module}/files/cve-fix-pending.js")
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
    access_modes = ["ReadWriteOnce"]
    # SSD since 2026-11-03: read-heavy, regenerable cache (android-emulator has the details).
    storage_class_name = "proxmox-lvm-ssd"
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
            restart_policy      = "Never"
            priority_class_name = kubernetes_priority_class_v1.renovate.metadata[0].name
            security_context {
              # The image runs as uid 12021; fsGroup makes the cache PVC writable.
              fs_group = 12021
              # Only chown the volume when its root has the wrong group. The
              # default (Always) re-chowned all ~12,000 cache files on every pod
              # start, which took about 10 minutes per run on 2026-10-11.
              fs_group_change_policy = "OnRootMismatch"
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
              env {
                # Order pending updates by fixable Critical/High CVE count
                # from Trivy (files/cve-priority.js, 2026-11-04), and after a
                # successful run push the pending fixes for images with CVEs
                # (files/cve-fix-pending.js, 2026-11-10).
                name  = "CVE_PRIORITY"
                value = "1"
              }
              env {
                # Saturday (UTC): pending majors go ahead of everything else, so
                # they do not wait behind a queue that never empties
                # (files/cve-priority.js, 2026-11-05). 0 = Sunday ... 6 = Saturday.
                name  = "MAJORS_FIRST_WEEKDAY"
                value = "6"
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

# ---------------------------------------------------------------------------
# renovate-apps: app repos (ADR-0001 Delivery row, 2026-10-16).
# Repo list, landing policy, 3-day npm wait and the TanStack Start/Router hold
# live in files/config-apps.js. Same image pin as the infra job, so Renovate's
# weekly self-bump moves both.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "renovate_apps" {
  metadata {
    name      = "renovate-apps"
    namespace = kubernetes_namespace.renovate.metadata[0].name
  }
  data = {
    "config.js"       = file("${path.module}/files/config-apps.js")
    "run-renovate.sh" = file("${path.module}/files/run-renovate.sh")
  }
}

# Repo clones, lookup cache, the OSV database and the Bun binary containerbase
# installs (binarySource=install). Public data, rebuilt by the next run if
# lost, so no backup. Separate from renovate-cache: both are RWO, and sharing
# one would tie the two jobs to the same node.
resource "kubernetes_persistent_volume_claim" "apps_cache" {
  wait_until_bound = false
  metadata {
    name      = "renovate-apps-cache"
    namespace = kubernetes_namespace.renovate.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    # SSD since 2026-11-03: read-heavy, regenerable cache (android-emulator has the details).
    storage_class_name = "proxmox-lvm-ssd"
    resources {
      requests = { storage = "5Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer grows this PVC; do not shrink it back on apply.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_cron_job_v1" "renovate_apps" {
  metadata {
    name      = "renovate-apps"
    namespace = kubernetes_namespace.renovate.metadata[0].name
    labels    = { app = "renovate-apps" }
  }
  spec {
    schedule                      = var.apps_schedule
    suspend                       = var.apps_suspended
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = { app = "renovate-apps" }
      }
      spec {
        backoff_limit              = 0
        active_deadline_seconds    = 1500
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "renovate-apps" }
          }
          spec {
            restart_policy      = "Never"
            priority_class_name = kubernetes_priority_class_v1.renovate.metadata[0].name
            security_context {
              fs_group               = 12021
              fs_group_change_policy = "OnRootMismatch"
            }
            container {
              name  = "renovate"
              image = local.image
              args  = ["/opt/renovate/run-renovate.sh"]
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
              # Pushgateway group job="renovate", instance="apps". The
              # RenovateNotSucceeding alert reads instance="infra" only.
              env {
                name  = "RENOVATE_INSTANCE"
                value = "apps"
              }
              # The rails hold cool-down is about infra bumps; app repos do not
              # wait on it. No WOODPECKER_REPO_ID either: app builds run on
              # GitHub Actions, and the infra pipeline guard does not apply.
              # The etcd calm gate stays on.
              env {
                name  = "RAILS_HOLD_COOLDOWN"
                value = "0"
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
                name         = kubernetes_config_map.renovate_apps.metadata[0].name
                default_mode = "0755"
              }
            }
            volume {
              name = "cache"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.apps_cache.metadata[0].name
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

# ---------------------------------------------------------------------------
# renovate-cloud-apps: Cloud Users' App repos (Cloud backlog B13, 2026-11-17).
# Repos come from the Forgejo topic cloud-app, which `cloud new` and `cloud
# renovate enable` set with the User's own token, together with
# cloud-renovate as a Write collaborator. The merge gate and the weekly group live in
# files/config-cloud-apps.js. Same image pin as the other jobs. No Woodpecker
# guard (Cloud builds App repos) and no rails cool-down; the etcd calm gate
# stays on.
# ---------------------------------------------------------------------------

# cloud-renovate's PAT (write:repository, read:user, write:issue), made by
# an Operator with Forgejo's in-pod CLI (docs/runbooks/cloud.md, "Renovate
# on App repos"). The only key: this job gets no other credential.
resource "kubernetes_manifest" "cloud_apps_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "renovate-cloud-env"
      namespace = kubernetes_namespace.renovate.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "renovate-cloud-env"
      }
      data = [
        {
          secretKey = "RENOVATE_TOKEN"
          remoteRef = { key = "renovate-cloud", property = "forgejo_token" }
        },
      ]
    }
  }
}

resource "kubernetes_config_map" "renovate_cloud_apps" {
  metadata {
    name      = "renovate-cloud-apps"
    namespace = kubernetes_namespace.renovate.metadata[0].name
  }
  data = {
    "config.js"       = file("${path.module}/files/config-cloud-apps.js")
    "run-renovate.sh" = file("${path.module}/files/run-renovate.sh")
  }
}

# Repo clones, lookup cache and the tools containerbase installs. Public or
# per-User repo data that the next run rebuilds if lost, so no backup. Its
# own PVC: the caches are RWO, and sharing one would tie the jobs to a node.
resource "kubernetes_persistent_volume_claim" "cloud_apps_cache" {
  wait_until_bound = false
  metadata {
    name      = "renovate-cloud-apps-cache"
    namespace = kubernetes_namespace.renovate.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-ssd"
    resources {
      requests = { storage = "5Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer grows this PVC; do not shrink it back on apply.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_cron_job_v1" "renovate_cloud_apps" {
  metadata {
    name      = "renovate-cloud-apps"
    namespace = kubernetes_namespace.renovate.metadata[0].name
    labels    = { app = "renovate-cloud-apps" }
  }
  spec {
    schedule                      = var.cloud_apps_schedule
    suspend                       = var.cloud_apps_suspended
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = { app = "renovate-cloud-apps" }
      }
      spec {
        backoff_limit              = 0
        active_deadline_seconds    = 1500
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "renovate-cloud-apps" }
          }
          spec {
            restart_policy      = "Never"
            priority_class_name = kubernetes_priority_class_v1.renovate.metadata[0].name
            security_context {
              fs_group               = 12021
              fs_group_change_policy = "OnRootMismatch"
            }
            container {
              name  = "renovate"
              image = local.image
              args  = ["/opt/renovate/run-renovate.sh"]
              env_from {
                secret_ref {
                  name = "renovate-cloud-env"
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
              # Pushgateway group job="renovate", instance="cloud-apps", read by
              # the RenovateCloudAppsNotSucceeding alert (stacks/monitoring).
              env {
                name  = "RENOVATE_INSTANCE"
                value = "cloud-apps"
              }
              env {
                name  = "RAILS_HOLD_COOLDOWN"
                value = "0"
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
                name         = kubernetes_config_map.renovate_cloud_apps.metadata[0].name
                default_mode = "0755"
              }
            }
            volume {
              name = "cache"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.cloud_apps_cache.metadata[0].name
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
  depends_on = [kubernetes_manifest.cloud_apps_external_secret]
}
