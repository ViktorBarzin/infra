# =============================================================================
# CISA Known Exploited Vulnerabilities -> Pushgateway (2026-11-10)
# =============================================================================
# Once a day, loads CISA's catalogue of CVEs exploited in the wild and PUTs one
# cisa_kev_listed{vuln_id} series per CVE (about 1,800). The
# TrivyKnownExploitedCVE alert (prometheus_chart_values.tpl, group Trivy) joins
# it with Trivy's findings, so an exploited CVE in an internet-reachable image
# alerts at once, whether or not any fix exists. CisaKevFeedStale fires when
# the catalogue has not refreshed for 3 days.
#
# job-runtime has python3 baked in; the script is ConfigMap-mounted
# (tests: python3 cisa_kev_test.py).
# =============================================================================

resource "kubernetes_config_map" "cisa_kev_script" {
  metadata {
    name      = "cisa-kev-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "cisa_kev.py" = file("${path.module}/cisa_kev.py")
  }
}

resource "kubernetes_cron_job_v1" "cisa_kev" {
  metadata {
    name      = "cisa-kev"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "cisa-kev"
      tier = var.tier
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "40 5 * * *"
    timezone                      = "Etc/UTC"
    starting_deadline_seconds     = 600
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "cisa-kev"
            }
            annotations = {
              "dependency.kyverno.io/wait-for" = "prometheus-prometheus-pushgateway.monitoring:9091"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "cisa-kev"
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              command           = ["python3", "/scripts/cisa_kev.py"]
              env {
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
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
              name = "script"
              config_map {
                name = kubernetes_config_map.cisa_kev_script.metadata[0].name
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
