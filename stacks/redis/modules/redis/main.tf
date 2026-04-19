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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.redis.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Redis with Sentinel HA via Bitnami Helm chart
# Architecture: 1 master + 1 replica + 2 sentinels (one per node)
# Sentinel automatically promotes a replica if master fails
# HAProxy sits in front and routes only to the current master (see below)
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
          memory = "64Mi"
        }
      }
    }

    master = {
      persistence = {
        enabled      = true
        storageClass = "proxmox-lvm-encrypted"
        size         = "2Gi"
        annotations = {
          "resize.topolvm.io/threshold"     = "80%"
          "resize.topolvm.io/increase"      = "50%"
          "resize.topolvm.io/storage_limit" = "10Gi"
        }
      }

      # 64Mi was too tight: replica OOMed during PSYNC full resync
      # (master steady-state 21Mi + COW during AOF rewrite + RDB transfer
      # buffer pushed replica RSS past 64Mi, causing 120 restart loops over
      # 5+ days before bump to 256Mi).
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          memory = "256Mi"
        }
      }
    }

    replica = {
      replicaCount = 2

      persistence = {
        enabled      = true
        storageClass = "proxmox-lvm-encrypted"
        size         = "2Gi"
        annotations = {
          "resize.topolvm.io/threshold"     = "80%"
          "resize.topolvm.io/increase"      = "50%"
          "resize.topolvm.io/storage_limit" = "10Gi"
        }
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "256Mi"
        }
        limits = {
          memory = "256Mi"
        }
      }
    }

    # Metrics for Prometheus
    metrics = {
      enabled = false
    }

    # Disable the Helm chart's ClusterIP service — we manage our own
    # that points to HAProxy (master-only routing). The headless service
    # is still needed for StatefulSet pod DNS resolution.
    nameOverride = "redis"
  })]
}

# HAProxy-based master-only proxy for simple redis:// clients.
# Health-checks each Redis node via INFO replication and only routes
# to the current master. On Sentinel failover, HAProxy detects the
# new master within seconds via its health check interval.
# Previously this was a K8s Service that routed to all nodes, causing
# READONLY errors when clients hit a replica.

