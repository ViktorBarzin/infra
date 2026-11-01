# Albums shared with Milka appear on her photo frame (frame-milka.tf).
#
# Viktor asked on 2026-11-01 that sharing an album with her be enough to put it
# on the frame, with no config edit per album. Before this the frame showed only
# her own library: ImmichFrame's library search returns only assets she owns, so
# a shared album never reached it.
#
# How it works:
#   - the render-settings init container in the frame pod runs
#     frame_shared_albums.py, which lists the albums other people have shared
#     with her and adds them to Settings.yml as a second account. ImmichFrame
#     weights accounts by photo count, so each photo, hers or shared, has an
#     equal chance of being shown (Viktor's choice).
#   - frame-milka-refresh restarts the frame every night, so an album shared or
#     unshared during the day is picked up by the next morning. Overnight rather
#     than more often, because every restart blanks the screen for a few seconds.
#
# The init container uses the frame's own read-only key (album.read covers
# listing shared albums). If Immich is unreachable at start, the frame starts
# with her library only rather than staying down.

locals {
  # Shared by the frame's first account and the shared-albums account.
  milka_frame_excluded_albums = ["0d174625-d279-49dd-a446-0eaeda03d7ff"]
}

resource "kubernetes_secret" "frame_milka_key" {
  metadata {
    name      = "frame-milka-key"
    namespace = "immich"
  }
  data = {
    key = data.vault_kv_secret_v2.emo_immich_frame_milka.data["key"]
  }
}

resource "kubernetes_config_map" "frame_milka_shared_albums_script" {
  metadata {
    name      = "frame-milka-shared-albums-script"
    namespace = "immich"
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "frame_shared_albums.py" = file("${path.module}/frame_shared_albums.py")
  }
}

resource "kubernetes_service_account" "frame_milka_refresh" {
  metadata {
    name      = "frame-milka-refresh"
    namespace = "immich"
  }
}

resource "kubernetes_role" "frame_milka_refresh" {
  metadata {
    name      = "frame-milka-refresh"
    namespace = "immich"
  }
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = [kubernetes_deployment.immich-frame-milka.metadata[0].name]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "frame_milka_refresh" {
  metadata {
    name      = "frame-milka-refresh"
    namespace = "immich"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.frame_milka_refresh.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.frame_milka_refresh.metadata[0].name
    namespace = "immich"
  }
}

resource "kubernetes_cron_job_v1" "frame_milka_refresh" {
  metadata {
    name      = "frame-milka-refresh"
    namespace = "immich"
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # 01:30 UTC = 03:30 in Sofia in winter, 04:30 in summer.
    schedule                  = "30 1 * * *"
    starting_deadline_seconds = 600
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 300
        ttl_seconds_after_finished = 86400
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.frame_milka_refresh.metadata[0].name
            container {
              name    = "restart"
              image   = "bitnami/kubectl:latest"
              command = ["kubectl", "-n", "immich", "rollout", "restart", "deployment/${kubernetes_deployment.immich-frame-milka.metadata[0].name}"]
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "128Mi" }
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
