# garage: a cluster-only S3 store for Cloud Buckets (cloud render-parity B25,
# Viktor's decision V6: cluster-only S3, Apps proxy uploads, no public S3
# host). Docs: docs/architecture/garage.md, runbook docs/runbooks/garage.md.
#
#   Project App pods ---S3 :3900---------------> garage   (Calico: B26a's floor
#   cloud console, restore Jobs ---S3 :3900---->  (1 pod)   Pass + Project policy)
#   cloud reconciler, console --admin :3903---->  buckets, keys, quotas
#   monitoring (Prometheus) --/metrics :3903--->  (no token; policy-limited)
#   garage-backup CronJob ---S3 + admin-------->  rclone sync -> NFS
#
# One Garage node, replication_factor 1, started with `--single-node`: the
# server assigns its own layout on first start and leaves it alone after, so a
# fresh cluster built from Terraform is usable without hand steps. One copy of
# each object lives here; the nightly backup on NFS is the second.
#
# Storage, both on proxmox-lvm-encrypted-sas (the SAS RAID1 pool, where small
# hot volumes and databases go; docs/architecture/storage.md), each its own PVC:
#   metadata (LMDB)  1Gi, grows to 10Gi. Never on NFS: LMDB needs real locks
#                    and fsync.
#   data (blocks)    20Gi, grows to 100Gi. On 2026-11-21 the SAS thin pool
#                    (sas/data, 537.6 GiB) had 189.6 GiB written (21.5%), with
#                    530 GiB already promised to its volumes; SASThinPoolFilling
#                    warns at 80% (430 GiB), so about 240 GiB is really free.
#                    100Gi keeps Garage under half of that. Each copy on NFS
#                    adds to the 3.3 of 4.0 TB already used there (87%).
#                    Raise the limit only after checking both.
#
# Credentials (Vault, written here from random values; never printed):
#   secret/garage        rpc_secret, admin_token. The pod reads them through
#                        ExternalSecret garage-secrets.
#   secret/cloud/garage  admin_token (the same value), admin_url, s3_url, for
#                        Cloud's reconciler. Kept apart so nothing in Cloud
#                        needs read on secret/garage.
# CI's Vault policy may write both paths (stacks/vault, policy `ci`).

variable "nfs_server" { type = string }

locals {
  namespace = "garage"
  labels    = { app = "garage", "app.kubernetes.io/name" = "garage" }
  # Literal pins so Renovate tracks them, with the docker.io/ prefix Kyverno's
  # require-trusted-registries wants. Digests as well: the store holds Project
  # data, and a moved tag must not change the server under it. Cloud's
  # `cloud bucket restore` Job pins the same rclone string (stacks/cloud).
  garage_image = "docker.io/dxflrs/garage:v2.6.0@sha256:4b5a318fc9fe2fbec5d3af590eeafe05d83492e6411266fa0b9e215c20264013"
  rclone_image = "docker.io/rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466"
  python_image = "docker.io/library/python:3.15.2-alpine@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd"
  s3_port      = 3900
  admin_port   = 3903
  s3_url       = "http://garage.garage.svc.cluster.local:3900"
  admin_url    = "http://garage.garage.svc.cluster.local:3903"
  # The backup writes, and Cloud's restore Job reads, files owned by this
  # uid/gid (/srv/nfs/cloud-buckets is 10001:10001, mode 750).
  backup_uid = 10001
  # Who may reach S3 and the admin API (NetworkPolicy garage below).
  cloud_managed_label = "cloud.viktorbarzin.me/managed"
}

resource "kubernetes_namespace" "garage" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# ── Credentials ──

# Garage wants the RPC secret as 32 bytes in hex. random_bytes, not
# random_id: random_id's hex is not sensitive and would show in every plan
# log, and this repo is public.
resource "random_bytes" "rpc_secret" {
  length = 32
}

resource "random_password" "admin_token" {
  length  = 48
  special = false
}

resource "vault_kv_secret_v2" "garage" {
  mount = "secret"
  name  = "garage"
  data_json = jsonencode({
    rpc_secret  = random_bytes.rpc_secret.hex
    admin_token = random_password.admin_token.result
  })
}

