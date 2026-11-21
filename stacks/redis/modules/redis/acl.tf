#### Redis ACL users (B40 R1, cloud render-parity backlog)
#
# Viktor's decision V5 (2026-11-15): put passwords on this Redis with no
# downtime. Named users first, then each consumer moves to its own user
# (R2), then `default` is locked last (R4). This file is R1: the users
# exist, and `default` keeps `on nopass ~* &* +@all`, so no client changes.
# Runbook: docs/runbooks/redis-acl.md.
#
# Pieces:
#   acl_users.json   one user per consumer namespace in the B40 inventory,
#                    plus exporter, backup, probe, verify and acl-admin, each
#                    with its fixed rule. The rule lives here, not in Vault.
#   random_password  one per user, written to Vault secret/redis/users (one
#                    key per user), plus one for default (R4; rybbit sends it
#                    from R2, see local.redis_default_user_namespaces). From R2 each consumer's ExternalSecret
#                    names its own key. Vault cannot enforce that per key:
#                    the eso-reader and ci policies read all of
#                    secret/data/*, so the isolation rests on reviewing each
#                    ExternalSecret.
#   redis-acl-seed   Secret: the first aclfile (default, unchanged, and
#                    acl-admin as a #<sha256> hash). The init container in
#                    main.tf writes it when /data/acl/users.acl is missing,
#                    because Redis does not start without its aclfile.
#   redis-acl-sync   CronJob, every minute (acl_sync.py): reads Vault,
#                    renders every user with #<sha256> hashes, sends the
#                    difference with ACL SETUSER/DELUSER in one MULTI as
#                    acl-admin, and ends every run with ACL SAVE; fails
#                    closed; counts CLIENT LIST by user (R3) and pushes
#                    metrics.
#
# Why over the network and not by writing the file: the data PVC is
# ReadWriteOnce. A second pod could mount it only on redis-v2-0's node, tied
# to it by pod affinity, with write access to the AOF and RDB files. ACL
# SAVE makes Redis write the aclfile itself, atomically (temporary file and
# rename), and the sync needs no volume. ACL SETUSER does not disconnect a
# user's clients; ACL DELUSER does, and only users nobody wants are deleted.
#
# Users:
#   acl-admin  ACL management, CLIENT LIST for the R3 counter, MULTI/EXEC.
#              It can create any user, so it is admin in effect; only the
#              sync job holds its password. Cloud Key Value tenants live on
#              cloud-redis (B27 option b, stacks/cloud-redis), not here.
#   exporter   what redis_exporter v1.97.0 runs with our flags (measured
#              with INFO commandstats on 8.10.3): INFO, CONFIG GET, SLOWLOG
#              GET/LEN, LATENCY LATEST/HISTOGRAM, COMMAND INFO, CLIENT
#              SETNAME. No key access, no CLIENT KILL.
#   backup     the redis-backup job: BGSAVE, then `redis-cli --rdb`, which
#              sends REPLCONF and SYNC.
#   probe      PING only, for the liveness and readiness probes (probe.sh).
#   the rest   the same rights as `default` today.

# Configurable, as the B27 review asked, so another Redis could reuse this
# file; the defaults are this Redis's.
variable "acl_users_vault_path" {
  description = "Vault KV v2 path (under secret/) of the ACL users' passwords, acl-admin's among them."
  type        = string
  default     = "redis/users"
}

