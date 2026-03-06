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

# Redis with Sentinel HA via Bitnami Helm chart
# Architecture: 1 master + 2 replicas + 3 sentinels
# Sentinel automatically promotes a replica if master fails
# The K8s Service always points at the current master
resource "helm_release" "redis" {
  namespace        = kubernetes_namespace.redis.metadata[0].name
  create_namespace = false
  name             = "redis"
  atomic           = true
  timeout          = 600

  repository = "oci://10.0.20.10:5000/bitnamicharts"
  chart      = "redis"
  version    = "25.3.2"

  values = [yamlencode({
    architecture = "replication"

    auth = {
      enabled = false
    }

    sentinel = {
      enabled         = true
      quorum          = 2
      masterSet       = "mymaster"
      automateCluster = true

      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "128Mi"
        }
      }
    }

    master = {
      persistence = {
        enabled      = true
        storageClass = "iscsi-truenas"
        size         = "2Gi"
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "256Mi"
        }
      }
    }

    replica = {
      replicaCount = 2

      persistence = {
        enabled      = true
        storageClass = "iscsi-truenas"
        size         = "2Gi"
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "256Mi"
        }
      }
    }

    # Metrics for Prometheus
    metrics = {
      enabled = false
    }

    # Use the existing service name so clients don't need changes
    # Sentinel-enabled Bitnami chart creates a headless service
    # and a regular service pointing at the master
    nameOverride = "redis"
  })]
}

# Override the Helm-managed service to pin to master pod
# Sentinel clients can use the headless service for discovery,
# but simple redis:// clients (paperless-ngx, etc.) need to hit the master
resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  spec {
    selector = {
      "app.kubernetes.io/component"        = "node"
      "app.kubernetes.io/instance"         = "redis"
      "app.kubernetes.io/name"             = "redis"
      "statefulset.kubernetes.io/pod-name" = "redis-node-0"
    }
    port {
      name        = "tcp-redis"
      port        = 6379
      target_port = 6379
    }
    port {
      name        = "tcp-sentinel"
      port        = 26379
      target_port = 26379
    }
  }

  depends_on = [helm_release.redis]
}

module "nfs_backup" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "redis-backup"
  namespace  = kubernetes_namespace.redis.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/redis-backup"
}

# Hourly backup: copy RDB snapshot from master to NFS
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
                # Trigger a fresh RDB save on the master
                redis-cli -h redis.redis BGSAVE
                sleep 5
                # Copy the RDB via redis-cli --rdb
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
              persistent_volume_claim {
                claim_name = module.nfs_backup.claim_name
              }
            }
          }
        }
      }
    }
  }
}