resource "vault_kv_secret_v2" "cloud_garage" {
  mount = "secret"
  name  = "cloud/garage"
  data_json = jsonencode({
    admin_token = random_password.admin_token.result
    admin_url   = local.admin_url
    s3_url      = local.s3_url
  })
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "garage-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "garage-secrets"
      }
      dataFrom = [{
        extract = {
          key = "garage"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.garage, vault_kv_secret_v2.garage]
}

# ── Server ──

resource "kubernetes_config_map" "garage" {
  metadata {
    name      = "garage-config"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }
  data = {
    "garage.toml" = file("${path.module}/files/garage.toml")
  }
}

# Both PVCs grow at 80% full (threshold 20% free), before GarageDiskFull at
# 85%, so the alert means a volume reached its storage_limit or the resizer
# is stuck.
resource "kubernetes_persistent_volume_claim" "meta" {
  wait_until_bound = false
  metadata {
    name      = "garage-meta-encrypted"
    namespace = kubernetes_namespace.garage.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "20%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted-sas"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer grows requests.storage; PVCs cannot shrink, so Terraform
    # must not try to set it back.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "garage-data-encrypted"
    namespace = kubernetes_namespace.garage.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "20%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "100Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted-sas"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "garage" {
  metadata {
    name      = "garage"
    namespace = kubernetes_namespace.garage.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      # A rotated token in garage-secrets restarts the server.
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # RWO volumes
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        security_context {
          run_as_user            = 1000
          run_as_group           = 1000
          run_as_non_root        = true
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
        }
        container {
          name  = "garage"
          image = local.garage_image
          # --single-node assigns this node's layout on the first start, with
          # the data volume's size as its capacity, and changes nothing on
          # later starts. Garage refuses to start with it once a layout has
          # other nodes.
          args = ["/garage", "server", "--single-node"]
          dynamic "env" {
            for_each = {
              GARAGE_RPC_SECRET  = "rpc_secret"
              GARAGE_ADMIN_TOKEN = "admin_token"
            }
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = "garage-secrets"
                  key  = env.value
                }
              }
            }
          }
          env {
            # Plain log lines for Loki, without colour codes.
            name  = "NO_COLOR"
            value = "1"
          }
          port {
            name           = "s3"
            container_port = local.s3_port
          }
          port {
            name           = "rpc"
            container_port = 3901
          }
          port {
            name           = "admin"
            container_port = local.admin_port
          }
          # /health is unauthenticated: 200 while this node can serve reads
          # and writes.
          readiness_probe {
            http_get {
              path = "/health"
              port = local.admin_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 3
          }
          liveness_probe {
            tcp_socket {
              port = local.admin_port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/garage.toml"
            sub_path   = "garage.toml"
            read_only  = true
          }
          volume_mount {
            name       = "meta"
            mount_path = "/var/lib/garage/meta"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/garage/data"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              # block_ram_buffer_max defaults to 256 MiB, on top of LMDB's
              # mapped pages.
              memory = "1Gi"
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.garage.metadata[0].name
          }
        }
        volume {
          name = "meta"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.meta.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

# Cluster-only: no Ingress, no public host, no DNS record (V6). RPC (3901) is
# not on the Service; there is no other node to talk to.
resource "kubernetes_service" "garage" {
  metadata {
    name      = "garage"
    namespace = kubernetes_namespace.garage.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "s3"
      port        = local.s3_port
      target_port = local.s3_port
    }
    port {
      name        = "admin"
      port        = local.admin_port
      target_port = local.admin_port
    }
  }
}

# Who may connect. Ingress only; Garage's own egress is not policed.
#   S3 3900:    every Cloud Project namespace (Calico tier `cloud` must Pass
#               the traffic first: B26a adds that to the Project egress floor
#               in stacks/cloud, and Cloud's Project policy allows it only for
#               Projects with a Bucket), all of namespace cloud (console,
#               reconciler, `cloud bucket restore` Jobs), this namespace (the
#               backup CronJob) and uptime-kuma (its TCP monitor).
#   admin 3903: the reconciler and the console pods in cloud (buckets, keys,
#               quotas), monitoring (/metrics, open without a token), this
#               namespace (the backup's key and grants), and the node network
#               for the kubelet's readiness probe on /health. Every admin call
#               but /health and /metrics needs the admin token; /metrics is
#               open (garage.toml), so this list is what guards it.
resource "kubernetes_network_policy_v1" "garage" {
  metadata {
    name      = "garage"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { (local.cloud_managed_label) = "true" }
        }
      }
      dynamic "from" {
        for_each = ["cloud", local.namespace, "uptime-kuma"]
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
      ports {
        port     = tostring(local.s3_port)
        protocol = "TCP"
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "cloud" }
        }
        pod_selector {
          match_expressions {
            key      = "app"
            operator = "In"
            values   = ["cloud", "cloud-reconciler"]
          }
        }
      }
      dynamic "from" {
        for_each = ["monitoring", local.namespace]
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
      from {
        ip_block {
          cidr = "10.0.20.0/24"
        }
      }
      ports {
        port     = tostring(local.admin_port)
        protocol = "TCP"
      }
    }
  }
}

