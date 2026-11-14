# ClickHouse settings Rybbit does not manage itself (ADR-0041):
#  - replay tables kept 90 days. Rybbit creates them with a 30-day TTL
#    and `CREATE TABLE IF NOT EXISTS`, so an ALTER survives restarts. An
#    upgrade that recreates a table would bring 30 days back, which is
#    why this runs on a schedule and only alters a table that has drifted.
#  - the Raw events store for the Event pipeline (events_raw.events),
#    kept forever. The daily clickhouse-backup dumps every database, so it
#    is backed up and mirrored offsite without further changes.

locals {
  replay_retention_days = 90

  clickhouse_schema_script = <<-EOT
    set -eu
    ch() { clickhouse-client --host clickhouse --port 9000 --user default --password "$CLICKHOUSE_PASSWORD" "$@"; }

    for spec in \
      "session_replay_events|toDateTime(timestamp)" \
      "session_replay_metadata|start_time" \
      "session_replay_metadata_v2|toDateTime(start_time)"; do
      t=$${spec%%|*}
      e=$${spec#*|}
      exists=$(ch -q "SELECT count() FROM system.tables WHERE database = '${local.clickhouse_db}' AND name = '$t'")
      if [ "$exists" != 1 ]; then
        echo "$t: not created yet, skipping"
        continue
      fi
      cur=$(ch -q "SELECT engine_full FROM system.tables WHERE database = '${local.clickhouse_db}' AND name = '$t'")
      case "$cur" in
        *"toIntervalDay(${local.replay_retention_days})"*) echo "$t: already ${local.replay_retention_days} days" ;;
        *)
          ch -q "ALTER TABLE ${local.clickhouse_db}.$t MODIFY TTL $e + INTERVAL ${local.replay_retention_days} DAY"
          echo "$t: TTL set to ${local.replay_retention_days} days"
          ;;
      esac
    done

    ch -q "CREATE DATABASE IF NOT EXISTS events_raw"
    ch -q "
      CREATE TABLE IF NOT EXISTS events_raw.events (
        received_at  DateTime64(3, 'UTC') DEFAULT now64(3),
        app          LowCardinality(String),
        type         LowCardinality(String),
        event        String,
        message_id   String,
        anonymous_id String,
        user_id      String,
        sent_at      Nullable(DateTime64(3, 'UTC')),
        client_ip    String,
        user_agent   String,
        payload      String
      )
      ENGINE = MergeTree
      PARTITION BY toYYYYMM(received_at)
      ORDER BY (app, received_at)
    "
    echo "events_raw.events: present"
  EOT
}

resource "kubernetes_config_map" "clickhouse_schema" {
  metadata {
    name      = "clickhouse-schema"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  data = {
    "schema.sh" = local.clickhouse_schema_script
  }
}

locals {
  clickhouse_schema_pod = {
    image = "clickhouse/clickhouse-server:26.10.4.207"
  }
}

# Runs every 6 hours so an upgrade that resets a TTL is corrected the same day.
resource "kubernetes_cron_job_v1" "clickhouse_schema" {
  metadata {
    name      = "clickhouse-schema"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  spec {
    schedule                      = "17 */6 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
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
              name    = "schema"
              image   = local.clickhouse_schema_pod.image
              command = ["/bin/sh", "/scripts/schema.sh"]
              env {
                name = "CLICKHOUSE_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "rybbit-secrets"
                    key  = "clickhouse_password"
                  }
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "scripts"
              config_map {
                name = kubernetes_config_map.clickhouse_schema.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].job_template[0].spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

# One run at apply time, so a change takes effect without waiting for the
# schedule. The name carries the script hash: a new script means a new Job.
resource "kubernetes_job" "clickhouse_schema" {
  metadata {
    name      = "clickhouse-schema-${substr(sha1(local.clickhouse_schema_script), 0, 8)}"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 86400
    template {
      metadata {
        annotations = {
          "dependency.kyverno.io/wait-for" = "clickhouse.rybbit:9000"
        }
      }
      spec {
        restart_policy = "Never"
        container {
          name    = "schema"
          image   = local.clickhouse_schema_pod.image
          command = ["/bin/sh", "/scripts/schema.sh"]
          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "clickhouse_password"
              }
            }
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map.clickhouse_schema.metadata[0].name
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "10m"
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}
