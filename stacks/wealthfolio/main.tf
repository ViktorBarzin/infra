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
      "keel.sh/enrolled" = "true"
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

resource "kubernetes_deployment" "wealthfolio" {
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    ]
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
          CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY,
            symbol TEXT,
            name TEXT,
            currency TEXT,
            kind TEXT,
            exchange TEXT,
            is_active BOOLEAN
          );
          CREATE TABLE IF NOT EXISTS quote_latest (
            asset_id TEXT PRIMARY KEY,
            day DATE NOT NULL,
            close NUMERIC NOT NULL,
            currency TEXT
          );
          CREATE TABLE IF NOT EXISTS positions_latest (
            asset_id TEXT PRIMARY KEY,
            snapshot_date DATE NOT NULL,
            quantity NUMERIC NOT NULL,
            average_cost NUMERIC NOT NULL,
            total_cost_basis NUMERIC NOT NULL,
            currency TEXT
          );
          -- Drop-in replacement for daily_account_valuation that subtracts
          -- the cumulative pension gains-offset (DEPOSITs emitted by
          -- broker-sync Fidelity provider to reconcile WF totals with the
          -- PlanViewer reported pot). Wealthfolio's data model treats the
          -- offset as a cash contribution, so without this correction
          -- net_contribution is inflated by the gain and growth shows £0
          -- for the entire pension. The view re-exports the corrected
          -- value AS net_contribution so panels can use it as a drop-in
          -- replacement for the base table.
          CREATE OR REPLACE VIEW dav_corrected AS
          WITH all_offsets AS (
            SELECT account_id, activity_date::date AS effective_date, amount
            FROM activities
            WHERE notes LIKE 'fidelity-planviewer:unrealised-gains-offset%'
          )
          SELECT
            d.id, d.account_id, d.valuation_date, d.account_currency,
            d.base_currency, d.fx_rate_to_base, d.cash_balance,
            d.investment_market_value, d.total_value, d.cost_basis,
            d.net_contribution AS net_contribution_raw,
            (d.net_contribution - COALESCE(SUM(o.amount), 0)) AS net_contribution,
            COALESCE(SUM(o.amount), 0) AS pension_gains_offset
          FROM daily_account_valuation d
          LEFT JOIN all_offsets o
            ON o.account_id = d.account_id
            AND o.effective_date <= d.valuation_date
          GROUP BY d.id, d.account_id, d.valuation_date, d.account_currency,
            d.base_currency, d.fx_rate_to_base, d.cash_balance,
            d.investment_market_value, d.total_value, d.cost_basis,
            d.net_contribution;
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

          sqlite3 -separator $'\t' /tmp/wf-sync/snapshot.db <<'SQ' > /tmp/wf-sync/assets.tsv
          SELECT id,
                 COALESCE(display_code, instrument_symbol) AS symbol,
                 name,
                 quote_ccy AS currency,
                 kind,
                 COALESCE(instrument_exchange_mic, '') AS exchange,
                 is_active
          FROM assets;
          SQ

          # Latest quote per asset, preferring YAHOO over MANUAL when both exist on the same day.
          sqlite3 -separator $'\t' /tmp/wf-sync/snapshot.db <<'SQ' > /tmp/wf-sync/quote_latest.tsv
          SELECT asset_id, day, CAST(close AS REAL) AS close, currency
          FROM (
            SELECT asset_id, day, close, currency,
                   ROW_NUMBER() OVER (
                     PARTITION BY asset_id
                     ORDER BY day DESC, CASE source WHEN 'YAHOO' THEN 1 ELSE 2 END
                   ) AS rn
            FROM quotes
          )
          WHERE rn = 1;
          SQ

          # Currently-held positions only, from the TOTAL aggregate snapshot (sums lots across accounts).
          sqlite3 -separator $'\t' /tmp/wf-sync/snapshot.db <<'SQ' > /tmp/wf-sync/positions_latest.tsv
          SELECT je.key AS asset_id,
                 snapshot_date,
                 CAST(json_extract(je.value, '$.quantity') AS REAL) AS quantity,
                 CAST(json_extract(je.value, '$.averageCost') AS REAL) AS average_cost,
                 CAST(json_extract(je.value, '$.totalCostBasis') AS REAL) AS total_cost_basis,
                 json_extract(je.value, '$.currency') AS currency
          FROM holdings_snapshots, json_each(holdings_snapshots.positions) AS je
          WHERE account_id = 'TOTAL'
            AND snapshot_date = (SELECT MAX(snapshot_date) FROM holdings_snapshots WHERE account_id = 'TOTAL')
            AND CAST(json_extract(je.value, '$.quantity') AS REAL) > 0.0001;
          SQ

          # Truncate-and-reload (small tables; simpler than upserts).
          psql -v ON_ERROR_STOP=1 <<SQL
          BEGIN;
          TRUNCATE accounts, daily_account_valuation, activities, assets, quote_latest, positions_latest;
          \copy accounts FROM '/tmp/wf-sync/accounts.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy daily_account_valuation FROM '/tmp/wf-sync/dav.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy activities FROM '/tmp/wf-sync/activities.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy assets FROM '/tmp/wf-sync/assets.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy quote_latest FROM '/tmp/wf-sync/quote_latest.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
          \copy positions_latest FROM '/tmp/wf-sync/positions_latest.tsv' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
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
  auth            = "required"
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
              name = "sync"
              # Phase 4 of forgejo-registry-consolidation 2026-05-07 +
              # post-cutover wealthfolio-sync rebuild: image is now
              # produced by /home/wizard/code/broker-sync (Forgejo
              # viktor/broker-sync, DockerHub viktorbarzin/broker-sync,
              # Forgejo viktor/wealthfolio-sync as the cluster pull path).
              image = "forgejo.viktorbarzin.me/viktor/wealthfolio-sync:latest"
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

