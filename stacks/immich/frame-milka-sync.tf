# Weekly curation for Milka's photo frame (see frame-milka.tf).
#
# Her library arrives mostly through Viber, so alongside the photographs it keeps
# collecting forwarded greeting cards, joke text-images and captures of
# conversations. The frame excludes one album; this job files the new arrivals of
# that kind into it so the exclusion does not go stale the moment it is applied.
#
# Uses its own key rather than the frame's: the frame's key is read-only on
# purpose (it is what sits on a kiosk), and adding to an album is a write. The
# sync key holds asset.read + album.read + albumAsset.create and nothing else —
# verified at mint time that removing from an album and deleting an asset both
# come back 403, so the worst case here is a photo hidden, never one lost.
#
# Script + album seeded 2026-08-22/23.

resource "kubernetes_secret" "frame_sync_milka" {
  metadata {
    name      = "frame-sync-milka"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    immich_api_key = data.vault_kv_secret_v2.emo_immich_sync_milka.data["key"]
  }
}

data "vault_kv_secret_v2" "emo_immich_sync_milka" {
  mount = "secret"
  name  = "emo/immich_sync_key_milka"
}

resource "kubernetes_config_map" "frame_sync_milka_script" {
  metadata {
    name      = "frame-sync-milka-script"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    "frame_sync_milka.py" = file("${path.module}/frame_sync_milka.py")
  }
}

resource "kubernetes_cron_job_v1" "frame-sync-milka" {
  metadata {
    name      = "frame-sync-milka"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # Sundays 03:00 UTC — an hour after frame-sync-emo, so the two do not put
    # their CLIP searches on the shared GPU at the same moment. No time_zone
    # attribute: it is not used anywhere in this repo with this provider and the
    # apply rejects it (2026-07-11).
    schedule                  = "0 3 * * 0"
    starting_deadline_seconds = 300
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
              command = ["python3", "/app/frame_sync_milka.py"]
              env {
                name  = "IMMICH_URL"
                value = "http://immich-server.immich.svc.cluster.local:2283"
              }
              env {
                name = "IMMICH_API_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.frame_sync_milka.metadata[0].name
                    key  = "immich_api_key"
                  }
                }
              }
              env {
                name  = "DROP_ALBUM"
                value = "0d174625-d279-49dd-a446-0eaeda03d7ff"
              }
              env {
                # A week's arrivals plus a week of slack, so one skipped run does
                # not leave a gap that never gets classified.
                name  = "DAYS"
                value = "14"
              }
              env {
                # Kept small deliberately. The window holds far fewer assets than
                # the whole library, so the same size reaches much deeper into the
                # ranking — and precision falls off the deep end, which is where
                # the errors that matter live (2026-08-23: at 60 the delivery-app
                # query returned her own camera photos of people with parcels).
                name  = "PER_QUERY"
                value = "60"
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
                name = kubernetes_config_map.frame_sync_milka_script.metadata[0].name
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
