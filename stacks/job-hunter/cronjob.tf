# Weekly market scrape. Runs ats + hn + levels_fyi, which upsert into
# comp_points/roles AND append dated rows into comp_snapshots/roles_snapshots
# (the trend series consumed by `job-hunter analyze`). Sundays 04:00 UTC —
# low-traffic window, polite to levels.fyi (~25 companies, 3s jitter each).
#
# The alembic-migrate init container mirrors the Deployment so the CronJob can
# never run a refresh against an un-migrated DB (snapshot inserts would fail).
# Image is local.image (:latest via image_tag) with imagePullPolicy=Always: a
# CronJob spawns a fresh pod each run, so Always pull = it always executes the
# newest built code. The Deployment is rolled by CI (kubectl set image to the
# build SHA); the CronJob needs no rollout — Always pull covers it.
resource "kubernetes_cron_job_v1" "job_hunter_refresh" {
  metadata {
    name      = "job-hunter-refresh"
    namespace = kubernetes_namespace.job_hunter.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "0 4 * * 0"
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
        active_deadline_seconds    = 1800 # cap a hung scrape at 30m
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

            init_container {
              name              = "alembic-migrate"
              image             = local.image
              image_pull_policy = "Always"
              command           = ["python", "-m", "job_hunter", "migrate"]
              env_from {
                secret_ref {
                  name = "job-hunter-secrets"
                }
              }
              env_from {
                secret_ref {
                  name = "job-hunter-db-creds"
                }
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "256Mi"
                }
                limits = {
                  memory = "512Mi"
                }
              }
            }

            container {
              name              = "refresh"
              image             = local.image
              image_pull_policy = "Always"
              command = ["python", "-m", "job_hunter", "refresh",
              "--source", "ats", "--source", "hn", "--source", "levels_fyi"]

              env_from {
                secret_ref {
                  name = "job-hunter-secrets"
                }
              }
              env_from {
                secret_ref {
                  name = "job-hunter-db-creds"
                }
              }

              resources {
                requests = {
                  cpu    = "100m"
                  memory = "512Mi"
                }
                limits = {
                  memory = "1Gi"
                }
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

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}
