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

      # 256Mi was too tight once the working set crossed ~200Mi: BGSAVE
      # fork during a replica full PSYNC doubled RSS via COW and pushed
      # the master past 256Mi → OOMKilled (exit 137), HAProxy flapped,
      # every redis client (Paperless, Immich, Authentik) saw connection
      # resets. 512Mi gives ~2x headroom on the current 204Mi RDB.
      resources = {
        requests = {
          cpu    = "100m"
          memory = "512Mi"
        }
        limits = {
          memory = "512Mi"
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
          memory = "512Mi"
        }
        limits = {
          memory = "512Mi"
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
        server redis-v2-0 redis-v2-0.redis-v2-headless.redis.svc.cluster.local:6379 check inter 1s fall 2 rise 2 resolvers kubernetes init-addr last,libc,none
        server redis-v2-1 redis-v2-1.redis-v2-headless.redis.svc.cluster.local:6379 check inter 1s fall 2 rise 2 resolvers kubernetes init-addr last,libc,none
        server redis-v2-2 redis-v2-2.redis-v2-headless.redis.svc.cluster.local:6379 check inter 1s fall 2 rise 2 resolvers kubernetes init-addr last,libc,none

      backend redis_sentinel
        balance roundrobin
        server redis-v2-0 redis-v2-0.redis-v2-headless.redis.svc.cluster.local:26379 check inter 5s resolvers kubernetes init-addr last,libc,none
        server redis-v2-1 redis-v2-1.redis-v2-headless.redis.svc.cluster.local:26379 check inter 5s resolvers kubernetes init-addr last,libc,none
        server redis-v2-2 redis-v2-2.redis-v2-headless.redis.svc.cluster.local:26379 check inter 5s resolvers kubernetes init-addr last,libc,none
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
    # 3 replicas + PDB minAvailable=2 (see kubernetes_pod_disruption_budget_v1.redis_haproxy).
    # After Nextcloud drops its sentinel fallback in Phase 6 of the 2026-04-19 redis
    # rework, HAProxy is the sole client-facing path for all 17 redis consumers, so
    # it needs HA equivalent to other critical-path pods (Traefik, Authentik, PgBouncer).
    replicas = 3
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

#### Redis v2 — parallel 3-node raw StatefulSet (target architecture)
#
# Built alongside the Bitnami helm_release.redis so data can migrate via
# REPLICAOF with <60s cutover downtime (see session plan / beads code-v2b).
#
# Pattern: MySQL standalone precedent (stacks/dbaas/modules/dbaas/main.tf,
# 2026-04-16 migration) — raw kubernetes_stateful_set_v1 + official image,
# no Bitnami Helm chart (deprecated by Broadcom Aug 2025; atomic-Helm trap
# caused the 2026-04-04 memory-bump deadlock).
#
# Design choices driven by incident cluster in April 2026:
#   - 3 sentinels (odd count, quorum=2) — eliminates the split-brain class
#     that caused the 2026-04-19 PM incident (2 sentinels, stale master state).
#   - Init container regenerates sentinel.conf on every boot by probing
#     peers for role:master — no persistent sentinel runtime state, so stale
#     entries can never resurface across pod restarts.
#   - podManagementPolicy=Parallel — all 3 pods start together, avoiding the
#     "sentinel-0 elects before -2 booted" ordering bug.
#   - Memory 768Mi (up from 512Mi) — concurrent BGSAVE + AOF-rewrite fork can
#     double RSS via COW. auto-aof-rewrite-percentage 200 + min-size 128mb
#     tune down rewrite frequency.
#   - Persistence: RDB snapshots + AOF everysec. Measured <1 GB/day write
#     volume (2026-04-19 disk-wear analysis) → 40+ year SSD runway.
#   - HAProxy remains sole client-facing path for all 17 consumers.

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
      maxmemory-policy allkeys-lru

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

      replica-read-only yes
      replica-serve-stale-data yes

      timeout 0
      tcp-keepalive 300
      tcp-backlog 511
      databases 16

      loglevel notice

      # Included last so `replicaof` directive written by the init container
      # overrides the "standalone master" default. Prevents the parallel-
      # bootstrap race where all 3 pods claim role:master simultaneously.
      include /shared/replica.conf
    EOT
  }
}