variable "acl_sync_pushgateway" {
  description = "Pushgateway base URL and the job name the sync pushes to."
  type        = object({ url = string, job = string })
  default     = { url = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job", job = "redis-acl-sync" }
}

variable "acl_sync_suspended" {
  description = "Suspend the redis-acl-sync CronJob (break glass, docs/runbooks/redis-acl.md)."
  type        = bool
  default     = false
}

locals {
  redis_acl_users = jsondecode(file("${path.module}/acl_users.json"))
  # Namespaces whose clients stay on the default user, because their app can
  # send only a password: rybbit (v2.9.3 reads REDIS_PASSWORD, no username).
  # They log in with default's Vault password. The R3 gate counts default
  # clients outside these namespaces (redis_default_clients_unexpected).
  redis_default_user_namespaces = ["rybbit"]
}

resource "random_password" "redis_acl" {
  for_each = local.redis_acl_users
  length   = 40
  # Letters and digits only, so every password fits a redis:// URL without
  # escaping.
  special = false
}

# default's password. Not used by the render until R4, which sets it on
# default instead of turning default off; rybbit sends it from R2 on, and
# Redis ignores a password for a nopass default.
resource "random_password" "redis_default" {
  length  = 40
  special = false
}

# CI writes this path through the `ci` policy (stacks/vault/main.tf), which
# grants data and metadata write on secret/redis/users only.
resource "vault_kv_secret_v2" "redis_users" {
  mount = "secret"
  name  = var.acl_users_vault_path
  data_json = jsonencode(merge(
    { for name, _ in local.redis_acl_users : name => random_password.redis_acl[name].result },
    { default = random_password.redis_default.result },
  ))
}

resource "kubernetes_secret" "redis_acl_seed" {
  metadata {
    name      = "redis-acl-seed"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  data = {
    "users.acl" = <<-EOT
      user default on nopass ~* &* +@all
      user acl-admin on #${sha256(random_password.redis_acl["acl-admin"].result)} ${local.redis_acl_users["acl-admin"]}
    EOT
  }
}

# The passwords of the users this namespace runs as itself (B40 R2): probe
# for the redis container's probes, exporter for the redis_exporter sidecar,
# backup for the redis-backup CronJob. A Terraform Secret, not an
# ExternalSecret, because the Redis pod needs it to start: Terraform creates
# it before the StatefulSet changes, and Redis does not wait on ESO. A
# -replace of one of these passwords updates this Secret in the same apply.
resource "kubernetes_secret" "redis_infra_users" {
  metadata {
    name      = "redis-infra-users"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  data = {
    for name in ["probe", "exporter", "backup"] : name => random_password.redis_acl[name].result
  }
}

resource "kubernetes_config_map" "redis_acl_sync" {
  metadata {
    name      = "redis-acl-sync"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
  data = {
    "acl_sync.py" = file("${path.module}/acl_sync.py")
    # The verify script reads this list too (stacks/redis/verify.sh).
    "users.json" = jsonencode(local.redis_acl_users)
  }
}

# Logs in to Vault as role redis-acl-sync (stacks/vault/main.tf), which reads
# secret/redis/users and nothing else.
resource "kubernetes_service_account" "redis_acl_sync" {
  metadata {
    name      = "redis-acl-sync"
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
}

# The sync lists the pods of the namespaces allowed on default, to tell
# their default clients from any other (R3 gate). Read-only, pods only.
resource "kubernetes_role" "redis_acl_sync_pods" {
  for_each = toset(local.redis_default_user_namespaces)
  metadata {
    name      = "redis-acl-sync-pods"
    namespace = each.value
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding" "redis_acl_sync_pods" {
  for_each = toset(local.redis_default_user_namespaces)
  metadata {
    name      = "redis-acl-sync-pods"
    namespace = each.value
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.redis_acl_sync_pods[each.value].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.redis_acl_sync.metadata[0].name
    namespace = kubernetes_namespace.redis.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "redis_acl_sync" {
  metadata {
    name      = "redis-acl-sync"
    namespace = kubernetes_namespace.redis.metadata[0].name
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
            annotations = {
              "checksum/script" = sha256(kubernetes_config_map.redis_acl_sync.data["acl_sync.py"])
            }
          }
          spec {
            service_account_name = kubernetes_service_account.redis_acl_sync.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "sync"
              image   = "docker.io/library/python:3.15.2-alpine@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd"
              command = ["python3", "/config/acl_sync.py"]
              env {
                name  = "REDIS_HOST"
                value = "${kubernetes_service.redis_master.metadata[0].name}.${kubernetes_namespace.redis.metadata[0].name}.svc.cluster.local"
              }
              env {
                name  = "VAULT_ROLE"
                value = "redis-acl-sync"
              }
              env {
                name  = "VAULT_SECRET_PATH"
                value = "secret/data/${vault_kv_secret_v2.redis_users.name}"
              }
              env {
                name  = "DEFAULT_USER_NAMESPACES"
                value = join(",", local.redis_default_user_namespaces)
              }
              env {
                name  = "PUSHGATEWAY_URL"
                value = "${var.acl_sync_pushgateway.url}/${var.acl_sync_pushgateway.job}"
              }
              volume_mount {
                name       = "config"
                mount_path = "/config"
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
            }
            volume {
              name = "config"
              config_map {
                name = kubernetes_config_map.redis_acl_sync.metadata[0].name
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
