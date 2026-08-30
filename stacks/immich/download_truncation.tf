# Do Immich downloads actually finish?
#
# Traefik writes its 200 and Content-Length before the body, then sends however
# many bytes it manages before the connection goes away. A download that dies
# part-way is therefore logged as a perfectly ordinary success, and the only
# way to tell the difference is to compare bytes delivered against the file's
# real size in Postgres. That is what this does, hourly.
#
# WHY IT EXISTS: on 2026-08-29 a friend of Viktor's downloaded a photo from a
# shared album and got a file that rendered correct on top and flat grey below
# a horizontal line — a truncated JPEG, which is what a decoder paints where
# the entropy data ran out. Nothing anywhere was watching for it. Reconstructing
# it took a hand-written Loki-to-Postgres join; this is that join, automated.
#
# TWO NUMBERS, and the distinction is the point:
#
#   immich_original_downloads_cut          a response carried fewer bytes than
#                                          the file holds. Routine on mobile,
#                                          and NOT a fault on its own: HTTP
#                                          range requests exist for this, and a
#                                          client that resumes gets everything.
#                                          Measured 5 of 9 assets in one real
#                                          session, 4 of which resumed cleanly.
#
#   immich_original_downloads_unrecovered  the ranges never covered the missing
#                                          tail, so somebody is holding a
#                                          partial file. THIS is the alert.
#
# Alerting on `cut` would page for someone riding a train. The alert below is
# on `unrecovered`, which in that same session was exactly 1 — the one photo
# that really was broken.
#
# Detection logic + its tests: download_truncation_detect{,_test}.py. Run the
# tests with `python3 download_truncation_detect_test.py`; they encode the real
# log lines from that session, including the video-seeking case (206 with no
# 200) that must NOT read as truncation.
#
# Stock images only — no pip/apk at runtime (the status-page-pusher disk-write
# anti-pattern, memory #559).

resource "kubernetes_config_map_v1" "download_truncation_script" {
  metadata {
    name      = "immich-download-truncation-script"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    "download_truncation_detect.py" = file("${path.module}/download_truncation_detect.py")
  }
}

resource "kubernetes_cron_job_v1" "immich_download_truncation" {
  metadata {
    name      = "immich-download-truncation"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # Hourly, with a window to match. Downloads are person-driven and bursty,
    # so a shorter window would mostly report zero and make the metric noisy.
    schedule                  = "7 * * * *"
    starting_deadline_seconds = 120
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 300
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            volume {
              name = "work"
              empty_dir {}
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map_v1.download_truncation_script.metadata[0].name
              }
            }

            # Every asset's true size. Dumped whole rather than filtered by the
            # ids Loki returns, because the id list is only known after the log
            # query and init containers run in sequence. ~163k rows is a few MB.
            init_container {
              name  = "sizes"
              image = "ghcr.io/immich-app/postgres:15-vectorchord0.4.3-pgvectors0.2.0"
              command = ["/bin/bash", "-c", <<-EOT
                set -euo pipefail
                psql -v ON_ERROR_STOP=1 -tA -F'|' \
                  -c 'SELECT "assetId", "fileSizeInByte" FROM asset_exif WHERE "fileSizeInByte" IS NOT NULL' \
                  > /work/sizes.csv
                echo "asset sizes: $(wc -l < /work/sizes.csv)"
              EOT
              ]
              env {
                name  = "PGHOST"
                value = "immich-postgresql.immich.svc.cluster.local"
              }
              env {
                name  = "PGUSER"
                value = "immich"
              }
              env {
                name  = "PGDATABASE"
                value = "immich"
              }
              env {
                name  = "PGCONNECT_TIMEOUT"
                value = "10"
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "immich-secrets"
                    key  = "db_password"
                  }
                }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "96Mi" }
              }
            }

            # Query Loki, join against the sizes, write exposition text.
            init_container {
              name    = "detect"
              image   = "docker.io/library/python:3.12-alpine"
              command = ["python3", "/script/download_truncation_detect.py"]
              env {
                name  = "LOKI_URL"
                value = "http://loki.monitoring.svc.cluster.local:3100"
              }
              env {
                name  = "WINDOW"
                value = "1h"
              }
              env {
                name  = "SIZES_FILE"
                value = "/work/sizes.csv"
              }
              env {
                name  = "OUT_FILE"
                value = "/work/metrics.prom"
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "script"
                mount_path = "/script"
              }
              resources {
                requests = { cpu = "20m", memory = "64Mi" }
                limits   = { memory = "192Mi" }
              }
            }

            container {
              name  = "push"
              image = "docker.io/curlimages/curl:8.11.1"
              command = [
                "curl", "-sf", "-m", "20", "--data-binary", "@/work/metrics.prom",
                "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/immich-download-truncation",
              ]
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              resources {
                requests = { cpu = "10m", memory = "16Mi" }
                limits   = { memory = "32Mi" }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: the inject-ndots ClusterPolicy stamps dns_config on
    # every pod; without this the next apply plans it away every time.
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