resource "kubernetes_config_map" "redis_v2_sentinel_bootstrap" {
  metadata {
    name      = "redis-v2-sentinel-bootstrap"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  data = {
    "init.sh" = <<-EOT
      #!/bin/sh
      set -eu

      HOSTNAME=$(hostname)
      MY_NUM=$${HOSTNAME##*-}
      MY_DNS="$HOSTNAME.redis-v2-headless.redis.svc.cluster.local"
      MASTER_HOST=""

      echo "=== Redis v2 bootstrap ==="
      echo "hostname: $HOSTNAME (index $MY_NUM)"

      # Priority 1: ask peer sentinels for the consensus master. Covers the
      # "steady-state pod restart" case — sentinels already agree on reality
      # and a restarting pod should join that topology.
      votes_0=0; votes_1=0; votes_2=0; votes_total=0
      for i in 0 1 2; do
        if [ "$i" = "$MY_NUM" ]; then continue; fi
        peer="redis-v2-$i.redis-v2-headless.redis.svc.cluster.local"
        reply=$(redis-cli -h "$peer" -p 26379 -t 2 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -n1 || true)
        echo "sentinel probe $peer: master=$${reply:-unreachable}"
        case "$reply" in
          *redis-v2-0*) votes_0=$((votes_0 + 1)); votes_total=$((votes_total + 1)) ;;
          *redis-v2-1*) votes_1=$((votes_1 + 1)); votes_total=$((votes_total + 1)) ;;
          *redis-v2-2*) votes_2=$((votes_2 + 1)); votes_total=$((votes_total + 1)) ;;
        esac
      done
      if [ "$votes_total" -gt 0 ]; then
        if [ "$votes_0" -ge "$votes_1" ] && [ "$votes_0" -ge "$votes_2" ] && [ "$votes_0" -gt 0 ]; then
          MASTER_HOST="redis-v2-0.redis-v2-headless.redis.svc.cluster.local"
        elif [ "$votes_1" -ge "$votes_2" ] && [ "$votes_1" -gt 0 ]; then
          MASTER_HOST="redis-v2-1.redis-v2-headless.redis.svc.cluster.local"
        elif [ "$votes_2" -gt 0 ]; then
          MASTER_HOST="redis-v2-2.redis-v2-headless.redis.svc.cluster.local"
        fi
        [ -n "$MASTER_HOST" ] && echo "sentinel vote winner: $MASTER_HOST"
      fi

      # Priority 2: look for a peer redis that's a master WITH at least one
      # replica connected. "Standalone master" peers (bootstrap race) are
      # skipped — connected_slaves=0 is ambiguous.
      if [ -z "$MASTER_HOST" ]; then
        for i in 0 1 2; do
          if [ "$i" = "$MY_NUM" ]; then continue; fi
          peer="redis-v2-$i.redis-v2-headless.redis.svc.cluster.local"
          info=$(redis-cli -h "$peer" -t 2 INFO replication 2>/dev/null || true)
          role=$(echo "$info" | awk -F: '/^role:/ {gsub(/\r/,""); print $2; exit}')
          slaves=$(echo "$info" | awk -F: '/^connected_slaves:/ {gsub(/\r/,""); print $2; exit}')
          echo "redis probe $peer: role=$${role:-unreachable} slaves=$${slaves:-0}"
          if [ "$role" = "master" ] && [ "$${slaves:-0}" -gt 0 ]; then
            MASTER_HOST="$peer"
            break
          fi
        done
      fi

      # Priority 3: deterministic fallback — pod -0 is always the bootstrap
      # master on a fresh cluster. All sentinels converge here, no race.
      if [ -z "$MASTER_HOST" ]; then
        MASTER_HOST="redis-v2-0.redis-v2-headless.redis.svc.cluster.local"
        echo "no master found via probes — bootstrap default: $MASTER_HOST"
      fi

      cat > /shared/sentinel.conf <<EOF
      port 26379
      bind 0.0.0.0 -::*
      dir /shared
      sentinel resolve-hostnames yes
      sentinel announce-hostnames yes
      sentinel monitor mymaster $MASTER_HOST 6379 2
      sentinel down-after-milliseconds mymaster 5000
      sentinel failover-timeout mymaster 30000
      sentinel parallel-syncs mymaster 1
      EOF

      # replica.conf is included by redis.conf (see ConfigMap redis_v2_conf).
      # Master pod gets an empty file; replicas get `replicaof <master>`.
      # This way pods come up already in the right role — no post-start race.
      if [ "$MY_DNS" = "$MASTER_HOST" ]; then
        : > /shared/replica.conf
        echo "role: master"
      else
        echo "replicaof $MASTER_HOST 6379" > /shared/replica.conf
        echo "role: replica of $MASTER_HOST"
      fi

      echo "=== bootstrap complete ==="
      cat /shared/sentinel.conf
      echo "--- replica.conf ---"
      cat /shared/replica.conf
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
    publish_not_ready_addresses = true
    selector = {
      app = "redis-v2"
    }
    port {
      name = "redis"
      port = 6379
    }
    port {
      name = "sentinel"
      port = 26379
    }
    port {
      name = "exporter"
      port = 9121
    }
  }
}

