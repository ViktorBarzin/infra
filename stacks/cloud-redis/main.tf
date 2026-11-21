variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

variable "acl_sync_suspended" {
  description = "Suspend the cloud-redis-acl-sync CronJob (break glass, docs/runbooks/cloud-redis.md)."
  type        = bool
  default     = false
}

#### cloud-redis: Cloud's Key Value Redis (cloud backlog B27, option b)
#
# Viktor chose a separate Redis for Cloud tenants over Key Values on the
# shared homelab Redis (decision-b27-redis.md): a tenant's busy script, Lua
# OOM or client buffers then restart only this pod, and the homelab's ~15
# consumers never share memory with Projects. Runbook:
# docs/runbooks/cloud-redis.md.
#
# One standalone pod, as stacks/redis (a Key Value is a cache and queue, not
# a database with HA). Every client logs in with its own ACL user: `default`
# is off from the first aclfile. Cloud's Projects log in as tenants
# p_<project>_<service>_<hash>, confined to keys and channels
# p:<project>:<service>:*, which the CronJob cloud-redis-acl-sync writes from
# Cloud's read-only tenant route (the shared code in
# stacks/redis/modules/redis: acl_sync.py, acl_init.sh; its own probe.sh).

locals {
  name      = "cloud-redis"
  shared    = "${path.module}/../redis/modules/redis"
  image     = "docker.io/library/redis:8.10.3-alpine@sha256:7958cfbb9d152f87dadfbc89f1b0b15938f0b81ff8982feb327476f4911935c3"
  labels    = { app = local.name }
  users     = jsondecode(file("${path.module}/acl_users.json"))
  sync_name = "${local.name}-acl-sync"
  # redis-server's command line. No modules, so tenant rules never carry a
  # module part.
  server_command = ["redis-server", "/etc/redis/redis.conf"]
  pushgateway    = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job"
  # Cloud's read-only tenant route (the cloud repo's reconciler, port 9091).
  tenants_url = "http://cloud-reconciler.cloud.svc.cluster.local:9091/internal/redis-tenants"
}

