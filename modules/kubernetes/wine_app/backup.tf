# Daily copy of the Wine prefix to NFS /srv/nfs/<name>-backup (the
# storage-backup.md convention for proxmox-lvm apps), as hardlinked rsync
# generations so an unchanged 3 GB prefix costs almost nothing per day.
# Keeps 14 generations. The directory must exist on the PVE host first
# (docs/runbooks/nfs-prerequisites.md).
#
# The volume is RWO. The app is normally asleep at backup time; if it is awake
# on another node the job waits for the attach until its deadline and tries
# again the next day. A copy taken while the app runs can catch its database
# mid-write, which is why the schedule sits in the night.
resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "${var.name}-backup"
    namespace = var.namespace
    labels    = { app = var.name, component = "backup" }
  }
  spec {
    schedule                      = var.backup_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 2
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 3600
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 7200
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = var.name, component = "backup" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "backup"
              image = "alpine:3.24"
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                apk add --no-cache rsync >/dev/null
                now=$(date +%Y-%m-%dT%H-%M-%S)
                last=$(ls -1d /backup/20* 2>/dev/null | tail -1 || true)
                if [ -n "$last" ]; then
                  rsync -a --delete --link-dest="$last" /data/ "/backup/$now.partial/"
                else
                  rsync -a --delete /data/ "/backup/$now.partial/"
                fi
                mv "/backup/$now.partial" "/backup/$now"
                rm -rf /backup/*.partial
                ls -1d /backup/20* | head -n -14 | xargs -r rm -rf
                echo "backup complete: /backup/$now ($(du -sh "/backup/$now" | cut -f1) apparent)"
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/data"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "256Mi" }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.prefix.metadata[0].name
                read_only  = true
              }
            }
            volume {
              name = "backup"
              nfs {
                server = var.nfs_server
                path   = "/srv/nfs/${var.name}-backup"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
