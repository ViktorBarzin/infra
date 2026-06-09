# Automatic Google Drive -> site sync (added 2026-06-09; supersedes the
# earlier on-demand-only model now that content is actively maintained).
#
# A CronJob mirrors the READ-ONLY Drive folder "claude" (servable content in
# subfolder "stem claude/files/") onto the NFS content volume every 10 min via
# rclone. rclone is delta-aware: an unchanged run lists ~33 files' metadata and
# transfers nothing, so the schedule is cheap (not a 24MB re-download). nginx
# keeps serving the same volume read-only; updates appear within ~5s (actimeo).
#
# Drive is treated strictly READ-ONLY: scope=drive.readonly and rclone only ever
# reads the remote (sync gdrive: -> /data), never writes back.
#
# TOKEN LONGEVITY: the GCP OAuth app (project home-lab-1700868541205) MUST be
# published to "Production" or its refresh token expires ~weekly and this job
# fails. After publishing, re-mint the token and refresh
# `secret/stem95su.rclone_conf`. A failed run surfaces as a failed Job.

resource "kubernetes_manifest" "rclone_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "stem95su-rclone"
      namespace = kubernetes_namespace.stem95su.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = { name = "stem95su-rclone" }
      data = [{
        secretKey = "rclone.conf"
        remoteRef = {
          key      = "stem95su"
          property = "rclone_conf"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.stem95su]
}

resource "kubernetes_cron_job_v1" "gdrive_sync" {
  metadata {
    name      = "stem95su-gdrive-sync"
    namespace = kubernetes_namespace.stem95su.metadata[0].name
    labels    = { run = "stem95su", component = "gdrive-sync" }
  }
  spec {
    schedule                      = "*/10 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 2
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata { labels = { run = "stem95su", component = "gdrive-sync" } }
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "rclone"
              image = "docker.io/rclone/rclone:1.74.3"
              # Mirror Drive folder -> /data. Guard: hard-fail on auth/list error
              # (so an expired token is visible); skip quietly if the source is
              # empty / missing the dashboard (never wipe the live site);
              # --max-delete caps catastrophic deletes from a partial listing.
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                cp /config/rclone.conf /tmp/rc.conf
                SRC="gdrive:stem claude/files"
                LIST=$(rclone --config /tmp/rc.conf lsf "$SRC" --files-only) || { echo "FATAL: Drive list failed (auth/network)"; exit 1; }
                N=$(printf '%s\n' "$LIST" | grep -c . || true)
                if [ "$N" -lt 1 ] || ! printf '%s\n' "$LIST" | grep -qx "stem_board.html"; then
                  echo "GUARD: source N=$N / stem_board.html missing -- skipping, site untouched"; exit 0
                fi
                echo "source OK ($N files) -- mirroring to /data"
                rclone --config /tmp/rc.conf sync "$SRC" /data --exclude ".DS_Store" --fast-list --transfers 4 --max-delete 25 -v
              EOT
              ]
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "192Mi" }
              }
              volume_mount {
                name       = "rclone-config"
                mount_path = "/config"
                read_only  = true
              }
              volume_mount {
                name       = "content"
                mount_path = "/data"
              }
            }
            volume {
              name = "rclone-config"
              secret { secret_name = "stem95su-rclone" }
            }
            volume {
              name = "content"
              persistent_volume_claim {
                claim_name = module.nfs_content.claim_name
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
  depends_on = [kubernetes_manifest.rclone_external_secret]
}
