variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }

# Nextcloud image tag, read by Renovate (docker.io/library/nextcloud). Majors
# step one at a time (32 -> 33 -> 34 -> 35): the image entrypoint refuses to
# skip a major. Before each hop: mysqldump of the nextcloud DB, a copy of
# config/ and data/, maintenance mode on, then occ upgrade after the roll.
# Never set this below the version in the DB; Nextcloud refuses a downgrade.
variable "nextcloud_image_tag" {
  type = string
  # renovate: datasource=docker depName=docker.io/library/nextcloud
  default = "32.0.15"
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "nextcloud"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.nextcloud.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
    labels = {
      "istio-injection" : "disabled"
      tier                                    = local.tiers.edge
      "resource-governance/custom-limitrange" = "true"
      "resource-governance/custom-quota"      = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "nextcloud-secrets"
      namespace = "nextcloud"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "nextcloud-secrets"
      }
      dataFrom = [{
        extract = {
          key = "nextcloud"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.nextcloud]
}

# DB credentials from Vault database engine (rotated every 24h)
# Nextcloud Helm chart reads password at runtime via existingSecret reference
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "nextcloud-db-creds"
      namespace = "nextcloud"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "nextcloud-db-creds"
        template = {
          data = {
            DB_PASSWORD = "{{ .password }}"
            db-username = "nextcloud"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/mysql-nextcloud"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.nextcloud]
}

resource "kubernetes_resource_quota" "nextcloud" {
  metadata {
    name      = "nextcloud-quota"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "8Gi"
      "limits.memory"   = "16Gi"
      pods              = "10"
    }
  }
}

resource "kubernetes_limit_range" "nextcloud" {
  metadata {
    name      = "nextcloud-limits"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "256Mi"
      }
      default_request = {
        cpu    = "25m"
        memory = "64Mi"
      }
      max = {
        memory = "8Gi"
      }
    }
  }
}

resource "helm_release" "nextcloud" {
  namespace = kubernetes_namespace.nextcloud.metadata[0].name
  name      = "nextcloud"

  repository      = "https://nextcloud.github.io/helm/"
  chart           = "nextcloud"
  # Not atomic: the image entrypoint runs `occ upgrade` before Apache starts,
  # so a failed rollout has usually migrated the DB already. An atomic rollback
  # would put the previous image on that DB, and Nextcloud refuses to start on
  # a newer schema. A failed release stays on the new image to fix forward.
  atomic          = false
  cleanup_on_fail = false
  version         = "8.8.1"

  values     = [templatefile("${path.module}/chart_values.yaml", { tls_secret_name = var.tls_secret_name, mysql_host = var.mysql_host, image_tag = var.nextcloud_image_tag })]
  timeout    = 6000
  depends_on = [kubernetes_manifest.db_external_secret]
}

resource "kubernetes_config_map" "apache_tuning" {
  metadata {
    name      = "nextcloud-apache-tuning"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  data = {
    "mpm_prefork.conf" = <<-EOF
      # Tuned for Nextcloud on MySQL
      # Capped MaxRequestWorkers to prevent runaway Apache consuming all node CPU
      <IfModule mpm_prefork_module>
        StartServers            5
        MinSpareServers         3
        MaxSpareServers         10
        MaxRequestWorkers       30
        MaxConnectionsPerChild  500
      </IfModule>
    EOF
  }
}

# resource "kubernetes_config_map" "config" {
#   metadata {
#     name      = "config"
#    namespace = kubernetes_namespace.nextcloud.metadata[0].name

#     annotations = {
#       "reloader.stakater.com/match" = "true"
#     }
#   }

#   data = {
#     "conf.yml" = file("${path.module}/conf.yml")
#   }
# }

resource "kubernetes_persistent_volume_claim" "nextcloud_data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "nextcloud-data-encrypted"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "20%"
      "resize.topolvm.io/storage_limit" = "100Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

module "nfs_nextcloud_backup_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "nextcloud-backup-host"
  namespace          = kubernetes_namespace.nextcloud.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/nextcloud-backup"
  storage_class_name = "nfs-pve"
}

module "nfs_pve_root_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "nextcloud-pve-nfs-root"
  namespace          = kubernetes_namespace.nextcloud.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs"
  storage            = "3000Gi"
  storage_class_name = "nfs-pve"
}

