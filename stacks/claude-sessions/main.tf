# claude-sessions: the long-term store of every Claude Code session on the
# devvm (ADR-0039, docs/architecture/claude-session-store.md).
#
# A dedicated single-node ClickHouse, patterned on stacks/rybbit but kept
# separate: transcripts hold prompts, code and tool output, so the data lives
# on the encrypted SAS pool, and its upgrade path stays independent of rybbit.
#
#   devvm claude-sessions-ingest.timer --HTTPS--> ingest user (INSERT only)
#   homelab claude-sessions sql/schema --HTTPS--> reader user (SELECT, limits)
#   backup CronJob ------------------native-----> default (admin)
#   stacks/netsec Vector ------------HTTP-------> netsec_writer (INSERT netsec.*)
#   homelab netsec sql --------------HTTPS------> netsec_reader (SELECT netsec.*)
#
# The netsec database (network IDS data) shares this server but not its
# backup: backup.sh saves DATABASE claude only, so browsing data stays off NFS.
#
# Schema: files/schema.sql, run once by the image's initdb on an empty volume.
# Later schema changes are applied by hand as the default user and copied into
# schema.sql in the same commit (docs/runbooks/restore-claude-sessions.md).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

locals {
  namespace = "claude-sessions"
}

resource "kubernetes_namespace" "claude_sessions" {
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

# Vault secret/claude-sessions: clickhouse_password (default/admin),
# ingest_password, reader_password, netsec_writer_password,
# netsec_reader_password, netsec_alerts_password. The devvm playbook reads the same keys
# into /etc/claude-sessions/{ingest,reader}.env.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-sessions-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-sessions-secrets"
      }
      dataFrom = [{
        extract = {
          key = "claude-sessions"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.claude_sessions]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.claude_sessions.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Encrypted, and on the SAS pool where database engines live
# (docs/agents/databases.md), not on sdc, which is shared with etcd.
resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "claude-sessions-data-encrypted"
    namespace = kubernetes_namespace.claude_sessions.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "200Gi"
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
    # The autoresizer grows requests.storage; PVCs cannot shrink, so Terraform
    # must not try to set it back.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# Backups land here (files/backup.sh). The directory must exist on the PVE
# host first, owned by uid 101 (the clickhouse user):
#   ssh root@192.168.1.127 'mkdir -p /srv/nfs/claude-sessions-backup && chown 101:101 /srv/nfs/claude-sessions-backup && chmod 750 /srv/nfs/claude-sessions-backup'
# /srv/nfs is mirrored to sda and the Synology by nfs-mirror and offsite-sync.
module "nfs_backup" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "claude-sessions-backup-host"
  namespace          = kubernetes_namespace.claude_sessions.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/claude-sessions-backup"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_config_map" "clickhouse" {
  metadata {
    name      = "clickhouse-config"
    namespace = kubernetes_namespace.claude_sessions.metadata[0].name
  }
  data = {
    "config.xml" = file("${path.module}/files/config.xml")
    "users.xml"  = file("${path.module}/files/users.xml")
    "schema.sql" = file("${path.module}/files/schema.sql")
    "backup.sh"  = file("${path.module}/files/backup.sh")
  }
}

resource "kubernetes_deployment" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.claude_sessions.metadata[0].name
    labels = {
      app  = "clickhouse"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "clickhouse"
      }
    }
    template {
      metadata {
        labels = {
          app = "clickhouse"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9363"
          "prometheus.io/path"   = "/metrics"
        }
      }
      spec {
        security_context {
          run_as_user            = 101
          run_as_group           = 101
          fs_group               = 101
          fs_group_change_policy = "OnRootMismatch"
        }
        container {
          name = "clickhouse"
          # Literal pin so Renovate tracks it (renovate.json5 "Shape A"), the
          # same tag as stacks/rybbit so one upgrade procedure covers both.
          # Parts written by 26.x cannot be read by 25.x: back up before a bump.
          image = "clickhouse/clickhouse-server:26.10.3.7"
          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "claude-sessions-secrets"
                key  = "clickhouse_password"
              }
            }
          }
          env {
            name = "CLAUDE_SESSIONS_INGEST_PASSWORD"
            value_from {
              secret_key_ref {
                name = "claude-sessions-secrets"
                key  = "ingest_password"
              }
            }
          }
          env {
            name = "CLAUDE_SESSIONS_READER_PASSWORD"
            value_from {
              secret_key_ref {
                name = "claude-sessions-secrets"
                key  = "reader_password"
              }
            }
          }
          # netsec database (docs/architecture/network-security-monitoring.md):
          # the stacks/netsec Vector writes, Viktor reads.
          env {
            name = "NETSEC_WRITER_PASSWORD"
            value_from {
              secret_key_ref {
                name = "claude-sessions-secrets"
                key  = "netsec_writer_password"
              }
            }
          }
          env {
            name = "NETSEC_READER_PASSWORD"
            value_from {
              secret_key_ref {
                name = "claude-sessions-secrets"
                key  = "netsec_reader_password"
              }
            }
          }
          env {
            name = "NETSEC_ALERTS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "claude-sessions-secrets"
                key  = "netsec_alerts_password"
              }
            }
          }
          port {
            name           = "http"
            container_port = 8123
          }
          port {
            name           = "native"
            container_port = 9000
          }
          port {
            name           = "metrics"
            container_port = 9363
          }
          liveness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 5
            period_seconds        = 15
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/clickhouse"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/clickhouse-server/config.d/claude.xml"
            sub_path   = "config.xml"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/clickhouse-server/users.d/claude-users.xml"
            sub_path   = "users.xml"
          }
          volume_mount {
            name       = "config"
            mount_path = "/docker-entrypoint-initdb.d/schema.sql"
            sub_path   = "schema.sql"
          }
          volume_mount {
            name       = "backups"
            mount_path = "/backups"
          }
          resources {
            requests = {
              cpu    = "250m"
              memory = "1Gi"
            }
            limits = {
              memory = "4Gi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.clickhouse.metadata[0].name
          }
        }
        volume {
          name = "backups"
          persistent_volume_claim {
            claim_name = module.nfs_backup.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.claude_sessions.metadata[0].name
    labels = {
      app = "clickhouse"
    }
  }
  spec {
    selector = {
      app = "clickhouse"
    }
    port {
      name        = "http"
      port        = 8123
      target_port = 8123
    }
    port {
      name        = "native"
      port        = 9000
      target_port = 9000
    }
  }
}