resource "kubernetes_namespace" "cloud_redis" {
  metadata {
    name = local.name
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- users and their passwords -------------------------------------------------
#
# acl-admin (the sync job), exporter, backup and probe, with fixed rules in
# acl_users.json. Their passwords: random_password, written to Vault
# secret/cloud-redis/users by this stack's apply (the ci policy may write it,
# stacks/vault), and copied into Terraform Secrets so the pod starts without
# waiting for ESO.

resource "random_password" "users" {
  for_each = local.users
  length   = 40
  special  = false
}

resource "vault_kv_secret_v2" "users" {
  mount     = "secret"
  name      = "cloud-redis/users"
  data_json = jsonencode({ for name, _ in local.users : name => random_password.users[name].result })
}

# The bearer token the sync sends to Cloud's tenant route: one value, in
# secret/cloud-redis/cloud-tenants for the sync and secret/cloud/redis-tenants
# for Cloud (stacks/cloud's ExternalSecret cloud-reconciler-redis-tenants).
resource "random_password" "cloud_tenants_token" {
  length  = 40
  special = false
}

resource "vault_kv_secret_v2" "cloud_tenants" {
  mount     = "secret"
  name      = "cloud-redis/cloud-tenants"
  data_json = jsonencode({ token = random_password.cloud_tenants_token.result })
}

resource "vault_kv_secret_v2" "cloud_tenants_cloud_copy" {
  mount     = "secret"
  name      = "cloud/redis-tenants"
  data_json = jsonencode({ token = random_password.cloud_tenants_token.result })
}

# The first aclfile: default off, and acl-admin as a #<sha256> hash. The
# init step writes it when /data/acl/users.acl is missing (acl_init.sh).
resource "kubernetes_secret" "acl_seed" {
  metadata {
    name      = "${local.name}-acl-seed"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  data = {
    "users.acl" = <<-EOT
      user default off
      user acl-admin on #${sha256(random_password.users["acl-admin"].result)} ${local.users["acl-admin"]}
    EOT
  }
}

resource "kubernetes_secret" "infra_users" {
  metadata {
    name      = "${local.name}-infra-users"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  data = { for name in ["probe", "exporter", "backup"] : name => random_password.users[name].result }
}

# --- Redis ---------------------------------------------------------------------

resource "kubernetes_config_map" "conf" {
  metadata {
    name      = "${local.name}-conf"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  data = {
    # Memory in the 1Gi pod (request = limit): 512 MiB data (maxmemory) +
    # 128 MiB client buffers (maxmemory-clients) = 640 MiB, leaving 384 MiB
    # for Lua and for the copy-on-write of the fork that the AOF rewrite and
    # the backup's BGSAVE make. That copy grows with the pages written while
    # the fork lives, up to the whole 512 MiB of data in the worst case; past
    # the limit the kernel kills this pod only (CloudRedisBusy, CloudRedisDown),
    # never the homelab's Redis. The client limits nest, as
    # they must (Redis does not check it): one value (proto-max-bulk-len
    # 32mb) fits a client's query buffer (64mb), which fits the memory all
    # clients may hold before Redis evicts the biggest (maxmemory-clients
    # 128mb). The output limit nests too: the hard limit (64mb) holds one
    # reply of the largest value, which a 32mb limit cut off (the GET of a
    # legal 32 MiB value closed the connection, tested on 8.10.3). A client
    # that does not read its replies is cut off at 64mb of output, or 16mb
    # held for 60 s; a replica (the backup's `redis-cli --rdb` uses the
    # replication protocol) gets the same 64mb/16mb/60 s. busy-reply-threshold:
    # a script past 5 s makes other clients get BUSY, and probe.sh then fails
    # liveness, so the kubelet restarts the pod (CloudRedisBusy).
    "redis.conf" = <<-EOT
      bind 0.0.0.0 -::*
      port 6379
      protected-mode no
      dir /data
      maxmemory 512mb
      maxmemory-policy volatile-lru
      maxmemory-clients 128mb
      client-output-buffer-limit normal 64mb 16mb 60
      client-output-buffer-limit pubsub 64mb 16mb 60
      client-output-buffer-limit replica 64mb 16mb 60
      client-query-buffer-limit 64mb
      proto-max-bulk-len 32mb
      busy-reply-threshold 5000
      save 3600 1
      appendonly yes
      appendfsync everysec
      aof-load-truncated yes
      aof-use-rdb-preamble yes
      aof-load-corrupt-tail-max-size 1024
      timeout 0
      tcp-keepalive 300
      databases 16
      loglevel notice
      aclfile /data/acl/users.acl
    EOT
  }
}

resource "kubernetes_service" "headless" {
  metadata {
    name      = "${local.name}-headless"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
    labels    = local.labels
  }
  spec {
    cluster_ip = "None"
    selector   = local.labels
    port {
      name = "redis"
      port = 6379
    }
  }
}

resource "kubernetes_service" "cloud_redis" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
  }
}

resource "kubernetes_stateful_set_v1" "cloud_redis" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.cluster })
  }
  spec {
    service_name = kubernetes_service.headless.metadata[0].name
    replicas     = 1
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9121"
          "checksum/conf"        = sha256(kubernetes_config_map.conf.data["redis.conf"])
        }
      }
      spec {
        termination_grace_period_seconds = 90

        # Writes /data/acl/users.acl from the seed when it is missing, and
        # refreshes acl-admin's line otherwise (acl_init.sh).
        init_container {
          name    = "acl-seed"
          image   = local.image
          command = ["/bin/sh", "-c", file("${local.shared}/acl_init.sh")]
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "acl-seed"
            mount_path = "/seed"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { memory = "32Mi" }
          }
        }

        container {
          name    = "redis"
          image   = local.image
          command = local.server_command
          port {
            container_port = 6379
            name           = "redis"
          }
          resources {
            requests = { cpu = "100m", memory = "1Gi" }
            limits   = { memory = "1Gi" }
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
          env {
            name = "REDIS_PROBE_PASSWORD"
            value_from {
              secret_key_ref {
                name     = kubernetes_secret.infra_users.metadata[0].name
                key      = "probe"
                optional = true
              }
            }
          }
          liveness_probe {
            exec {
              command = ["sh", "-c", file("${path.module}/probe.sh")]
            }
            # A BUSY reply or no answer fails (probe.sh): a script running
            # past about 30 s (3 failures 10 s apart, after the 5 s before
            # Redis starts answering BUSY) gets the pod restarted; a shorter
            # one survives.
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          readiness_probe {
            exec {
              command = ["sh", "-c", file("${path.module}/probe.sh")]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }

        container {
          name  = "exporter"
          image = "docker.io/oliver006/redis_exporter:v1.97.0"
          port {
            container_port = 9121
            name           = "exporter"
          }
          env {
            name  = "REDIS_ADDR"
            value = "redis://localhost:6379"
          }
          env {
            name  = "REDIS_USER"
            value = "exporter"
          }
          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name     = kubernetes_secret.infra_users.metadata[0].name
                key      = "exporter"
                optional = true
              }
            }
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "32Mi" }
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
            name = kubernetes_config_map.conf.metadata[0].name
          }
        }
        volume {
          name = "acl-seed"
          secret {
            secret_name = kubernetes_secret.acl_seed.metadata[0].name
          }
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
        storage_class_name = "proxmox-lvm-encrypted-sas"
        resources {
          requests = { storage = "5Gi" }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].volume_claim_template,
    ]
  }
}

