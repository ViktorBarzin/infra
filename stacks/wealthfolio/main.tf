variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }

resource "kubernetes_namespace" "wealthfolio" {
  metadata {
    name = "wealthfolio"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "wealthfolio-secrets"
      namespace = "wealthfolio"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "wealthfolio-secrets"
      }
      dataFrom = [{
        extract = {
          key = "wealthfolio"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.wealthfolio]
}

# DB credentials for the SQLite→PG ETL sidecar. Vault DB engine static role
# `pg-wealthfolio-sync` rotates this every 7 days; ExternalSecret refreshes
# the K8s Secret every 15m so the sidecar always has a valid password.
resource "kubernetes_manifest" "wealthfolio_sync_db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "wealthfolio-sync-db-creds"
      namespace = "wealthfolio"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "wealthfolio-sync-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            PGHOST     = var.postgresql_host
            PGPORT     = "5432"
            PGDATABASE = "wealthfolio_sync"
            PGUSER     = "wealthfolio_sync"
            PGPASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-wealthfolio-sync"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.wealthfolio]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.wealthfolio.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "wealthfolio-data-proxmox"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
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
}

resource "kubernetes_deployment" "wealthfolio" {
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    labels = {
      app  = "wealthfolio"
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
        app = "wealthfolio"
      }
    }
    template {
      metadata {
        labels = {
          app = "wealthfolio"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v?\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "afadil/wealthfolio:3.2"
          name  = "wealthfolio"
          port {
            container_port = 8080
          }
          env {
            name  = "WF_LISTEN_ADDR"
            value = "0.0.0.0:8080"
          }
          env {
            name = "WF_AUTH_PASSWORD_HASH"
            value_from {
              secret_key_ref {
                name = "wealthfolio-secrets"
                key  = "password_hash"
              }
            }
          }
          env {
            name  = "WF_DB_PATH"
            value = "/data/wealthfolio.db"
          }
          env {
            name  = "WF_CORS_ALLOW_ORIGINS"
            value = "https://authentik.viktorbarzin.me"
          }
          env {
            name  = "WF_AUTH_TOKEN_TTL_MINUTES"
            value = "10080"
          }
          env {
            name  = "WF_SECRET_KEY"
            value = random_string.random.result
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # 2026-04-18 OOM after broker-sync Phase 3 landed (~700 activities
          # across 6 accounts including Fidelity + matched cash flows). The
          # /api/v1/net-worth + /valuations/history endpoints materialise the
          # full history in memory for the chart; 64Mi was a Phase-0 guess
          # that fit a 10-activity demo DB and nothing bigger.
          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        # Backup sidecar — see the big comment further down. Shares the WF
        # data PVC (read-only) + the NFS backup target. busybox crond fires
        # a nightly sqlite3 .backup so we have an off-cluster copy.
        container {
          name  = "backup"
          image = "alpine:3.20"
          command = ["/bin/sh", "-c", <<-EOT
          set -eu
          apk add --no-cache --quiet sqlite busybox-suid
          mkdir -p /etc/crontabs
          cat >/etc/crontabs/root <<'CRON'
          30 4 * * * /scripts/backup.sh >>/proc/1/fd/1 2>&1
          CRON
          mkdir -p /scripts
          cat >/scripts/backup.sh <<'SCRIPT'
          #!/bin/sh
          set -eu
          TS=$(date +%Y-%m-%dT%H-%M-%S)
          DIR=/backup/$TS
          mkdir -p "$DIR"
          sqlite3 /data/wealthfolio.db ".backup $DIR/wealthfolio.db"
          cp /data/secrets.json "$DIR/" 2>/dev/null || true
          # Retention — keep 30 days.
          find /backup -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
          echo "wealthfolio-backup: $DIR ($(du -sh $DIR | cut -f1))"
          SCRIPT
          chmod +x /scripts/backup.sh
          echo "wealthfolio-backup sidecar ready; next 04:30 UTC"
          exec crond -f -l 8
          EOT
          ]
          volume_mount {
            name       = "data"
            mount_path = "/data"
            read_only  = true
          }
          volume_mount {
            name       = "backup"
            mount_path = "/backup"
          }
          resources {
            requests = { cpu = "5m", memory = "16Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        # pg-sync sidecar — mirrors a small subset of SQLite into PG every hour
        # so Grafana can chart net worth / contributions / growth via the
        # `wealthfolio_sync` database. Mounts /data RO; writes to a tmp dir
        # for the sqlite3 .backup snapshot to avoid blocking writers. Bootstrap
        # DDL runs each iteration (CREATE TABLE IF NOT EXISTS — idempotent).
        # Truncate-and-reload pattern: tables are small (~10k DAV rows, ~500
        # activities, 6 accounts), so a full reload each hour is simpler than
        # incremental upserts and gives clean cold-start behaviour.
        container {
          name  = "pg-sync"
          image = "alpine:3.20"
          env {
            name = "PGHOST"
            value_from {
              secret_key_ref {
                name = "wealthfolio-sync-db-creds"
                key  = "PGHOST"
              }
            }
          }
          env {
            name = "PGPORT"
            value_from {
              secret_key_ref {
                name = "wealthfolio-sync-db-creds"
                key  = "PGPORT"
              }
            }
          }
          env {
            name = "PGDATABASE"
            value_from {
              secret_key_ref {
                name = "wealthfolio-sync-db-creds"
                key  = "PGDATABASE"
              }
            }
          }
          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = "wealthfolio-sync-db-creds"
                key  = "PGUSER"
              }
            }
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "wealthfolio-sync-db-creds"
                key  = "PGPASSWORD"
              }
            }
          }
          command = ["/bin/sh", "-c", <<-EOT
          set -eu
          apk add --no-cache --quiet sqlite postgresql-client busybox-suid
          mkdir -p /etc/crontabs /scripts /tmp/wf-sync
          cat >/etc/crontabs/root <<'CRON'
          # Hourly: snapshot SQLite, reload PG mirror.
          7 * * * * /scripts/sync.sh >>/proc/1/fd/1 2>&1
          CRON
          cat >/scripts/sync.sh <<'SCRIPT'
          #!/bin/sh
          set -eu
          TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          echo "[$TS] wealthfolio-pg-sync: starting"

          # Bootstrap schema (idempotent).
          psql -v ON_ERROR_STOP=1 <<'SQL'
          CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            name TEXT,
            account_type TEXT,
            currency TEXT,
            is_active BOOLEAN
          );
          CREATE TABLE IF NOT EXISTS daily_account_valuation (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            valuation_date DATE NOT NULL,
            account_currency TEXT,
            base_currency TEXT,
            fx_rate_to_base NUMERIC,
            cash_balance NUMERIC,
            investment_market_value NUMERIC,
            total_value NUMERIC,
            cost_basis NUMERIC,
            net_contribution NUMERIC
          );
          CREATE INDEX IF NOT EXISTS idx_dav_acct_date ON daily_account_valuation(account_id, valuation_date);
          CREATE INDEX IF NOT EXISTS idx_dav_date ON daily_account_valuation(valuation_date);
          CREATE TABLE IF NOT EXISTS activities (
            id TEXT PRIMARY KEY,
            account_id TEXT,
            asset_id TEXT,
            activity_type TEXT,
            activity_date TIMESTAMPTZ,
            quantity NUMERIC,
            unit_price NUMERIC,
            amount NUMERIC,
            fee NUMERIC,
            currency TEXT,
            fx_rate NUMERIC,
            notes TEXT
          );
          CREATE INDEX IF NOT EXISTS idx_act_date ON activities(activity_date);
          SQL

          # Snapshot SQLite (online backup — non-blocking).
          rm -f /tmp/wf-sync/snapshot.db
          sqlite3 /data/wealthfolio.db ".backup /tmp/wf-sync/snapshot.db"

          # Dump source rows to TSV.
          sqlite3 -separator $'\t' /tmp/wf-sync/snapshot.db \
            "SELECT id, name, account_type, currency, is_active FROM accounts;" \
            > /tmp/wf-sync/accounts.tsv

          sqlite3 -separator $'\t' /tmp/wf-sync/snapshot.db <<'SQ' > /tmp/wf-sync/dav.tsv
          SELECT id, account_id, valuation_date, account_currency, base_currency,
                 CAST(fx_rate_to_base AS REAL),
                 CAST(cash_balance AS REAL),
                 CAST(investment_market_value AS REAL),
                 CAST(total_value AS REAL),
                 CAST(cost_basis AS REAL),
                 CAST(net_contribution AS REAL)
          FROM daily_account_valuation
          WHERE account_id != 'TOTAL';  -- synthetic pre-aggregated row; would double-count when summed
          SQ

          sqlite3 -separator $'\t' /tmp/wf-sync/snapshot.db <<'SQ' > /tmp/wf-sync/activities.tsv
          SELECT id, account_id, asset_id, activity_type, activity_date,
                 CAST(quantity AS REAL),
                 CAST(unit_price AS REAL),
                 CAST(amount AS REAL),
                 CAST(fee AS REAL),
                 currency,
                 CAST(fx_rate AS REAL),
                 notes
          FROM activities WHERE status='POSTED';
          SQ

          # Truncate-and-reload (small tables; simpler than upserts).
          psql -v ON_ERROR_STOP=1 <<SQL
          BEGIN;
          TRUNCATE accounts, daily_account_valuation, activities;
          \copy accounts FROM '/tmp/wf-sync/accounts.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy daily_account_valuation FROM '/tmp/wf-sync/dav.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy activities FROM '/tmp/wf-sync/activities.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          COMMIT;
          SQL

          ROWS=$(psql -tAc "SELECT COUNT(*) FROM daily_account_valuation;")
          echo "[$TS] wealthfolio-pg-sync: ok (daily_account_valuation rows=$ROWS)"
          rm -f /tmp/wf-sync/*.tsv /tmp/wf-sync/snapshot.db
          SCRIPT
          chmod +x /scripts/sync.sh
          echo "wealthfolio-pg-sync sidecar ready; running initial sync, then hourly at :07"
          /scripts/sync.sh || echo "initial sync failed (will retry on next cron tick)"
          exec crond -f -l 8
          EOT
          ]
          volume_mount {
            name       = "data"
            mount_path = "/data"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = "wealthfolio-data-encrypted"
          }
        }
        volume {
          name = "backup"
          nfs {
            server = var.nfs_server
            path   = "/srv/nfs/wealthfolio-backup"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wealthfolio" {
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    labels = {
      "app" = "wealthfolio"
    }
  }

  spec {
    selector = {
      app = "wealthfolio"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.wealthfolio.metadata[0].name
  name            = "wealthfolio"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Wealthfolio"
    "gethomepage.dev/description"  = "Investment portfolio tracker"
    "gethomepage.dev/icon"         = "mdi-finance"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

resource "kubernetes_cron_job_v1" "wealthfolio_sync" {
  metadata {
    name      = "wealthfolio-sync"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }
  spec {
    schedule                      = "0 8 1 * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "sync"
              image = "registry.viktorbarzin.me/wealthfolio-sync:latest"
              env {
                name = "IMAP_HOST"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_host"
                  }
                }
              }
              env {
                name = "IMAP_USER"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_user"
                  }
                }
              }
              env {
                name = "IMAP_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_password"
                  }
                }
              }
              env {
                name = "IMAP_DIRECTORY"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_directory"
                  }
                }
              }
              env {
                name = "TRADING212_API_KEYS"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "trading212_api_keys"
                  }
                }
              }
              env {
                name  = "DB_PATH"
                value = "/data/wealthfolio.db"
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = "wealthfolio-data-encrypted"
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

# Plan-time read of the ESO-created K8s Secret for Grafana datasource password.
# First apply: -target=kubernetes_manifest.wealthfolio_sync_db_external_secret first.
data "kubernetes_secret" "wealthfolio_sync_db_creds" {
  metadata {
    name      = "wealthfolio-sync-db-creds"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }
  depends_on = [kubernetes_manifest.wealthfolio_sync_db_external_secret]
}

# Grafana datasource for wealthfolio_sync PostgreSQL DB.
# Lives in the monitoring namespace so the Grafana sidecar (grafana_datasource=1) picks it up.
resource "kubernetes_config_map" "grafana_wealth_datasource" {
  metadata {
    name      = "grafana-wealth-datasource"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "wealth-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "Wealth"
        type   = "postgres"
        access = "proxy"
        url    = "${var.postgresql_host}:5432"
        user   = "wealthfolio_sync"
        uid    = "wealth-pg"
        # Grafana 11.2+ Postgres plugin reads DB name from jsonData.database
        # (top-level `database` is silently ignored).
        jsonData = {
          database        = "wealthfolio_sync"
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
        }
        secureJsonData = {
          password = data.kubernetes_secret.wealthfolio_sync_db_creds.data["PGPASSWORD"]
        }
        editable = true
      }]
    })
  }
}

############################################################################
# Backup — sidecar approach
#
# Wealthfolio has no PG/MySQL support (Diesel ORM hard-wired to SQLite per
# upstream README). The data lives on an RWO PVC that's held 24/7 by the
# main WF pod, so a separate backup CronJob would hit a Multi-Attach error
# (confirmed 2026-04-18 test).
#
# Instead, the WF Deployment gets a backup sidecar:
# - Shares the data PVC read-only + the NFS backup target.
# - Runs busybox `crond` with a 04:30-daily entry.
# - Uses `sqlite3 .backup` (WAL-safe, no downtime) to snapshot into an
#   NFS dated folder + retains 30 days.
#
# See `resource "kubernetes_deployment" "wealthfolio"` above — the sidecar
# is wired in via the deployment's container/volume blocks.
############################################################################