resource "kubernetes_stateful_set_v1" "redis_v2" {
  metadata {
    name      = "redis-v2"
    namespace = kubernetes_namespace.redis.metadata[0].name
    labels = {
      app = "redis-v2"
    }
  }
  spec {
    service_name          = kubernetes_service.redis_v2_headless.metadata[0].name
    replicas              = 3
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
          "checksum/bootstrap"   = sha256(kubernetes_config_map.redis_v2_sentinel_bootstrap.data["init.sh"])
        }
      }
      spec {
        termination_grace_period_seconds = 30

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_expressions {
                    key      = "app"
                    operator = "In"
                    values   = ["redis-v2"]
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        init_container {
          name    = "generate-sentinel-conf"
          image   = "docker.io/library/redis:8-alpine"
          command = ["/bin/sh", "/bootstrap/init.sh"]

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "32Mi"
            }
          }

          volume_mount {
            name       = "bootstrap"
            mount_path = "/bootstrap"
            read_only  = true
          }
          volume_mount {
            name       = "shared"
            mount_path = "/shared"
          }
        }

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
          volume_mount {
            # redis.conf `include /shared/replica.conf` — written by init container.
            name       = "shared"
            mount_path = "/shared"
            read_only  = true
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "PING"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
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
          name    = "sentinel"
          image   = "docker.io/library/redis:8-alpine"
          command = ["redis-sentinel", "/shared/sentinel.conf"]

          port {
            container_port = 26379
            name           = "sentinel"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          volume_mount {
            name       = "shared"
            mount_path = "/shared"
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "-p", "26379", "PING"]
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }
          readiness_probe {
            exec {
              command = ["redis-cli", "-p", "26379", "PING"]
            }
            initial_delay_seconds = 10
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
        volume {
          name = "bootstrap"
          config_map {
            name         = kubernetes_config_map.redis_v2_sentinel_bootstrap.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "shared"
          empty_dir {}
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
        annotations = {
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

resource "kubernetes_pod_disruption_budget_v1" "redis_v2" {
  metadata {
    name      = "redis-v2"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  spec {
    min_available = 2
    selector {
      match_labels = {
        app = "redis-v2"
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "redis_haproxy" {
  metadata {
    name      = "redis-haproxy"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  spec {
    min_available = 2
    selector {
      match_labels = {
        app = "redis-haproxy"
      }
    }
  }
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
