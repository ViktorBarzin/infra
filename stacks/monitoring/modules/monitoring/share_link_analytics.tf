# =============================================================================
# Immich share-link geo analytics -> Pushgateway (daily)
# =============================================================================
# "Who viewed my shared album, and from where?" — per-slug unique-visitor and
# per-country gauges computed from Traefik access logs in Loki, geolocated
# with the DB-IP Country Lite DB (CC-BY 4.0, no account/key), pushed to the
# persisted Pushgateway. Complements the "Immich Share Link Analytics" Loki
# recording rules (loki.tf), which provide the continuous opens/requests
# counters; exact unique-IP counting needs per-IP data that must NOT become
# Prometheus label cardinality, hence this job computes distincts and pushes
# only the aggregates.
#
# Deliberately DECOUPLED from the Alloy ingest path: enriching log lines with
# GeoIP at ship time would make every Alloy pod's startup depend on an mmdb
# file (external download or NFS mount) — the exact coupling the storage docs
# forbid for monitoring-critical components. A daily stateless job that can
# fail without breaking anything is the right altitude.
#
# Implementation follows the alert-digest pattern: stock python:3.12-alpine,
# pure-stdlib script from a ConfigMap, no pip/apk at runtime (memory id=559).
# Alert: ShareLinkGeoStale (prometheus_chart_values.tpl) fires after two
# missed dailies.
# =============================================================================

resource "kubernetes_config_map" "share_link_geo_script" {
  metadata {
    name      = "share-link-geo-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "share_link_geo.py" = file("${path.module}/share_link_geo.py")
  }
}

resource "kubernetes_cron_job_v1" "share_link_geo" {
  metadata {
    name      = "share-link-geo"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "share-link-geo"
      tier = var.tier
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "45 6 * * *"
    starting_deadline_seconds     = 600
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        active_deadline_seconds    = 1500
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "share-link-geo"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "share-link-geo"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/share_link_geo.py"]
              env {
                name  = "LOKI_URL"
                value = "http://loki.monitoring.svc.cluster.local:3100"
              }
              env {
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              # 30d = Loki retention; swept in 72h instant-query chunks (a
              # single 720h query 504s the SingleBinary — 2026-07-06).
              env {
                name  = "WINDOW_HOURS"
                value = "720"
              }
              env {
                name  = "CHUNK_HOURS"
                value = "72"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu = "50m"
                  # DB-IP country table is held in memory (~700k ranges as
                  # int arrays/tuples) — comfortably under 512Mi.
                  memory = "192Mi"
                }
                limits = {
                  memory = "512Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.share_link_geo_script.metadata[0].name
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
