# health-connection-sync: the scheduled puller from health ADR-0006.
#
# Runs `python -m app.services.connection_sync_cli` from the app image once a
# day. It pulls every active Connection, today the Home Assistant Connector
# that copies Viktor's weight, lean body mass and body fat from ha-london's
# Apple Health sensors into health_records, so the Budget's weight trend is
# current (health docs/plans/2026-11-20-photo-food-diary.md). HA keeps about
# ten days of sensor history, so one missed run loses nothing.
#
# The credential of each Connection lives encrypted in the health database;
# this Job only needs the database URL and the Fernet key that decrypts it.

resource "kubernetes_cron_job_v1" "connection_sync" {
  metadata {
    name      = "health-connection-sync"
    namespace = kubernetes_namespace.health.metadata[0].name
  }

  spec {
    # 06:20 UTC daily: after the morning weigh-in has reached ha-london.
    schedule                      = "20 6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 600

    job_template {
      metadata {}
      spec {
        active_deadline_seconds    = 600
        backoff_limit              = 1
        ttl_seconds_after_finished = 3600
        template {
          metadata {
            labels = {
              app = "health-connection-sync"
            }
          }
          spec {
            restart_policy = "Never"
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name              = "connection-sync"
              image             = "ghcr.io/viktorbarzin/health:latest"
              image_pull_policy = "Always"
              command           = ["python", "-m", "app.services.connection_sync_cli"]
              env {
                name = "DATABASE_URL"
                value_from {
                  secret_key_ref {
                    name = "health-db-secrets"
                    key  = "DATABASE_URL"
                  }
                }
              }
              env {
                name = "CONNECTION_ENCRYPTION_KEY"
                value_from {
                  secret_key_ref {
                    name = "health-kv-secrets"
                    key  = "connection_encryption_key"
                  }
                }
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.external_secret_kv]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
