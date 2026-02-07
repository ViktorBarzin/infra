variable "tls_secret_name" {}
variable "db_password" {}
variable "tier" { type = string }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.nextcloud.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
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

  values  = [templatefile("${path.module}/chart_values.yaml", { tls_secret_name = var.tls_secret_name, db_password = var.db_password })]
  timeout = 6000
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

resource "kubernetes_deployment" "whiteboard" {
  metadata {
    name      = "whiteboard"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
    labels = {
      app  = "whiteboard"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "whiteboard"
      }
    }
    template {
      metadata {
        labels = {
          app = "whiteboard"
        }
      }
      spec {
        container {
          image = "ghcr.io/nextcloud-releases/whiteboard:release"
          name  = "whiteboard"

          port {
            container_port = 3002
          }
          env {
            name  = "NEXTCLOUD_URL"
            value = "http://nextcloud:8080"
          }
          env {
            name  = "JWT_SECRET_KEY"
            value = var.db_password # anything secret is fine
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whiteboard" {
  metadata {
    name      = "whiteboard"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
    labels = {
      app = "whiteboard"
    }
  }

  spec {
    selector = {
      app = "whiteboard"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3002
    }
  }
}

resource "kubernetes_persistent_volume" "nextcloud-data-pv" {
  metadata {
    name = "nextcloud-data-pv"
  }
  spec {
    capacity = {
      "storage" = "100Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/nextcloud"
        server = "10.0.10.15"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "nextcloud-data-pvc" {
  metadata {
    name      = "nextcloud-data-pvc"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        "storage" = "100Gi"
      }
    }
    volume_name = "nextcloud-data-pv"
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.nextcloud.metadata[0].name
  name            = "nextcloud"
  tls_secret_name = var.tls_secret_name
  port            = 8080
  rybbit_site_id  = "5a3bfe59a3fe"
}

module "whiteboard_ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.nextcloud.metadata[0].name
  name            = "whiteboard"
  tls_secret_name = var.tls_secret_name
  port            = 80
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
              nfs {
                server = "10.0.10.15"
                path   = "/mnt/main/nextcloud"
              }
            }

            volume {
              name = "backup"
              nfs {
                server = "10.0.10.15"
                path   = "/mnt/main/nextcloud-backup"
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