# HTTPS for the devvm (ingest timer and the homelab verb). LAN/VPN only:
# dns_type "internal" publishes the internal Traefik LB address, and
# allow_local_access_only adds the IP allowlist. ClickHouse's own users and
# passwords are the authentication; there is no browser to hold an SSO cookie.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the clients are the devvm ingest timer and the homelab CLI,
  # not browsers, so there is no SSO cookie. ClickHouse users and passwords
  # authenticate, and allow_local_access_only limits it to the LAN/VPN.
  auth                    = "none"
  namespace               = kubernetes_namespace.claude_sessions.metadata[0].name
  name                    = "claude-sessions-db"
  service_name            = kubernetes_service.clickhouse.metadata[0].name
  port                    = 8123
  root_domain             = "viktorbarzin.me"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  dns_type                = "internal"
  external_monitor        = false
  # Ingest bursts several 8 MB inserts in a row; the default limit is sized
  # for browsers.
  skip_default_rate_limit = true
  # ClickHouse answers many query errors (bad SQL, illegal aggregation) with
  # HTTP 500 and the reason in the body. The shared error-pages middleware
  # replaced that body with a generic HTML page, so an agent writing SQL never
  # saw what was wrong.
  skip_error_pages = true
  extra_annotations = {
    "gethomepage.dev/description" = "ClickHouse store of every Claude Code session (LAN only)"
    "gethomepage.dev/icon"        = "clickhouse.png"
  }
}

# Nightly native BACKUP to NFS: weekly full (Sunday) plus daily incrementals.
# Runs as uid 101 so it can prune the directories the server writes.
resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "clickhouse-backup"
    namespace = kubernetes_namespace.claude_sessions.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    schedule                      = "40 1 * * *"
    starting_deadline_seconds     = 600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            security_context {
              run_as_user  = 101
              run_as_group = 101
            }
            container {
              name = "backup"
              # Must match the server tag: clickhouse-client of the same release.
              image   = "clickhouse/clickhouse-server:26.10.3.7"
              command = ["/bin/bash", "/scripts/backup.sh"]
              env {
                name  = "CH_HOST"
                value = "${kubernetes_service.clickhouse.metadata[0].name}.${local.namespace}.svc.cluster.local"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              env {
                name = "CLICKHOUSE_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "claude-sessions-secrets"
                    key  = "clickhouse_password"
                  }
                }
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
                name       = "backups"
                mount_path = "/backups"
              }
            }
            volume {
              name = "scripts"
              config_map {
                name = kubernetes_config_map.clickhouse.metadata[0].name
                items {
                  key  = "backup.sh"
                  path = "backup.sh"
                }
              }
            }
            volume {
              name = "backups"
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