# --- backup --------------------------------------------------------------------
#
# As stacks/redis's redis-backup: BGSAVE, then the RDB over the replication
# protocol as the backup user, to NFS, keeping 28 days. Suspended: the Proxmox
# host's nightly-chain starts it on Sundays (annotation) before nfs-mirror
# copies /srv/nfs. The directory /srv/nfs/cloud-redis-backup must exist on
# the NFS host first (docs/runbooks/cloud-redis.md, "First apply").

module "nfs_backup" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "${local.name}-backup-host"
  namespace          = kubernetes_namespace.cloud_redis.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/cloud-redis-backup"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "${local.name}-backup"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
    annotations = {
      "backup.viktorbarzin.me/nightly-chain" = "sunday"
    }
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    schedule                      = "0 3 * * 0"
    suspend                       = true
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 60
        template {
          metadata {
            labels = { app = "${local.name}-backup" }
          }
          spec {
            container {
              name  = "backup"
              image = local.image
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                host=${kubernetes_service.cloud_redis.metadata[0].name}.${local.name}.svc.cluster.local
                TIMESTAMP=$(date +%Y%m%d-%H%M)
                login=$(redis-cli -h "$host" --no-auth-warning --user backup PING 2>&1)
                [ "$login" = PONG ] || { echo "login as backup failed: $login"; exit 1; }
                redis-cli -h "$host" --no-auth-warning --user backup BGSAVE
                sleep 5
                redis-cli -h "$host" --no-auth-warning --user backup --rdb /backup/cloud-redis-$TIMESTAMP.rdb
                find /backup -name 'cloud-redis-*.rdb' -type f -mtime +28 -delete
                out=$(stat -c%s /backup/cloud-redis-$TIMESTAMP.rdb)
                wget -qO- --post-data "backup_output_bytes $out
                backup_last_success_timestamp $(date +%s)
                " "${local.pushgateway}/${local.name}-backup" || true
              EOT
              ]
              env {
                name = "REDISCLI_AUTH"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.infra_users.metadata[0].name
                    key  = "backup"
                  }
                }
              }
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# --- the sync job ----------------------------------------------------------------
#
# The shared acl_sync.py with default off and the tenant section on: it
# renders acl-admin, exporter, backup and probe from acl_users.json and
# Vault, and the tenants from Cloud's route, every minute, and measures the
# tenants every KV_MEASURE_EVERY_SECONDS. Runbook: docs/runbooks/cloud-redis.md
# and redis-acl.md, "Cloud Key Value tenants".