# ── Backup ──
#
# Nightly, for every bucket: rclone sync from Garage into
# /srv/nfs/cloud-buckets/current/<bucket>/, with what the sync overwrites or
# deletes moved to /srv/nfs/cloud-buckets/<YYYY-MM-DD>/<bucket>/; the newest 7
# dated directories stay (files/backup_sync.sh). Cloud's `cloud bucket
# restore` (B26c) reads that layout. So an object that changed every night has
# up to 8 copies: current plus 7 dated ones. /srv/nfs goes on to sda by
# nfs-mirror and to the Synology by offsite-sync, like every other dump.
#
# The directory must exist on the PVE host before the first run, owned by the
# backup uid:
#   ssh root@192.168.1.127 'mkdir -p /srv/nfs/cloud-buckets && chown 10001:10001 /srv/nfs/cloud-buckets && chmod 750 /srv/nfs/cloud-buckets'
module "nfs_backup" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "garage-backup-host"
  namespace          = kubernetes_namespace.garage.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/cloud-buckets"
  storage            = "100Gi"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_config_map" "backup" {
  metadata {
    name      = "garage-backup-scripts"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }
  data = {
    "backup_prepare.py" = file("${path.module}/files/backup_prepare.py")
    "backup_sync.sh"    = file("${path.module}/files/backup_sync.sh")
  }
}

resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "garage-backup"
    namespace = kubernetes_namespace.garage.metadata[0].name
    # Run by the Proxmox host's nightly-chain (scripts/nightly-chain.sh), not by
    # this schedule: "daily" means every night, with the other dumps, before
    # nfs-mirror copies /srv/nfs onwards.
    annotations = {
      "backup.viktorbarzin.me/nightly-chain" = "daily"
    }
  }
  spec {
    concurrency_policy = "Forbid"
    # Not used while suspended: nightly-chain starts the Job with
    # `kubectl create job --from=cronjob/garage-backup` (00:00 UTC onwards),
    # which still updates lastSuccessfulTime.
    schedule                      = "30 1 * * *"
    suspend                       = true
    starting_deadline_seconds     = 600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        # No retry: a failed run reports its failure and the next night tries
        # again; a retry would be a second run on the same day.
        backoff_limit = 0
        # Under nightly-chain's 2 h per-dump limit. A first sync of a full
        # 100 GiB store over NFS may need longer; then run it by hand.
        active_deadline_seconds = 6600
        template {
          metadata {
            labels = { app = "garage-backup" }
          }
          spec {
            restart_policy = "Never"
            security_context {
              run_as_user     = local.backup_uid
              run_as_group    = local.backup_uid
              run_as_non_root = true
            }
            init_container {
              name    = "prepare"
              image   = local.python_image
              command = ["python3", "-I", "/scripts/backup_prepare.py"]
              env {
                name  = "GARAGE_ADMIN_URL"
                value = local.admin_url
              }
              env {
                name  = "GARAGE_S3_URL"
                value = local.s3_url
              }
              env {
                name = "GARAGE_ADMIN_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "garage-secrets"
                    key  = "admin_token"
                  }
                }
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
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
            }
            container {
              name    = "sync"
              image   = local.rclone_image
              command = ["/bin/sh", "/scripts/backup_sync.sh"]
              env {
                name  = "BACKUP_ROOT"
                value = "/backup"
              }
              env {
                name  = "KEEP"
                value = "7"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              env {
                # rclone keeps its cache and lock files here.
                name  = "HOME"
                value = "/tmp"
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "512Mi"
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
            }
            volume {
              name = "scripts"
              config_map {
                name = kubernetes_config_map.backup.metadata[0].name
              }
            }
            # The backup key's secret: memory only, gone with the pod.
            volume {
              name = "work"
              empty_dir {
                medium     = "Memory"
                size_limit = "1Mi"
              }
            }
            volume {
              name = "tmp"
              empty_dir {
                size_limit = "256Mi"
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
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
