# Nightly curation for Viktor's photo frame (frame.tf), which is also the London
# projector's screensaver.
#
# Viktor asked on 2026-11-25 for the frame to show only photos with him, with
# Anca, or with nobody (landscapes), and never photos of only other people. The
# frame excludes one album; frame_sync_viktor.py keeps that album equal to
# "photos with faces, none of them Viktor or Anca", adding new ones and taking
# out any that face recognition later assigns to either of them.
#
# The album was seeded the same day from the database: 13,492 of 67,279 images
# (11,454 with other named or clustered people, 2,038 with only unassigned
# faces). Uses the frame's key, which already holds every scope.

locals {
  # Immich person ids on Viktor's account (Immich v3 returns the person group id).
  frame_viktor_keep_people = [
    "409ea64b-7163-4189-a211-ab55651f645b", # Viktor Barzin
    "fc207035-ae2a-4baa-9aa5-f0082846777e", # Anca Milea
  ]
  frame_viktor_excluded_album = "87e490a6-1d9a-4529-a45c-aa202116bb15" # "Frame: hidden (other people only)"
}

resource "kubernetes_secret" "frame_sync_viktor" {
  metadata {
    name      = "frame-sync-viktor"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    immich_api_key = data.vault_kv_secret_v2.secrets.data["frame_api_key"]
  }
}

resource "kubernetes_config_map" "frame_sync_viktor_script" {
  metadata {
    name      = "frame-sync-viktor-script"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  data = {
    "frame_sync_viktor.py" = file("${path.module}/frame_sync_viktor.py")
  }
}

resource "kubernetes_cron_job_v1" "frame-sync-viktor" {
  metadata {
    name      = "frame-sync-viktor"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # Daily 04:00 UTC, after Immich's nightly face recognition has clustered the
    # previous day's uploads.
    schedule                  = "0 4 * * *"
    starting_deadline_seconds = 300
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 1800
        ttl_seconds_after_finished = 86400
        template {
          metadata {}
          spec {
            container {
              name = "sync"
              # Pure-stdlib script on a stock image: never pip/apk install at
              # runtime in a CronJob (writes the node container layer every run).
              image   = "docker.io/library/python:3.15-alpine"
              command = ["python3", "/app/frame_sync_viktor.py"]
              env {
                name  = "IMMICH_URL"
                value = "http://immich-server.immich.svc.cluster.local:2283"
              }
              env {
                name = "IMMICH_API_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.frame_sync_viktor.metadata[0].name
                    key  = "immich_api_key"
                  }
                }
              }
              env {
                name  = "DROP_ALBUM"
                value = local.frame_viktor_excluded_album
              }
              env {
                name  = "KEEP_PEOPLE"
                value = join(",", local.frame_viktor_keep_people)
              }
              env {
                # Photos added this recently with no assigned person get a
                # per-photo faces lookup. Two weeks lets a missed run or a slow
                # face-detection queue catch up.
                name  = "WINDOW_DAYS"
                value = "14"
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
                requests = { cpu = "10m", memory = "128Mi" }
                limits   = { memory = "256Mi" }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.frame_sync_viktor_script.metadata[0].name
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