resource "kubernetes_config_map" "sync" {
  metadata {
    name      = local.sync_name
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  data = {
    "acl_sync.py" = file("${local.shared}/acl_sync.py")
    "users.json"  = jsonencode(local.users)
  }
}

# Logs in to Vault as role cloud-redis-acl-sync (stacks/vault), which reads
# secret/cloud-redis/users and secret/cloud-redis/cloud-tenants only.
resource "kubernetes_service_account" "sync" {
  metadata {
    name      = local.sync_name
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "sync" {
  metadata {
    name      = local.sync_name
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  spec {
    schedule                      = "* * * * *"
    concurrency_policy            = "Forbid"
    suspend                       = var.acl_sync_suspended
    starting_deadline_seconds     = 30
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 0
        active_deadline_seconds    = 50
        ttl_seconds_after_finished = 600
        template {
          metadata {
            # stacks/cloud admits these pods to the tenant route on 9091.
            labels = { app = local.sync_name }
            annotations = {
              "checksum/script" = sha256(kubernetes_config_map.sync.data["acl_sync.py"])
            }
          }
          spec {
            service_account_name = kubernetes_service_account.sync.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "sync"
              image   = "docker.io/library/python:3.15.2-alpine@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd"
              command = ["python3", "/config/acl_sync.py"]
              dynamic "env" {
                for_each = {
                  REDIS_HOST               = "${kubernetes_service.cloud_redis.metadata[0].name}.${local.name}.svc.cluster.local"
                  DEFAULT_USER             = "off"
                  VAULT_ROLE               = local.sync_name
                  VAULT_SECRET_PATH        = "secret/data/${vault_kv_secret_v2.users.name}"
                  CLOUD_TENANTS_TOKEN_PATH = "secret/data/${vault_kv_secret_v2.cloud_tenants.name}"
                  CLOUD_TENANTS_URL        = local.tenants_url
                  PUSHGATEWAY_URL          = "${local.pushgateway}/${local.sync_name}"
                  PUSHGATEWAY_KV_URL       = "${local.pushgateway}/${local.sync_name}-kv"
                  PUSHGATEWAY_KV_USAGE_URL = "${local.pushgateway}/${local.sync_name}-kv-usage"
                  KV_MEASURE_EVERY_SECONDS = "300"
                }
                content {
                  name  = env.key
                  value = env.value
                }
              }
              volume_mount {
                name       = "config"
                mount_path = "/config"
                read_only  = true
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map.sync.metadata[0].name
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

# --- network -----------------------------------------------------------------------
#
# Default deny, both ways, for every pod in the namespace. Then: Redis on
# 6379 from Cloud Project namespaces (Cloud's Project policy lets only a
# Project with a Key Value through; infra's egress floor passes it), from
# Cloud's reconciler (it checks a new tenant's login before Apps get
# REDIS_URL), and from this namespace's sync and backup jobs; the exporter on
# 9121 from Prometheus and the kubelet. The sync job reaches DNS, Redis,
# Cloud's tenant route, Vault and the Pushgateway; the backup job DNS, Redis
# and the Pushgateway. The NFS mount is the kubelet's, outside pod policy.

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "redis" {
  metadata {
    name      = "${local.name}-ingress"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { "cloud.viktorbarzin.me/managed" = "true" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "cloud" }
        }
        pod_selector {
          match_labels = { app = "cloud-reconciler" }
        }
      }
      from {
        pod_selector {
          match_labels = { app = local.sync_name }
        }
      }
      from {
        pod_selector {
          match_labels = { app = "${local.name}-backup" }
        }
      }
      ports {
        port     = "6379"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
      # The exporter's httpGet liveness probe, dialled by the kubelet.
      from {
        ip_block {
          cidr = "10.0.20.0/24"
        }
      }
      ports {
        port     = "9121"
        protocol = "TCP"
      }
    }
  }
}

locals {
  egress_dns = [
    { to = { ns = "kube-system", pod = { "k8s-app" = "kube-dns" }, cidr = null }, ports = [{ port = 53, protocol = "UDP" }, { port = 53, protocol = "TCP" }] },
    { to = { ns = null, pod = null, cidr = "10.96.0.10/32" }, ports = [{ port = 53, protocol = "UDP" }, { port = 53, protocol = "TCP" }] },
  ]
  egress_redis = [{ to = { ns = local.name, pod = local.labels, cidr = null }, ports = [{ port = 6379, protocol = "TCP" }] }]
  egress_push  = [{ to = { ns = "monitoring", pod = null, cidr = null }, ports = [{ port = 9091, protocol = "TCP" }] }]
  egress = {
    (local.sync_name) = concat(local.egress_dns, local.egress_redis, local.egress_push, [
      { to = { ns = "cloud", pod = { app = "cloud-reconciler" }, cidr = null }, ports = [{ port = 9091, protocol = "TCP" }] },
      { to = { ns = "vault", pod = null, cidr = null }, ports = [{ port = 8200, protocol = "TCP" }] },
    ])
    "${local.name}-backup" = concat(local.egress_dns, local.egress_redis, local.egress_push)
  }
}

resource "kubernetes_network_policy_v1" "egress" {
  for_each = local.egress
  metadata {
    name      = "${each.key}-egress"
    namespace = kubernetes_namespace.cloud_redis.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = each.key }
    }
    policy_types = ["Egress"]
    dynamic "egress" {
      for_each = each.value
      content {
        to {
          dynamic "namespace_selector" {
            for_each = egress.value.to.ns == null ? [] : [egress.value.to.ns]
            content {
              match_labels = { "kubernetes.io/metadata.name" = namespace_selector.value }
            }
          }
          dynamic "pod_selector" {
            for_each = egress.value.to.pod == null ? [] : [egress.value.to.pod]
            content {
              match_labels = pod_selector.value
            }
          }
          dynamic "ip_block" {
            for_each = egress.value.to.cidr == null ? [] : [egress.value.to.cidr]
            content {
              cidr = ip_block.value
            }
          }
        }
        dynamic "ports" {
          for_each = egress.value.ports
          content {
            port     = tostring(ports.value.port)
            protocol = ports.value.protocol
          }
        }
      }
    }
  }
}
