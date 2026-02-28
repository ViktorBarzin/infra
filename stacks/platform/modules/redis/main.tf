variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "redis" {
  metadata {
    name = "redis"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.redis.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Local PVC for Redis data — proper fsync, fast RDB saves
resource "kubernetes_persistent_volume_claim" "redis" {
  metadata {
    name      = "redis-data"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app  = "redis"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "redis"
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
        }
      }
      spec {
        # No init container needed — all Redis data is transient (queues, caches).
        # Starting fresh is safe; services rebuild their state automatically.

        container {
          image = "redis:7-alpine"
          name  = "redis"

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }
          }

          port {
            container_port = 6379
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.redis.metadata[0].name
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

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis"
    }
  }
  spec {
    selector = {
      app = "redis"
    }
    port {
      name = "redis"
      port = 6379
    }
  }
}

# Hourly backup: copy RDB snapshot to NFS for the TrueNAS → backup NAS pipeline
resource "kubernetes_cron_job_v1" "redis-backup" {
  metadata {
    name      = "redis-backup"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    schedule                      = "0 * * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 60
        template {
          metadata {}
          spec {
            container {
              name  = "redis-backup"
              image = "redis:7-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -eux
                # Trigger a fresh RDB save
                redis-cli -h redis.redis BGSAVE
                sleep 5
                # Copy the RDB from the running pod's data via redis
                redis-cli -h redis.redis --rdb /backup/dump.rdb
                echo "Backup complete: $(ls -lh /backup/dump.rdb)"
              EOT
              ]
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "backup"
              nfs {
                path   = "/mnt/main/redis-backup"
                server = var.nfs_server
              }
            }
          }
        }
      }
    }
  }
}
