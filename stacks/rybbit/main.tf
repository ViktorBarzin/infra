variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "rybbit"
}

resource "kubernetes_namespace" "rybbit" {
  metadata {
    name = "rybbit"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "rybbit-secrets"
      namespace = "rybbit"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "rybbit-secrets"
      }
      dataFrom = [{
        extract = {
          key = "rybbit"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.rybbit]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

locals {
  clickhouse_db = "clickhouse"
}


resource "kubernetes_persistent_volume_claim" "clickhouse_data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "rybbit-clickhouse-data-proxmox"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
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
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_config_map" "clickhouse_memory" {
  metadata {
    name      = "clickhouse-memory-config"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  data = {
    "memory.xml" = <<-EOF
      <clickhouse>
          <max_server_memory_usage>1258291200</max_server_memory_usage>
          <!-- Disable high-churn system logs to reduce disk writes -->
          <trace_log remove="1"/>
          <text_log remove="1"/>
          <metric_log remove="1"/>
          <asynchronous_metric_log remove="1"/>
          <query_log remove="1"/>
          <part_log remove="1"/>
          <processors_profile_log remove="1"/>
          <query_metric_log remove="1"/>
          <error_log remove="1"/>
          <latency_log remove="1"/>
      </clickhouse>
    EOF
    # ClickHouse's built-in Prometheus endpoint, scraped by the annotation-driven
    # kubernetes-pods job (pod annotations below). Gives the DB checks and the
    # ClickHouseDown alert a signal (software-currency design, Groundwork).
    # Measured on a scratch 26.9.14.10 pod: about 1,300 series with events off,
    # 2,884 with them on (1,586 ProfileEvents counters, mostly zero). Events and
    # errors stay off until a dashboard or alert needs them.
    "prometheus.xml" = <<-EOF
      <clickhouse>
          <prometheus>
              <endpoint>/metrics</endpoint>
              <port>9363</port>
              <metrics>true</metrics>
              <events>false</events>
              <asynchronous_metrics>true</asynchronous_metrics>
              <errors>false</errors>
          </prometheus>
      </clickhouse>
    EOF
  }
}

resource "kubernetes_deployment" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "clickhouse"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
      # Keel opts out: Terraform owns the image tag below. ClickHouse storage
      # changes are one-way across major lines, so a version bump needs a
      # dump first and a deliberate hop, not an automatic roll.
      "keel.sh/policy" = "never"
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
          run_as_user  = 101
          run_as_group = 101
          fs_group     = 101
        }
        container {
          name = "clickhouse"
          # Exact pin, owned by Terraform (not in lifecycle.ignore_changes).
          # Parts written on 26.x cannot be read by 25.x (Map/JSON/String
          # serialization changes), so dump clickhouse.events in Native format
          # before bumping, and keep each hop within ClickHouse's one-year
          # compatibility window.
          image = "clickhouse/clickhouse-server:26.9.14.10"
          env {
            name  = "CLICKHOUSE_DB"
            value = local.clickhouse_db
          }
          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "clickhouse_password"
              }
            }
          }
          port {
            name           = "clickhouse"
            protocol       = "TCP"
            container_port = 8123
          }
          port {
            name           = "metrics"
            protocol       = "TCP"
            container_port = 9363
          }
          liveness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 15
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
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/clickhouse"
          }
          volume_mount {
            name       = "memory-config"
            mount_path = "/etc/clickhouse-server/config.d/memory.xml"
            sub_path   = "memory.xml"
          }
          volume_mount {
            name       = "memory-config"
            mount_path = "/etc/clickhouse-server/config.d/prometheus.xml"
            sub_path   = "prometheus.xml"
          }
          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              memory = "1536Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.clickhouse_data_proxmox.metadata[0].name
          }
        }
        volume {
          name = "memory-config"
          config_map {
            name = kubernetes_config_map.clickhouse_memory.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],                      # KEEL_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      "app" = "clickhouse"
    }
  }

  spec {
    selector = {
      app = "clickhouse"
    }
    port {
      name        = "http"
      target_port = 8123
      port        = 8123
      protocol    = "TCP"
    }
    # Native protocol, for clickhouse-client (the backup CronJob below). The
    # server already listens on 9000; only the Service lacked the port.
    port {
      name        = "native"
      target_port = 9000
      port        = 9000
      protocol    = "TCP"
    }
  }
}

