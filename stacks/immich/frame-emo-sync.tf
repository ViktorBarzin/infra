# Weekly maintenance for Emo's Portal Mini photo-frame (see frame-emo.tf).
#
# The frame shows the trailing 365 days of Emo's Immich account MINUS the
# curated equipment/document album (ExcludedAlbums). New content photos appear
# automatically; new *equipment* photos would wrongly appear until they are
# added to the drop album. This CronJob classifies the photos that are new
# since the last run and files the equipment ones into the drop album, using
# Immich's own CLIP smart-search (no external LLM) — ~95% precision / ~96%
# recall vs the hand-labelled seed set, conservative (only excludes on a match,
# so it errs toward showing a photo rather than hiding a memory).
#
# Script + albums seeded 2026-07-11/12; see memory + docs. Self-contained: uses
# Emo's own Immich key (frame_api_key_emo) and the in-cluster immich-server.

resource "kubernetes_secret" "frame_sync_emo" {
  metadata {
    name      = "frame-sync-emo"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    immich_api_key = data.vault_kv_secret_v2.secrets.data["frame_api_key_emo"]
  }
}

resource "kubernetes_config_map" "frame_sync_emo_script" {
  metadata {
    name      = "frame-sync-emo-script"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    "frame_sync.py" = file("${path.module}/frame_sync.py")
  }
}

resource "kubernetes_cron_job_v1" "frame-sync-emo" {
  metadata {
    name      = "frame-sync-emo"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "0 4 * * 0" # Sundays 04:00
    time_zone                     = "Europe/Sofia"
    starting_deadline_seconds     = 300
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 600
        ttl_seconds_after_finished = 86400
        template {
          metadata {}
          spec {
            container {
              name = "sync"
              # Pure-stdlib script on a stock image — never pip/apk install at
              # runtime in a CronJob (writes the node container layer every run).
              image   = "docker.io/library/python:3.12-alpine"
              command = ["python3", "/app/frame_sync.py"]
              env {
                name  = "IMMICH_URL"
                value = "http://immich-server.immich.svc.cluster.local:2283"
              }
              env {
                name = "IMMICH_API_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.frame_sync_emo.metadata[0].name
                    key  = "immich_api_key"
                  }
                }
              }
              env {
                name  = "KEEP_ALBUM"
                value = "c64addd4-79f5-490e-bf4b-6af1e1ef610f"
              }
              env {
                name  = "DROP_ALBUM"
                value = "b703c7e1-943f-44c4-9ebb-ae3ee41473dd"
              }
              env {
                name  = "DAYS"
                value = "365"
              }
              env {
                name  = "DRY_RUN"
                value = "false"
              }
              volume_mount {
                name       = "script"
                mount_path = "/app"
                read_only  = true
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.frame_sync_emo_script.metadata[0].name
              }
            }
            restart_policy = "Never"
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
