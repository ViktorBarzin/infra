# =============================================================================
# Grafana Postgres datasource for the wealth app (datasource uid wealth-app-pg)
# =============================================================================
# wealth (stacks/wealth, Forgejo viktor/wealth) keeps each household's ledger,
# Plans, FIRE results and Sweeps in the `wealth` database. Grafana reads one
# household through the views in schema `grafana` that a wealth migration
# makes; the household is the one row in `grafana.settings`. The views feed
# the FIRE panels of dashboards/wealth.json and the whole fire-planner.json
# and cost-of-living.json dashboards.
#
# CREDENTIAL: its own SELECT-only role `wealth_grafana` (stacks/dbaas,
# pg_wealth_grafana), not the app's owner role. It may read schema `grafana`
# only, every session is read-only, and statements stop after 30 s. Vault
# static role `static-creds/pg-wealth-grafana` (stacks/vault) rotates it on
# Tuesdays at 10:02 with Grafana's other sources. The ExternalSecret below
# mirrors it into `monitoring`; Grafana reads it through envFromSecrets in
# grafana_chart_values.yaml, and Reloader restarts Grafana when ESO updates
# the secret, so the $__env{} substitution never holds a rotated-out password.
# -----------------------------------------------------------------------------

resource "kubernetes_manifest" "grafana_wealth_app_db_external_secret" {
  # external-secrets takes server-side-apply ownership of .spec.refreshInterval;
  # force_conflicts lets TF win (values match, so it is stable).
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-wealth-app-pg-creds"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grafana-wealth-app-pg-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            WEALTH_APP_PG_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-wealth-grafana"
          property = "password"
        }
      }]
    }
  }
}

resource "kubernetes_config_map" "grafana_wealth_app_datasource" {
  metadata {
    name      = "grafana-wealth-app-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "wealth-app-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "Wealth app"
        type   = "postgres"
        access = "proxy"
        url    = "${var.postgresql_host}:5432"
        user   = "wealth_grafana"
        uid    = "wealth-app-pg"
        # Grafana 11.2+ reads the database name from jsonData.database; the
        # top-level `database` field is silently ignored by the frontend.
        # Three connections at most, under the role's limit of five.
        jsonData = {
          database        = "wealth"
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
          maxOpenConns    = 3
          maxIdleConns    = 1
        }
        secureJsonData = {
          password = "$__env{WEALTH_APP_PG_PASSWORD}"
        }
        editable = false
      }]
    })
  }
  depends_on = [kubernetes_manifest.grafana_wealth_app_db_external_secret]
}