# CronJob to truncate ClickHouse system log tables every 6 hours.
# These tables grow unboundedly on NFS and trigger CPU-heavy background merges.
resource "kubernetes_cron_job_v1" "clickhouse_truncate_logs" {
  metadata {
    name      = "clickhouse-truncate-logs"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "truncate"
              image = "curlimages/curl:8.12.1"
              command = [
                "sh", "-c",
                join(" && ", [
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${data.vault_kv_secret_v2.secrets.data["clickhouse_password"]}' -d 'TRUNCATE TABLE IF EXISTS system.metric_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${data.vault_kv_secret_v2.secrets.data["clickhouse_password"]}' -d 'TRUNCATE TABLE IF EXISTS system.trace_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${data.vault_kv_secret_v2.secrets.data["clickhouse_password"]}' -d 'TRUNCATE TABLE IF EXISTS system.text_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${data.vault_kv_secret_v2.secrets.data["clickhouse_password"]}' -d 'TRUNCATE TABLE IF EXISTS system.asynchronous_metric_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${data.vault_kv_secret_v2.secrets.data["clickhouse_password"]}' -d 'TRUNCATE TABLE IF EXISTS system.query_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${data.vault_kv_secret_v2.secrets.data["clickhouse_password"]}' -d 'TRUNCATE TABLE IF EXISTS system.part_log'",
                  "echo 'System logs truncated'"
                ])
              ]
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

# Daily logical backup of ClickHouse to the PVE NFS share
# (192.168.1.127:/srv/nfs/clickhouse-backup). Software-currency groundwork
# (docs/plans/2026-10-09-software-currency-design.md): the pre-upgrade
# snapshot step needs a backup to run before a ClickHouse bump.
#
# Each run writes /backup/<UTC yyyymmdd-hhmm>/ with, per user table, the
# schema (<db>.<table>.sql, from SHOW CREATE) and the data in Native format
# (<db>.<table>.native.gz), plus VERSION, counts.tsv and SHA256SUMS. Before
# the directory is written, the job restores the whole dump into
# clickhouse-local from the same image and checks every table's row count, so
# a dump that does not read back never lands. 14-day retention. Restore:
# docs/runbooks/restore-clickhouse.md.
#
# The image must match the server tag above: Native files and SHOW CREATE
# output are read back by the same release that wrote them.
module "nfs_clickhouse_backup" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "rybbit-clickhouse-backup-host"
  namespace          = kubernetes_namespace.rybbit.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/clickhouse-backup"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_cron_job_v1" "clickhouse_backup" {
  metadata {
    name      = "clickhouse-backup"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    schedule                      = "10 1 * * *"
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
            container {
              name  = "clickhouse-backup"
              image = "clickhouse/clickhouse-server:26.9.14.10"
              env {
                name  = "CH_HOST"
                value = "${kubernetes_service.clickhouse.metadata[0].name}.${kubernetes_namespace.rybbit.metadata[0].name}.svc.cluster.local"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              env {
                name = "CLICKHOUSE_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "rybbit-secrets"
                    key  = "clickhouse_password"
                  }
                }
              }
              command = ["/bin/bash", "-c", <<-EOT
                set -eu
                # Runs in the clickhouse-server image that matches the server. Dumps every
                # user table (schema as SQL, data in Native format), restores the dump into
                # clickhouse-local to prove it reads back, then writes it to NFS.
                ch() { clickhouse-client --host "$CH_HOST" --port 9000 --user default --password "$CLICKHOUSE_PASSWORD" "$@"; }
                t0=$(date -u +%s)
                TS=$(date -u +%Y%m%d-%H%M)
                work=/tmp/dump
                mkdir -p "$work"
                ch -q "SELECT version()" > "$work/VERSION"
                ch -q "SELECT name FROM system.databases WHERE name NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA') ORDER BY name FORMAT TSV" > "$work/databases"
                ch -q "SELECT database, name, engine LIKE '%MergeTree' OR engine IN ('Log', 'TinyLog', 'StripeLog', 'Memory') FROM system.tables WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA') AND NOT is_temporary ORDER BY database, name FORMAT TSV" > "$work/tables.tsv"
                : > "$work/counts.tsv"
                while read -r db; do
                  ch -q "SHOW CREATE DATABASE \`$db\` FORMAT TSVRaw" > "$work/$db.database.sql"
                done < "$work/databases"
                while IFS="$(printf '\t')" read -r db t hasdata; do
                  ch -q "SHOW CREATE TABLE \`$db\`.\`$t\` FORMAT TSVRaw" > "$work/$db.$t.sql"
                  if [ "$hasdata" = 1 ]; then
                    n=$(ch -q "SELECT count() FROM \`$db\`.\`$t\`")
                    ch -q "SELECT * FROM \`$db\`.\`$t\` FORMAT Native" | gzip -6 > "$work/$db.$t.native.gz"
                    printf '%s\t%s\t%s\n' "$db" "$t" "$n" >> "$work/counts.tsv"
                  fi
                done < "$work/tables.tsv"

                # Restore check: tables that hold data first, then everything else (views).
                r="$work/restore.sql"
                : > "$r"
                while read -r db; do
                  [ "$db" = default ] || { cat "$work/$db.database.sql"; echo ";"; } >> "$r"
                done < "$work/databases"
                for pass in 1 0; do
                  while IFS="$(printf '\t')" read -r db t hasdata; do
                    [ "$hasdata" = "$pass" ] || continue
                    { cat "$work/$db.$t.sql"; echo ";"; } >> "$r"
                    [ "$hasdata" = 1 ] && echo "INSERT INTO \`$db\`.\`$t\` SELECT * FROM file('$work/$db.$t.native.gz', 'Native');" >> "$r"
                  done < "$work/tables.tsv"
                done
                clickhouse-local --path /tmp/restore --queries-file "$r"
                fail=0
                while IFS="$(printf '\t')" read -r db t n; do
                  got=$(clickhouse-local --path /tmp/restore -q "SELECT count() FROM \`$db\`.\`$t\`")
                  echo "table $db.$t source=$n restored=$got"
                  [ "$got" -ge "$n" ] || fail=1
                done < "$work/counts.tsv"
                [ "$fail" -eq 0 ] || { echo "restore check failed, not writing the backup"; exit 1; }

                out=/backup/$TS
                mkdir -p "$out.partial"
                cp "$work"/*.sql "$work"/*.native.gz "$work/VERSION" "$work/databases" "$work/tables.tsv" "$work/counts.tsv" "$out.partial/"
                rm -f "$out.partial/restore.sql"
                (cd "$out.partial" && sha256sum * > SHA256SUMS)
                mv "$out.partial" "$out"
                find /backup -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +14 -exec rm -rf {} +
                find /backup -mindepth 1 -maxdepth 1 -type d -name '*.partial' -mtime +1 -exec rm -rf {} +

                dur=$(( $(date -u +%s) - t0 ))
                bytes=$(du -sb "$out" | cut -f1)
                echo "backup written: $out ($bytes bytes, $dur s)"; ls -l "$out"
                printf 'backup_duration_seconds %s\nbackup_output_bytes %s\nbackup_last_success_timestamp %s\n' "$dur" "$bytes" "$(date -u +%s)" > /tmp/metrics
                wget -qO- --post-file=/tmp/metrics "$PUSHGATEWAY/metrics/job/clickhouse-backup" || echo "pushgateway push failed"
              EOT
              ]
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "256Mi"
                }
                limits = {
                  memory = "1Gi"
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
                claim_name = module.nfs_clickhouse_backup.claim_name
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

# Ensure the rybbit Postgres database exists before the app starts. The rybbit
# ROLE is managed elsewhere (Vault/ESO) and has CREATEDB; the DATABASE itself
# was missing after a past CNPG rebuild (role survived, db did not), so
# rybbit's node-cron logged 'database "rybbit" does not exist' every minute
# (found via Loki 2026-06-06). Idempotent: connect as rybbit to the default
# 'postgres' db and CREATE DATABASE only if absent. Self-contained — uses the
# rybbit password from rybbit-secrets (no root creds needed).
resource "kubernetes_job" "db_init" {
  metadata {
    name      = "rybbit-db-init"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  spec {
    template {
      metadata {}
      spec {
        container {
          name  = "db-init"
          image = "postgres:16-alpine"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              psql -h ${var.postgresql_host} -U rybbit -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='rybbit'" | grep -q 1 || \
                psql -h ${var.postgresql_host} -U rybbit -d postgres -c "CREATE DATABASE rybbit OWNER rybbit"
              echo "rybbit database ensured"
            EOT
          ]
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "postgres_password"
              }
            }
          }
        }
        restart_policy = "Never"
      }
    }
    backoff_limit = 3
  }
  wait_for_completion = true
  timeouts {
    create = "2m"
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno mutates the pod dns_config (ndots) on
    # admission; ignore it so a completed job doesn't show perpetual drift.
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

resource "kubernetes_deployment" "rybbit" {
  depends_on = [kubernetes_job.db_init]
  metadata {
    name      = "rybbit"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "rybbit"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "rybbit"
      }
    }
    template {
      metadata {
        labels = {
          app = "rybbit"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^v?\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432,clickhouse.rybbit:8123"
        }
      }
      spec {
        container {
          image = "ghcr.io/rybbit-io/rybbit-backend:v1.1.0"
          name  = "rybbit"

          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "CLICKHOUSE_HOST"
            value = "http://clickhouse.rybbit.svc.cluster.local:8123"
          }
          env {
            name  = "CLICKHOUSE_DB"
            value = local.clickhouse_db
          }
          env {
            name  = "CLICKHOUSE_USER"
            value = "default"
          }
          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "clickhouse_password"
              }
            }
          }
          env {
            name  = "POSTGRES_HOST"
            value = var.postgresql_host
          }
          env {
            name  = "POSTGRES_PORT"
            value = "5432"
          }
          env {
            name  = "POSTGRES_DB"
            value = "rybbit"
          }
          env {
            name  = "POSTGRES_USER"
            value = "rybbit"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "postgres_password"
              }
            }
          }
          env {
            name  = "BASE_URL"
            value = "https://rybbit.viktorbarzin.me"
          }
          env {
            name  = "DISABLE_SIGNUP"
            value = "true"
          }
          env {
            name  = "BETTER_AUTH_SECRET"
            value = random_string.random.result
          }
          env {
            name  = "AUTH_ENABLED"
            value = "true"
          }
          port {
            container_port = 3001
          }
          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3001
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3001
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "384Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],                      # KEEL_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "rybbit" {
  metadata {
    name      = "rybbit"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      "app" = "rybbit"
    }
  }

  spec {
    selector = {
      "app" = "rybbit"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3001
    }
  }
}

resource "kubernetes_deployment" "rybbit-client" {
  metadata {
    name      = "rybbit-client"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "rybbit-client"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "rybbit-client"
      }
    }
    template {
      metadata {
        labels = {
          app = "rybbit-client"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "rybbit.rybbit:80"
        }
      }
      spec {
        container {
          name  = "rybbit-client"
          image = "ghcr.io/rybbit-io/rybbit-client:v1.1.0"
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "DISABLE_SIGNUP"
            value = "true"
          }
          port {
            name           = "rybbit-client"
            protocol       = "TCP"
            container_port = 3002
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3002
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3002
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "192Mi"
            }
            limits = {
              memory = "192Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "rybbit-client" {
  metadata {
    name      = "rybbit-client"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      "app" = "rybbit-client"
    }
  }

  spec {
    selector = {
      "app" = "rybbit-client"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3002
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  name            = "rybbit"
  service_name    = "rybbit-client"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Rybbit"
    "gethomepage.dev/description"  = "Web analytics"
    "gethomepage.dev/icon"         = "rybbit.png"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

module "ingress-api" {
  source = "../../modules/kubernetes/ingress_factory"
  # Analytics tracker beacon — public websites embed Rybbit's /api/script.js
  # and post events to /api/event. Forward-auth would 302 every tracking
  # request and break analytics collection. Rybbit's site_id is the gate.
  # auth = "none": Analytics tracker API — public websites embed /api/script.js and POST events; forward-auth breaks tracking collection.
  auth            = "none"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  name            = "rybbit-api"
  host            = "rybbit"
  service_name    = "rybbit"
  ingress_path    = ["/api"]
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
