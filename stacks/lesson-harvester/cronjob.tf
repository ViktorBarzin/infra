# Learn Later playlist poller. Shipped SUSPENDED — flip suspend=false once the
# YouTube API key + playlist id are in Vault secret/lesson-harvester.
resource "kubernetes_cron_job_v1" "poll" {
  metadata {
    name      = "lesson-harvester-poll"
    namespace = kubernetes_namespace.lesson_harvester.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "0 * * * *"
    suspend                       = true
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 1800
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            init_container {
              name              = "alembic-migrate"
              image             = local.image
              image_pull_policy = "Always"
              command           = ["alembic", "upgrade", "head"]
              env_from {
                secret_ref {
                  name = "lesson-harvester-secrets"
                }
              }
              env_from {
                secret_ref {
                  name = "lesson-harvester-db-creds"
                }
              }
              resources {
                requests = { cpu = "50m", memory = "256Mi" }
                limits   = { memory = "512Mi" }
              }
            }
            container {
              name              = "poll"
              image             = local.image
              image_pull_policy = "Always"
              command           = ["python", "-m", "lesson_harvester", "poll"]
              env_from {
                secret_ref {
                  name = "lesson-harvester-secrets"
                }
              }
              env_from {
                secret_ref {
                  name = "lesson-harvester-db-creds"
                }
              }
              dynamic "env" {
                for_each = local.app_env
                content {
                  name  = env.key
                  value = env.value
                }
              }
              resources {
                requests = { cpu = "100m", memory = "512Mi" }
                limits   = { memory = "1Gi" }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1 (CronJob path)
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_manifest.app_external_secret, kubernetes_manifest.db_external_secret]
}