module "nfs_pve_ssd_root_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "nextcloud-pve-nfs-ssd-root"
  namespace          = kubernetes_namespace.nextcloud.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs-ssd"
  storage            = "100Gi"
  storage_class_name = "nfs-pve"
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Native WebDAV / CalDAV / CardDAV clients (Nextcloud desktop+mobile apps,
  # calendar sync) use HTTP basic-auth + app passwords, not browser sessions.
  # Nextcloud has strong app-layer auth of its own.
  # auth = "app": Native WebDAV / CalDAV / CardDAV clients use HTTP Basic auth + app passwords; Nextcloud enforces app-layer authentication.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.nextcloud.metadata[0].name
  name            = "nextcloud"
  tls_secret_name = var.tls_secret_name
  port            = 8080
  # Fix Apple CalDAV/CardDAV discovery (2026-07-19). Nextcloud's shipped
  # .htaccess redirects /.well-known/{caldav,carddav} -> /remote.php/dav/ but
  # builds the redirect from apache's own scheme; behind Traefik's TLS
  # termination apache sees http, so it emits an http:// Location. Apple's
  # ATS-hardened dataaccessd refuses the https->http downgrade, discovery fails
  # (405 "can't figure out its principalPath") and the account degrades to
  # read-only (reads work off cached collection URLs, writes never leave the
  # device). This middleware answers discovery at the ingress with a clean
  # https redirect, before the request reaches Nextcloud. See
  # kubernetes_manifest.wellknown_dav_redirect below.
  extra_middlewares = ["nextcloud-wellknown-dav@kubernetescrd"]
  extra_annotations = {
    "gethomepage.dev/enabled"         = "true"
    "gethomepage.dev/name"            = "Nextcloud"
    "gethomepage.dev/description"     = "Cloud productivity suite"
    "gethomepage.dev/icon"            = "nextcloud.png"
    "gethomepage.dev/group"           = "Productivity"
    "gethomepage.dev/pod-selector"    = ""
    "gethomepage.dev/widget.type"     = "nextcloud"
    "gethomepage.dev/widget.url"      = "https://nextcloud.viktorbarzin.me"
    "gethomepage.dev/widget.username" = local.homepage_credentials["nextcloud"]["username"]
    "gethomepage.dev/widget.password" = local.homepage_credentials["nextcloud"]["password"]
  }
}

# Traefik Middleware: answer CalDAV/CardDAV service discovery with a clean
# *https* redirect so Apple clients (dataaccessd) can resolve their principalPath
# and push writes. Referenced by module.ingress as
# "nextcloud-wellknown-dav@kubernetescrd" (Traefik cross-provider ref format
# "<namespace>-<name>@kubernetescrd"). Root cause + why this lives at Traefik
# rather than in Nextcloud: see the extra_middlewares comment on module.ingress.
resource "kubernetes_manifest" "wellknown_dav_redirect" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "wellknown-dav"
      namespace = kubernetes_namespace.nextcloud.metadata[0].name
    }
    spec = {
      redirectRegex = {
        # Match the full URL; capture the host so the redirect preserves it.
        regex       = "^https?://([^/]+)/\\.well-known/(caldav|carddav)/?$"
        replacement = "https://$${1}/remote.php/dav/"
        permanent   = true
      }
    }
  }
}