resource "kubernetes_config_map" "haproxy" {
  metadata {
    name      = "redis-haproxy"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  data = {
    "haproxy.cfg" = <<-EOT
      global
        maxconn 256

      defaults
        mode tcp
        timeout connect 5s
        timeout client  30s
        timeout server  30s
        timeout check   3s

      # Dynamic DNS resolution via cluster CoreDNS. Without this, haproxy
      # resolves server hostnames once at startup and caches forever, so
      # when redis-node-X pods restart and get new IPs, haproxy keeps
      # connecting to the old (dead) IPs and returns "Connection refused"
      # until haproxy itself is restarted. This caused an immich outage
      # on 2026-04-19 after a redis pod cycle.
      resolvers kubernetes
        nameserver coredns kube-dns.kube-system.svc.cluster.local:53
        resolve_retries 3
        timeout resolve 1s
        timeout retry   1s
        hold other      10s
        hold refused    10s
        hold nx         10s
        hold timeout    10s
        hold valid      10s
        hold obsolete   10s

      frontend redis_front
        bind *:6379
        default_backend redis_master

      frontend sentinel_front
        bind *:26379
        default_backend redis_sentinel

      backend redis_master
        option tcp-check
        tcp-check connect
        tcp-check send "PING\r\n"
        tcp-check expect string +PONG
        tcp-check send "INFO replication\r\n"
        # Match "role:master" only — cannot appear in slave responses
        # (slave has "role:slave" then "master_host:..." which doesn't match)
        tcp-check expect rstring role:master
        tcp-check send "QUIT\r\n"
        tcp-check expect string +OK
        server redis-node-0 redis-node-0.redis-headless.redis.svc.cluster.local:6379 check inter 1s fall 2 rise 2 resolvers kubernetes init-addr last,libc,none
        server redis-node-1 redis-node-1.redis-headless.redis.svc.cluster.local:6379 check inter 1s fall 2 rise 2 resolvers kubernetes init-addr last,libc,none

      backend redis_sentinel
        balance roundrobin
        server redis-node-0 redis-node-0.redis-headless.redis.svc.cluster.local:26379 check inter 5s resolvers kubernetes init-addr last,libc,none
        server redis-node-1 redis-node-1.redis-headless.redis.svc.cluster.local:26379 check inter 5s resolvers kubernetes init-addr last,libc,none
    EOT
  }
}

resource "kubernetes_deployment" "haproxy" {
  metadata {
    name      = "redis-haproxy"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis-haproxy"
    }
  }
  spec {
    replicas = 2
    selector {
      match_labels = {
        app = "redis-haproxy"
      }
    }
    template {
      metadata {
        labels = {
          app = "redis-haproxy"
        }
        annotations = {
          # Roll the deployment whenever haproxy.cfg content changes so a
          # config update (e.g. DNS resolver tweaks) actually takes effect.
          "checksum/config" = sha256(kubernetes_config_map.haproxy.data["haproxy.cfg"])
        }
      }
      spec {
        container {
          name  = "haproxy"
          image = "docker.io/library/haproxy:3.1-alpine"
          port {
            container_port = 6379
            name           = "redis"
          }
          port {
            container_port = 26379
            name           = "sentinel"
          }
          volume_mount {
            name       = "config"
            mount_path = "/usr/local/etc/haproxy"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
          liveness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.haproxy.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [helm_release.redis]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

# Dedicated service for HAProxy master-only routing.
# Clients should use redis-master.redis.svc.cluster.local for write-safe connections.
# HAProxy health-checks Redis nodes and only routes to the current master.
resource "kubernetes_service" "redis_master" {
  metadata {
    name      = "redis-master"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis-haproxy"
    }
  }
  spec {
    selector = {
      app = "redis-haproxy"
    }
    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
    port {
      name        = "sentinel"
      port        = 26379
      target_port = 26379
    }
  }

  depends_on = [kubernetes_deployment.haproxy]
}

# The Helm chart creates a `redis` Service that selects all nodes (master + replica),
# causing READONLY errors when clients hit the replica. We patch it post-Helm to
# route through HAProxy instead, which health-checks and routes only to the master.
# This runs on every apply to ensure the Helm chart's service is always corrected.
resource "null_resource" "patch_redis_service" {
  triggers = {
    # Re-patch only when a Helm upgrade (chart version bump) or an HAProxy
    # config change could have reset the selector / rotated HAProxy pods.
    # timestamp() would force-replace on every apply, hiding real drift.
    chart_version  = helm_release.redis.version
    haproxy_config = sha256(kubernetes_config_map.haproxy.data["haproxy.cfg"])
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig=${abspath("${path.module}/../../../../config")} \
        patch svc redis -n redis --type='json' \
        -p='[{"op":"replace","path":"/spec/selector","value":{"app":"redis-haproxy"}}]'
    EOT
  }

  depends_on = [helm_release.redis, kubernetes_deployment.haproxy]
}

module "nfs_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "redis-backup-host"
  namespace  = kubernetes_namespace.redis.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/redis-backup"
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
    schedule                      = "0 3 * * 0"
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
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                TIMESTAMP=$(date +%Y%m%d-%H%M)
                # Trigger a fresh RDB save on the master
                redis-cli -h redis.redis BGSAVE
                sleep 5
                # Copy the RDB via redis-cli --rdb
                redis-cli -h redis.redis --rdb /backup/redis-$TIMESTAMP.rdb
                # Rotate — 28-day retention
                find /backup -name 'redis-*.rdb' -type f -mtime +28 -delete

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(ls -lh /backup/redis-$$TIMESTAMP.rdb | awk '{print $5}')"

                _out_bytes=$(stat -c%s /backup/redis-$TIMESTAMP.rdb)
                wget -qO- --post-data "backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                " "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/redis-backup" || true
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
                claim_name = module.nfs_backup_host.claim_name
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
