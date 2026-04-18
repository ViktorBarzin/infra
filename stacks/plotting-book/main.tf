variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "plotting-book" {
  metadata {
    name = "plotting-book"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "plotting-book-secrets"
      namespace = "plotting-book"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "plotting-book-secrets"
      }
      dataFrom = [{
        extract = {
          key = "plotting-book"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.plotting-book]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.plotting-book.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "plotting-book-data" {
  metadata {
    name      = "plotting-book-data-proxmox"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    labels = {
      app  = "plotting-book"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  lifecycle {
    # DRIFT_WORKAROUND: CI pipeline owns image tag (kubectl set image from Woodpecker/GHA). Reviewed 2026-04-18.
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
    ]
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "plotting-book"
      }
    }
    template {
      metadata {
        labels = {
          app = "plotting-book"
        }
      }
      spec {
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.plotting-book-data.metadata[0].name
          }
        }
        container {
          image = "ancamilea/book-plotter:latest"
          # image = "viktorbarzin/book-plotter:7"
          name              = "plotting-book"
          image_pull_policy = "Always"
          env {
            name = "SESSION_SECRET"
            value_from {
              secret_key_ref {
                name = "plotting-book-secrets"
                key  = "session_secret"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "plotting-book-secrets"
                key  = "google_client_id"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "plotting-book-secrets"
                key  = "google_client_secret"
              }
            }
          }
          env {
            name  = "GOOGLE_CALLBACK_URL"
            value = "https://plotting-book.viktorbarzin.me/api/auth/google/callback"
          }
          env {
            name  = "DB_PATH"
            value = "/data/database.sqlite"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          port {
            container_port = 3001
          }
          resources {
            requests = {
              memory = "128Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    labels = {
      "app" = "plotting-book"
    }
  }

  spec {
    selector = {
      app = "plotting-book"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3001
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.plotting-book.metadata[0].name
  name            = "plotting-book"
  tls_secret_name = var.tls_secret_name

  custom_content_security_policy = "default-src 'self' blob: data:; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; worker-src 'self' blob:; connect-src 'self' blob: https://accounts.google.com; form-action 'self' https://accounts.google.com; frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Plotting Book"
    "gethomepage.dev/description"  = "Interactive fiction"
    "gethomepage.dev/icon"         = "mdi-book-open-variant"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# -----------------------------------------------------------------------------
# Backup — Weekly SQLite backup to NFS
# -----------------------------------------------------------------------------

module "nfs_plotting_book_backup_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "plotting-book-backup-host"
  namespace  = kubernetes_namespace.plotting-book.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/plotting-book-backup"
}

resource "kubernetes_cron_job_v1" "plotting_book_backup" {
  metadata {
    name      = "plotting-book-backup"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    schedule                      = "0 3 * * 0"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "plotting-book"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "plotting-book-backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache sqlite
                now=$(date +"%Y_%m_%d_%H_%M")
                mkdir -p /backup/$now
                sqlite3 /data/database.sqlite ".backup /backup/$now/database.sqlite"
                # Rotate — 30 day retention
                find /backup -maxdepth 1 -mindepth 1 -type d -mtime +30 -exec rm -rf {} +
                echo "Backup complete: $now"
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
                requests = {
                  memory = "32Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.plotting-book-data.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_plotting_book_backup_host.claim_name
              }
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
            }
          }
        }
      }
    }
  }
}

# Sealed Secrets — encrypted secrets safe to commit to git
resource "kubernetes_manifest" "sealed_secrets" {
  for_each = fileset(path.module, "sealed-*.yaml")
  manifest = yamldecode(file("${path.module}/${each.value}"))
}
