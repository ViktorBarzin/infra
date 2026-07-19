variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "redis" {
  metadata {
    name = "redis"
    labels = {
      tier               = var.tier
      "keel.sh/enrolled" = "true"
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

#### Redis — SINGLE standalone instance (reverted from 3-node Sentinel HA 2026-05-30)
#
# History: a 3-node StatefulSet + Sentinel + HAProxy (the "redis-v2" rework of
# 2026-04-19, beads code-v2b) was built to eliminate the 2-sentinel split-brain
# of the 2026-04-19 PM incident. It STILL split-brained on 2026-05-30:
# redis-v2-0 booted during a network partition, hit the init script's
# "pod-0 is always the bootstrap master" fallback, and became a SECOND master
# alongside the sentinel-elected redis-v2-2. HAProxy's `expect rstring
# role:master` matched BOTH, so it round-robined client connections across
# both masters — Immich enqueued BullMQ jobs on one instance while its workers
# blocked-popped on the other, wedging every queue (new-upload thumbnails 404'd
# cluster-wide). Third Redis HA incident in ~6 weeks.
#
# Decision (Viktor, 2026-05-30): revert to a SINGLE instance. A homelab
# cache/broker does not need HA; a few seconds of downtime on a pod restart is
# an acceptable trade for structurally removing the entire split-brain class
# (no sentinel quorum, no second master, no HAProxy master fan-out).
#
# eviction policy `volatile-lru` (was `allkeys-lru`): the instance is shared by
# ~15 consumers split between CACHES (want LRU eviction of disposable keys) and
# QUEUES (Immich BullMQ `bull:*`, Celery `_kombu:*` — must NEVER be evicted or
# jobs vanish). `volatile-lru` evicts only keys that carry a TTL (caches set
# them) and never touches TTL-less keys (queue jobs), so it serves both
# correctly in one instance. Backstop: PrometheusRule RedisMemoryHigh (>80%)
# in the monitoring stack — if it ever fills with non-volatile keys, writes
# error like noeviction, and we want to know before that happens.
#
# Service name `redis-master.redis.svc.cluster.local:6379` is UNCHANGED so all
# ~15 consumers keep working without edits — it now selects the redis pod
# directly instead of HAProxy. Confirmed (2026-05-30) no consumer used the
# Sentinel port (26379); Nextcloud dropped its in-process sentinel query in the
# 2026-04-19 rework. Pattern mirrors the MySQL standalone (memory 711).

resource "kubernetes_config_map" "redis_v2_conf" {
  metadata {
    name      = "redis-v2-conf"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  data = {
    "redis.conf" = <<-EOT
      bind 0.0.0.0 -::*
      port 6379
      protected-mode no
      dir /data

      maxmemory 640mb
      # volatile-lru: evict only keys WITH a TTL (caches) under memory
      # pressure; never evict TTL-less keys (Immich BullMQ + Celery jobs).
      # See the header comment for the full rationale. Was allkeys-lru, which
      # silently evicted queue jobs.
      maxmemory-policy volatile-lru

      save 900 1
      save 300 100
      save 60 10000
      rdbcompression yes
      rdbchecksum yes
      stop-writes-on-bgsave-error no

      appendonly yes
      appendfsync everysec
      no-appendfsync-on-rewrite no
      auto-aof-rewrite-percentage 200
      auto-aof-rewrite-min-size 128mb
      aof-load-truncated yes
      aof-use-rdb-preamble yes
      # Allow loading an AOF with up to 1KB of garbage at the tail (post-2026-05-26
      # node2 unclean reboot corrupted an incremental AOF; without this redis
      # crashlooped). Redis truncates the corrupted tail and continues.
      aof-load-corrupt-tail-max-size 1024

      timeout 0
      tcp-keepalive 300
      tcp-backlog 511
      databases 16

      loglevel notice
    EOT
  }
}

resource "kubernetes_service" "redis_v2_headless" {
  metadata {
    name      = "redis-v2-headless"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis-v2"
    }
  }
  spec {
    cluster_ip                  = "None"
    publish_not_ready_addresses = false
    selector = {
      app = "redis-v2"
    }
    port {
      name = "redis"
      port = 6379
    }
    port {
      name = "exporter"
      port = 9121
    }
  }
}

# Stable client-facing service for all ~15 Redis consumers.
# Name/DNS (redis-master.redis.svc.cluster.local) unchanged across the HA
# teardown; now selects the redis pod directly (HAProxy removed).
resource "kubernetes_service" "redis_master" {
  metadata {
    name      = "redis-master"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis-v2"
    }
  }
  spec {
    selector = {
      app = "redis-v2"
    }
    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
  }
}

module "nfs_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "redis-backup-host"
  namespace  = kubernetes_namespace.redis.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/redis-backup"
}

resource "kubernetes_stateful_set_v1" "redis_v2" {
  metadata {
    name      = "redis-v2"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis-v2"
      # Keel opt-out: a :8-alpine -> :8.0.6-alpine patch bump (also a
      # semantic downgrade) rejected `aof-load-corrupt-tail-max-size` and
      # crashed redis. Both LABEL + ANNOTATION required for full opt-out.
      "keel.sh/policy" = "never"
      # Declared because the sync-tier-label-from-namespace Kyverno policy
      # stamps it live; without it every apply strips the label and the
      # policy re-adds it (perma-drift that fed provider identity bugs).
      tier = var.tier
    }
    annotations = {
      "keel.sh/policy" = "never"
    }
  }
  spec {
    service_name = kubernetes_service.redis_v2_headless.metadata[0].name
    replicas     = 1
    # pod_management_policy is immutable on a StatefulSet — kept as "Parallel"
    # (unchanged from the 3-node era) so this revert does NOT force a
    # destroy/recreate of the STS (which would detach the data PVC).
    pod_management_policy = "Parallel"

    selector {
      match_labels = {
        app = "redis-v2"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis-v2"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9121"
          "checksum/conf"        = sha256(kubernetes_config_map.redis_v2_conf.data["redis.conf"])
        }
      }
      spec {
        # 90s (was 30) so a slow AOF/RDB flush finishes cleanly on shutdown
        # instead of self-SIGKILLing at 30 (2026-07-19 shutdown tuning).
        termination_grace_period_seconds = 90

        container {
          name    = "redis"
          image   = "docker.io/library/redis:8-alpine"
          command = ["redis-server", "/etc/redis/redis.conf"]

          port {
            container_port = 6379
            name           = "redis"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "768Mi"
            }
            limits = {
              memory = "768Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/redis"
            read_only  = true
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "PING"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 10
            failure_threshold     = 5
          }
          readiness_probe {
            exec {
              command = ["redis-cli", "PING"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }

        container {
          name  = "exporter"
          image = "docker.io/oliver006/redis_exporter:v1.62.0"

          port {
            container_port = 9121
            name           = "exporter"
          }

          env {
            name  = "REDIS_ADDR"
            value = "redis://localhost:6379"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "32Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 9121
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
          }
        }

        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map.redis_v2_conf.metadata[0].name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
        annotations = {
          # NOTE: VCT is immutable on a live StatefulSet — this must match the
          # live value (drifted to 80% out-of-band) or apply fails with
          # "updates to statefulset spec ... forbidden". Don't "fix" to 10%.
          "resize.topolvm.io/threshold"     = "80%"
          "resize.topolvm.io/increase"      = "100%"
          "resize.topolvm.io/storage_limit" = "20Gi"
        }
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "proxmox-lvm-encrypted"
        resources {
          requests = {
            storage = "5Gi"
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

# Weekly backup: copy RDB snapshot to NFS
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
                redis-cli -h redis-master.redis BGSAVE
                sleep 5
                # Copy the RDB via redis-cli --rdb
                redis-cli -h redis-master.redis --rdb /backup/redis-$TIMESTAMP.rdb
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
