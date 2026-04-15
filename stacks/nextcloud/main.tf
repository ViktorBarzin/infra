variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }

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
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "nextcloud-secrets"
      namespace = "nextcloud"
    }
    spec = {
      refreshInterval = "15m"
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
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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

  repository = "https://nextcloud.github.io/helm/"
  chart      = "nextcloud"
  atomic     = true
  version    = "8.8.1"

  values     = [templatefile("${path.module}/chart_values.yaml", { tls_secret_name = var.tls_secret_name, mysql_host = var.mysql_host })]
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
      "resize.topolvm.io/threshold"     = "80%"
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
}

module "nfs_nextcloud_backup_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "nextcloud-backup-host"
  namespace  = kubernetes_namespace.nextcloud.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/nextcloud-backup"
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.nextcloud.metadata[0].name
  name            = "nextcloud"
  tls_secret_name = var.tls_secret_name
  port            = 8080
  rybbit_site_id  = "5a3bfe59a3fe"
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

      # Backup everything (config, data, custom_apps, themes, etc.)
      echo "Backing up Nextcloud installation..."
      rsync -a "$DATA_DIR/" "$BACKUP_PATH/"

      # Keep only last 7 backups
      echo "Cleaning old backups..."
      cd "$BACKUP_DIR"
      ls -dt */ | tail -n +8 | xargs -r rm -rf

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

# Watchdog: auto-restart Nextcloud when Apache workers go runaway
# Checks every 5 minutes if Apache has >40 active workers (normal is 5-15).
# If runaway detected, restarts the deployment to recover node CPU.
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
    schedule                      = "*/5 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"

    job_template {
      metadata {}
      spec {
        active_deadline_seconds = 120
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
              EOF
              ]
            }
          }
        }
      }
    }
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
}