# Hook script: sync DB password from env var into config.php on every pod start.
# Closes the Vault rotation gap: Vault rotates MySQL password → ESO syncs to K8s Secret →
# Reloader restarts pod → this hook patches config.php with the current MYSQL_PASSWORD.
resource "kubernetes_config_map" "db_password_sync_hook" {
  metadata {
    name      = "nextcloud-db-password-sync"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  data = {
    "sync-db-password.sh" = <<-EOF
      #!/bin/bash
      set -e
      CONFIG="/var/www/html/config/config.php"
      if [ -z "$MYSQL_PASSWORD" ]; then
        echo "MYSQL_PASSWORD not set, skipping config.php sync"
        exit 0
      fi
      if [ ! -f "$CONFIG" ]; then
        echo "config.php not found, skipping (first install)"
        exit 0
      fi
      CURRENT_PW=$(php -r "include '$CONFIG'; echo \$CONFIG['dbpassword'] ?? '';")
      if [ "$CURRENT_PW" = "$MYSQL_PASSWORD" ]; then
        echo "DB password in config.php already matches MYSQL_PASSWORD"
        exit 0
      fi
      echo "Updating DB password in config.php to match MYSQL_PASSWORD..."
      php /docker-entrypoint-hooks.d/before-starting/patch-db-pw.php "$CONFIG" "$MYSQL_PASSWORD"
      echo "DB password updated successfully"
    EOF

    "patch-db-pw.php" = <<-EOF
      <?php
      $file = $argv[1];
      $newPw = $argv[2];
      $content = file_get_contents($file);
      $escaped = str_replace(["'", "\\"], ["\\'", "\\\\"], $newPw);
      $content = preg_replace("/'dbpassword'\\s*=>\\s*'[^']*'/", "'dbpassword' => '" . $escaped . "'", $content);
      file_put_contents($file, $content);
    EOF
  }
}

resource "kubernetes_config_map" "backup-script" {
  metadata {
    name      = "nextcloud-backup-script"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  data = {
    "backup.sh" = <<-EOF
      #!/bin/bash
      set -e

      BACKUP_DIR="/backup"
      DATA_DIR="/nextcloud-data"
      DATE=$(date +%Y%m%d_%H%M%S)
      BACKUP_PATH="$BACKUP_DIR/$DATE"

      echo "Starting Nextcloud backup at $(date)"

      # Note: Maintenance mode is skipped because occ is not available in the NFS mount.
      # For a proper backup with maintenance mode, exec into the nextcloud pod:
      #   kubectl exec -n nextcloud deployment/nextcloud -- php occ maintenance:mode --on

      # Create backup directory
      mkdir -p "$BACKUP_PATH"

      # Backup config/data/custom_apps. Exclusions (2026-06-01 space fix):
      #  - nextcloud.log* — rotated at source via log_rotate_size; previously
      #    grew to 10GB+ and bloated every dated copy (backups hit 20G each).
      #  - preview cache — regenerable thumbnails, no need to back up.
      # Backs up config/, data/, custom_apps/ (the irreplaceable bits). Skips:
      #  - html/ — the Nextcloud app code, reproducible from the pinned image
      #    (real config is at config/config.php; html/config/config.php is empty).
      #  - nextcloud.log* — capped at source via log_rotate_size; was 10GB+.
      #  - preview cache — regenerable thumbnails.
      echo "Backing up Nextcloud installation..."
      rsync -a \
        --exclude='/html/' \
        --exclude='nextcloud.log' \
        --exclude='nextcloud.log.*' \
        --exclude='data/appdata_*/preview/' \
        "$DATA_DIR/" "$BACKUP_PATH/"

      # Keep only the latest backup. The version history lives in daily-backup's
      # pvc-data (4 weekly snapshot-consistent copies of this same encrypted PVC),
      # so this browsable app-level copy only needs the most recent. Keeping the
      # whole installation (incl. logs) x7 here was the bulk of the 87G that
      # filled the offsite Synology.
      #
      # Sort by NAME, not mtime: dirs are YYYYMMDD_HHMMSS so lexical order is
      # chronological. `rsync -a` stamps the backup dir with the SOURCE dir's
      # mtime, which made the old `ls -dt | tail` delete the freshest backup and
      # keep a stale one — keep the lexically-last (newest) instead.
      echo "Cleaning old backups (keep latest)..."
      cd "$BACKUP_DIR"
      ls -d */ 2>/dev/null | sort | head -n -1 | xargs -r rm -rf

      echo "Backup completed at $(date)"
      echo "Backup stored at: $BACKUP_PATH"
    EOF

    "restore.sh" = <<-EOF
      #!/bin/bash
      # Restore script - run manually when needed
      # Usage: ./restore.sh <backup_date>
      # Example: ./restore.sh 20250117_030000
      #
      # Before restoring, enable maintenance mode:
      #   kubectl exec -n nextcloud deployment/nextcloud -- php occ maintenance:mode --on
      # After restoring, disable it:
      #   kubectl exec -n nextcloud deployment/nextcloud -- php occ maintenance:mode --off

      set -e

      if [ -z "$1" ]; then
        echo "Usage: $0 <backup_date>"
        echo "Available backups:"
        ls -1 /backup/
        exit 1
      fi

      BACKUP_PATH="/backup/$1"
      DATA_DIR="/nextcloud-data"

      if [ ! -d "$BACKUP_PATH" ]; then
        echo "Backup not found: $BACKUP_PATH"
        exit 1
      fi

      echo "Restoring from $BACKUP_PATH"

      # Restore everything
      echo "Restoring Nextcloud installation..."
      rsync -a "$BACKUP_PATH/" "$DATA_DIR/"

      echo "Restore completed!"
      echo "Remember to run: kubectl exec -n nextcloud deployment/nextcloud -- php occ maintenance:mode --off"
    EOF
  }
}

# Watchdog: runs every 5 minutes with two jobs:
#  1. Apache runaway recovery — if >40 workers (normal 5-15), rollout-restart
#     to recover node CPU.
#  2. F1 self-heal — if occ reports needsDbUpgrade=true (an interrupted
#     `occ upgrade` after an image bump left the app in maintenance mode),
#     re-run `occ upgrade` and clear maintenance mode.
resource "kubernetes_service_account" "nextcloud_watchdog" {
  metadata {
    name      = "nextcloud-watchdog"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

resource "kubernetes_role" "nextcloud_watchdog" {
  metadata {
    name      = "nextcloud-watchdog"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "get"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "nextcloud_watchdog" {
  metadata {
    name      = "nextcloud-watchdog"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.nextcloud_watchdog.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextcloud_watchdog.metadata[0].name
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "nextcloud_watchdog" {
  metadata {
    name      = "nextcloud-watchdog"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    # Suspended while the 32 -> 35 major hops run (2026-10-12): its F1 branch
    # would start a second `occ upgrade` next to the entrypoint's, and F3 would
    # clear a maintenance flag the upgrade still needs.
    suspend = true
    # */30 since 2026-08-16 (was */5). At 5-minute granularity this was 288 pod
    # creations a day, and on this host that is not free — each pod create and
    # destroy writes containerd overlay layers, a kubelet pod dir, /var/log/pods
    # and a systemd transient scope plus the ext4 journal metadata for all of
    # it, and k8s node root disks are 43% of sdc's write IOPS with cronjob churn
    # as the driver.
    #
    # Both self-heals below were measured quiet over Loki's full 30-day
    # retention: 0 runaway detections, 0 restarts, 0 stuck-maintenance clears.
    # Apache workers ran min 7 / median 11 / max 17 against a threshold of 40,
    # so the runaway check has ~2.3x headroom before it would even trip.
    #
    # It is deliberately SLOWED rather than removed. The maintenance-mode
    # self-heal is the ONLY detection for a failure that has twice caused a
    # multi-hour silent outage (~20.5h, and the ~22h 2026-05-26 incident) and
    # that the health probes structurally CANNOT see — all three hit
    # /status.php, which answers 200 in maintenance mode, so the pod reads Ready
    # throughout. Against ~20h undetected, a slower check is still a large win.
    #
    # NOTE the interaction with MAINT_GRACE_MIN=30 in the script: it only clears
    # a flag that has been set for at least 30 minutes, so at a 30-minute
    # cadence the worst case to clear becomes ~60 minutes rather than ~30. That
    # is the accepted cost of this change; shorten the cadence (not the grace,
    # which exists to protect deliberate maintenance windows) if it ever bites.
    schedule                      = "*/30 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"

    job_template {
      metadata {}
      spec {
        # 600s (was 120s) so the F1 self-heal `occ upgrade` isn't killed
        # mid-migration. concurrency_policy=Forbid prevents overlap.
        active_deadline_seconds = 600
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.nextcloud_watchdog.metadata[0].name
            restart_policy       = "Never"

            container {
              name  = "watchdog"
              image = "bitnami/kubectl:latest"

              command = ["/bin/bash", "-c", <<-EOF
                set -e
                # Find the nextcloud pod
                POD=$(kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                if [ -z "$POD" ]; then
                  echo "No nextcloud pod found, skipping"
                  exit 0
                fi

                # Count Apache worker processes (exclude grep itself and the parent apache2 process)
                WORKERS=$(kubectl exec -n nextcloud "$POD" -c nextcloud -- pgrep -c apache2 2>/dev/null || echo "0")
                echo "$(date): Apache worker count: $WORKERS"

                # Normal operation: 5-15 workers. Runaway threshold: 40+
                if [ "$WORKERS" -gt 40 ]; then
                  echo "RUNAWAY DETECTED: $WORKERS Apache workers (threshold: 40)"
                  echo "Restarting nextcloud deployment..."
                  kubectl rollout restart deployment nextcloud -n nextcloud
                  echo "Restart triggered at $(date)"
                else
                  echo "Apache workers within normal range ($WORKERS <= 40)"
                fi

                # F1 self-heal: an image bump runs `occ upgrade` in the
                # entrypoint, but if that's interrupted (e.g. a probe restart
                # mid-upgrade) occ reports needsDbUpgrade=true and the app sits
                # in maintenance mode (503). Re-run the upgrade and clear
                # maintenance mode. Gated on needsDbUpgrade only, so a
                # deliberate manual maintenance window is left untouched.
                ST=$(kubectl exec -n nextcloud "$POD" -c nextcloud -- php occ status --output=json 2>/dev/null || true)
                if echo "$ST" | grep -q '"needsDbUpgrade":true'; then
                  echo "$(date): needsDbUpgrade=true → running occ upgrade"
                  kubectl exec -n nextcloud "$POD" -c nextcloud -- php occ upgrade --no-interaction || true
                  kubectl exec -n nextcloud "$POD" -c nextcloud -- php occ maintenance:mode --off || true
                  echo "$(date): self-heal occ upgrade complete"
                else
                  echo "$(date): occ status healthy (no DB upgrade pending)"
                fi

                # F3 self-heal: maintenance mode stuck ON while the DB upgrade
                # is already COMPLETE (maintenance=true + needsDbUpgrade=false).
                # F1 above gates on needsDbUpgrade, so this quadrant had no
                # cover: on 2026-08-15 an image bump finished its occ upgrade but
                # never cleared maintenance mode, and every client 503'd for
                # ~20.5h while this watchdog logged "healthy" every 5 min. The
                # probes did not catch it either — all three hit /status.php,
                # which answers 200 in maintenance mode, so the pod stayed
                # Ready. Same class as the ~22h 2026-05-26 incident noted at the
                # top of this file. (Do NOT "fix" this by pointing the probes at
                # an endpoint that fails in maintenance mode: the liveness probe
                # would then restart the pod mid-upgrade, which is exactly how
                # F1 gets created.)
                #
                # A DELIBERATE maintenance window is protected by a grace
                # period rather than a flag: `occ maintenance:mode --on`
                # rewrites config.php, so its mtime is how long the mode has
                # been on. For a planned window longer than the grace, suspend
                # this CronJob:
                #   kubectl -n nextcloud patch cronjob nextcloud-watchdog \
                #     -p '{"spec":{"suspend":true}}'
                MAINT_GRACE_MIN=30
                if echo "$ST" | grep -q '"maintenance":true' && echo "$ST" | grep -q '"needsDbUpgrade":false'; then
                  CFG_MTIME=$(kubectl exec -n nextcloud "$POD" -c nextcloud -- stat -c %Y /var/www/html/config/config.php 2>/dev/null || echo 0)
                  MAINT_MIN=0
                  if [ "$CFG_MTIME" -gt 0 ]; then
                    MAINT_MIN=$(( ($(date +%s) - CFG_MTIME) / 60 ))
                  fi
                  if [ "$MAINT_MIN" -ge "$MAINT_GRACE_MIN" ]; then
                    echo "$(date): maintenance mode ON ~$MAINT_MIN min with no pending DB upgrade -> clearing stuck flag"
                    kubectl exec -n nextcloud "$POD" -c nextcloud -- php occ maintenance:mode --off || true
                  else
                    echo "$(date): maintenance mode ON ~$MAINT_MIN min (grace $MAINT_GRACE_MIN min) -> leaving alone"
                  fi
                fi
              EOF
              ]
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

resource "kubernetes_cron_job_v1" "nextcloud-backup" {
  metadata {
    name      = "nextcloud-backup"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    schedule                      = "0 3 * * 0" # Sunday at 3 AM
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"

    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"

            # Backup mounts the same RWO PVC (proxmox-lvm-encrypted) as the
            # main nextcloud pod, so it MUST schedule on the same node — the
            # volume cannot attach to two nodes simultaneously. Without this
            # the backup pod is stuck in ContainerCreating until cron retries.
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      "app.kubernetes.io/name"     = "nextcloud"
                      "app.kubernetes.io/instance" = "nextcloud"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                  namespaces   = [kubernetes_namespace.nextcloud.metadata[0].name]
                }
              }
            }

            container {
              name  = "backup"
              image = "alpine:latest"

              command = ["/bin/sh", "-c", "apk add --no-cache rsync bash && /scripts/backup.sh"]

              volume_mount {
                name       = "nextcloud-data"
                mount_path = "/nextcloud-data"
              }

              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
            }

            volume {
              name = "nextcloud-data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.nextcloud_data_encrypted.metadata[0].name
              }
            }

            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_nextcloud_backup_host.claim_name
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.backup-script.metadata[0].name
                default_mode = "0755"
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

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
