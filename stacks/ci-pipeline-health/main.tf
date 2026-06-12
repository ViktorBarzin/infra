# ci-pipeline-health — daily sweep of the off-infra CI chain (ADR-0002).
#
# Viktor's standing instruction (2026-06-12): monitor the pipelines closely
# during/after the off-infra builds migration (PRD infra#10). Deterministic
# shell sweep (files/sweep.sh) on the claude-agent-service image: GitHub
# Actions failures/stuck runs across owned repos, Woodpecker pipeline
# failures, GHA free-tier minutes burn. Healthy => one quiet Slack line;
# issues => Slack alert + a comment on infra#10.
#
# Runs IN-CLUSTER (not a claude.ai cloud routine) because Vault and the
# Woodpecker token are LAN-only — cloud agents can't reach them.

variable "schedule" {
  type = string
  # 07:30 UTC = 08:30 London in summer (07:30 in winter — acceptable drift,
  # CronJob schedules are UTC-only).
  default = "30 7 * * *"
}

# Mirrors stacks/claude-agent-service image tag — the image ships curl + jq.
variable "image_tag" {
  type    = string
  default = "2fd7670d"
}

locals {
  namespace = "ci-pipeline-health"
  image     = "forgejo.viktorbarzin.me/viktor/claude-agent-service:${var.image_tag}"
  labels = {
    app = "ci-pipeline-health"
  }
}

resource "kubernetes_namespace" "ci_pipeline_health" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
}

# github_pat (NOT the ghcr_pull_token alias): the sweep reads Actions runs +
# billing on PRIVATE mirrors, which a future scoped read:packages rotation of
# the alias could not do. Blast radius = this single-CronJob namespace.
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "ci-pipeline-health-creds"
      namespace = kubernetes_namespace.ci_pipeline_health.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "ci-pipeline-health-creds"
      }
      data = [
        {
          secretKey = "GITHUB_PAT"
          remoteRef = { key = "viktor", property = "github_pat" }
        },
        {
          secretKey = "WOODPECKER_API_TOKEN"
          remoteRef = { key = "ci/global", property = "woodpecker_api_token" }
        },
        {
          secretKey = "SLACK_WEBHOOK"
          remoteRef = { key = "ci/global", property = "slack_webhook" }
        },
      ]
    }
  }
}

resource "kubernetes_config_map" "sweep_script" {
  metadata {
    name      = "ci-pipeline-health-sweep"
    namespace = kubernetes_namespace.ci_pipeline_health.metadata[0].name
  }
  data = {
    "sweep.sh" = file("${path.module}/files/sweep.sh")
  }
}

resource "kubernetes_cron_job_v1" "sweep" {
  metadata {
    name      = "ci-pipeline-health"
    namespace = kubernetes_namespace.ci_pipeline_health.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 600
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy = "Never"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name    = "sweep"
              image   = local.image
              command = ["/bin/sh", "/scripts/sweep.sh"]
              env_from {
                secret_ref {
                  name = "ci-pipeline-health-creds"
                }
              }
              volume_mount {
                name       = "sweep-script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "sweep-script"
              config_map {
                name = kubernetes_config_map.sweep_script.metadata[0].name
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
