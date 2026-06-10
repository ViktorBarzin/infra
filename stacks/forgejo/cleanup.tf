# Forgejo container-package retention CronJob.
#
# Forgejo's per-package "Cleanup Rules" UI is not exposed via Terraform —
# it's per-user runtime state inside the Forgejo DB. Driving retention from
# a CronJob hitting the public API keeps the policy versioned in this repo.
#
# Auth: a write:package PAT belonging to VIKTOR (the package OWNER). PAT
# lives in Vault at secret/viktor/forgejo_cleanup_token.
#
# CORRECTION 2026-06-09: this previously said the PAT belonged to ci-pusher.
# That was wrong and silently broke retention — Forgejo container packages
# are scoped per-user, so ci-pusher gets HTTP 403 on DELETE of viktor/*
# (the dry-run only does GETs, which DO work, so the 403 stayed hidden until
# the first live run). DELETE requires a write:package PAT owned by viktor.
# forgejo_cleanup_token is therefore set to viktor's write:package PAT (today
# the same value as secret/ci/global/forgejo_push_token). IF that push token
# is ever regenerated, re-mirror it here or retention silently 403s again.

data "vault_kv_secret_v2" "forgejo_viktor" {
  mount = "secret"
  name  = "viktor"
}

locals {
  # REVERTED TO DRY-RUN 2026-06-10: the first live runs ORPHANED OCI indexes.
  # The keep-set is computed over package VERSIONS (newest 10 + tag "latest"
  # + *cache* tags), but multi-arch/attestation index CHILDREN are separate
  # UNTAGGED sha256 versions — for images not rebuilt recently they fall
  # outside the newest-10 window and get deleted while their parent index is
  # kept. Result: index children 404 (viktor/kms-website :latest + :dfc83fb,
  # caught by forgejo-integrity-probe / RegistryManifestIntegrityFailure,
  # 2026-06-10). Do NOT re-enable until the script either (a) resolves each
  # kept index's child digests via the registry API and adds them to the
  # keep set, or (b) skips untagged sha256 versions entirely, or (c) is
  # replaced by Forgejo's native per-owner package cleanup rules (container-
  # aware). The 2026-06-09 "0 running images on the delete set" verification
  # checked running PODS, not index child references — insufficient.
  # History: activated 2026-06-09 (would prune 317 stale versions); registry
  # PVC pressure concern remains (HDD, no SSD move — see beads code-oflt).
  forgejo_cleanup_dry_run = true
}

resource "kubernetes_config_map" "forgejo_cleanup_script" {
  metadata {
    name      = "forgejo-cleanup-script"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  data = {
    "cleanup.sh" = file("${path.module}/files/cleanup.sh")
  }
}

resource "kubernetes_secret" "forgejo_cleanup_token" {
  metadata {
    name      = "forgejo-cleanup-token"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  type = "Opaque"
  data = {
    # try() so the apply succeeds before the Vault key is populated during
    # Phase 0 bootstrap (see docs/runbooks/forgejo-registry-setup.md). Empty
    # token causes the cleanup CronJob to fail visibly — that's intended.
    FORGEJO_TOKEN = try(data.vault_kv_secret_v2.forgejo_viktor.data["forgejo_cleanup_token"], "")
  }
}

resource "kubernetes_cron_job_v1" "forgejo_cleanup" {
  metadata {
    name      = "forgejo-cleanup"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    schedule                      = "0 4 * * *"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 3600
        template {
          metadata {}
          spec {
            container {
              name    = "cleanup"
              image   = "docker.io/library/alpine:3.20"
              command = ["/bin/sh", "/scripts/cleanup.sh"]
              env {
                name = "FORGEJO_TOKEN"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.forgejo_cleanup_token.metadata[0].name
                    key  = "FORGEJO_TOKEN"
                  }
                }
              }
              env {
                name  = "FORGEJO_HOST"
                value = "http://forgejo.forgejo.svc.cluster.local"
              }
              env {
                name  = "FORGEJO_OWNER"
                value = "viktor"
              }
              env {
                name  = "KEEP_LAST_N"
                value = "10"
              }
              env {
                name  = "DRY_RUN"
                value = local.forgejo_cleanup_dry_run ? "true" : "false"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.forgejo_cleanup_script.metadata[0].name
                default_mode = "0755"
              }
            }
            restart_policy = "OnFailure"
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