# ExternalSecret in the monitoring namespace mirroring the rotating
# wealthfolio_sync DB password. Grafana mounts this via envFromSecrets
# in monitoring/grafana_chart_values.yaml; the datasource ConfigMap
# below references it as $__env{WEALTH_PG_PASSWORD}. Reloader restarts
# Grafana whenever ESO updates this secret (every 7d on rotation).
resource "kubernetes_manifest" "grafana_wealth_db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-wealth-pg-creds"
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grafana-wealth-pg-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            WEALTH_PG_PASSWORD = "{{ .password }}"
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
}

# Grafana datasource for wealthfolio_sync PostgreSQL DB.
# Lives in the monitoring namespace so the Grafana sidecar (grafana_datasource=1) picks it up.
# Password is injected via $__env{...} from grafana-wealth-pg-creds (above).
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
          password = "$__env{WEALTH_PG_PASSWORD}"
        }
        editable = true
      }]
    })
  }
  depends_on = [kubernetes_manifest.grafana_wealth_db_external_secret]
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

############################################################################
# Daily portfolio-recalc CronJob — keeps the Grafana wealth dashboard fresh.
#
# Wealthfolio writes new `daily_account_valuation` rows ONLY when a
# PortfolioJob fires with ValuationRecalcMode != None. None of its built-in
# schedulers do that for our deployment:
#   * Internal 6h quote scheduler — refreshes the `quotes` table only.
#   * Internal 4h broker scheduler — short-circuits if `sync_refresh_token`
#     is unset (it is — we route broker imports through the external
#     wealthfolio-sync CronJob).
# Result: valuations only update when the Tauri/web UI hits
# /api/v1/market-data/sync — i.e. when someone opens the dashboard.
#
# This CronJob mimics that: login → POST /api/v1/market-data/sync. The
# server runs the portfolio job (Incremental quote sync + IncrementalFromLast
# valuation recalc), backfilling missing daily_account_valuation rows up to
# today. The pg-sync sidecar's :07 hourly tick mirrors them to PG, and
# Grafana auto-refreshes within 5 min.
#
# Schedule 16:00 UTC (= 17:00 BST in summer):
#   - After UK market close (15:30 UTC BST), so EOD UK prices are settled
#   - US market open ~2.5h (good intra-day US quotes)
#   - pg-sync next tick at 16:07 → Grafana fresh by ~16:12 UTC ≈ 17:12 BST,
#     well before the 18:00 BST "fresh data by 6pm" target.
#
# Plaintext password lives at Vault `secret/wealthfolio.web_password`,
# pulled into the existing `wealthfolio-secrets` K8s Secret by the
# `dataFrom.extract` ExternalSecret above (no extra ESO wiring needed —
# the new key flows through automatically).
############################################################################
resource "kubernetes_cron_job_v1" "wealthfolio_daily_sync" {
  metadata {
    name      = "wealthfolio-daily-sync"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }

  spec {
    schedule                      = "0 16 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"

    job_template {
      metadata {}
      spec {
        active_deadline_seconds = 180
        backoff_limit           = 1
        template {
          metadata {}
          spec {
            restart_policy = "Never"

            container {
              name  = "curl"
              image = "curlimages/curl:8.11.1"
              env {
                name = "WF_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "web_password"
                  }
                }
              }
              command = ["/bin/sh", "-c"]
              args = [
                <<-EOT
                set -eu
                BASE=http://wealthfolio.wealthfolio.svc.cluster.local
                JAR=$(mktemp)
                trap 'rm -f "$JAR"' EXIT

                echo "[$(date -u +%FT%TZ)] login"
                curl -sS --max-time 15 --fail -X POST "$BASE/api/v1/auth/login" \
                  -H "Content-Type: application/json" \
                  -d "{\"password\":\"$WF_PASSWORD\"}" \
                  -c "$JAR" -o /dev/null

                echo "[$(date -u +%FT%TZ)] POST /api/v1/market-data/sync"
                curl -sS --max-time 60 --fail -X POST "$BASE/api/v1/market-data/sync" \
                  -H "Content-Type: application/json" \
                  -b "$JAR" \
                  -d '{"refetchAll":false}' -o /dev/null
                echo "[$(date -u +%FT%TZ)] sync queued (204) — portfolio job runs async"
                EOT
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
