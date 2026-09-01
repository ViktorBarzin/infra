# =============================================================================
# Grafana Postgres datasource for the Goldmane edge trail (design step 3)
# =============================================================================
# Points Grafana at the `goldmane_edges` CNPG database that
# goldmane-edge-aggregator writes (ADR-0014, stacks/goldmane-edge-aggregator).
# The dashboard on top of it is dashboards/east-west-traffic.json, folder
# "Networking".
#
# CREDENTIAL: the same Vault-rotated static role the aggregator itself uses
# (`static-creds/pg-goldmane-edges`, declared in stacks/vault/main.tf, rotated
# every 7 days), projected into `monitoring` by the ExternalSecret below. That is
# the pattern the other four Postgres datasources here follow — job-hunter,
# fire-planner, wealthfolio, payslip-ingest — each mirroring its app's own
# rotating role into this namespace. Consequence worth stating: Grafana connects
# as the DB owner, so it could in principle write. A separate SELECT-only role
# would need a new Vault static role plus grants, which is a change to
# stacks/vault; left as a hardening follow-up rather than diverging from the
# established pattern here.
#
# SCHEMA CONTRACT — this datasource is useful, but the DASHBOARD is not, until
# the aggregator's widening migration (design step 2) has run. Every panel query
# reads columns that do not exist yet. The dashboard expects table `public.edge`
# in database `goldmane_edges` to carry:
#
#   src_ns       text         (exists today)
#   src_name     text         FlowKey.SourceName      — the workload, i.e. the
#                                                       set of pods sharing a
#                                                       generateName; for a
#                                                       non-pod end it is the
#                                                       host endpoint / network
#                                                       set name, or 'pub'/'pvt'
#   src_type     text         FlowKey.SourceType      — WorkloadEndpoint |
#                                                       HostEndpoint |
#                                                       NetworkSet | Network
#   dst_ns       text         (exists today)
#   dst_name     text         FlowKey.DestName
#   dst_type     text         FlowKey.DestType
#   dst_port     integer      FlowKey.DestPort
#   dst_svc_name text         FlowKey.DestServiceName ('' when absent)
#   action       text         (exists today)
#   first_seen   timestamptz  (exists today)
#   last_seen    timestamptz  (exists today)
#   flow_count   bigint       (exists today)
#
# The aggregator owns that DDL; this comment is the dashboard's side of the
# contract. If step 2 lands different names, the fix is a rename inside the one
# file dashboards/east-west-traffic.json — nothing else here depends on them.
#
# Two columns the dashboard deliberately does NOT use, so it cannot break on
# them: FlowKey.DestServiceNamespace (near-always equal to dst_ns) and
# FlowKey.Proto. Proto's absence is a real gap, not an oversight — without it a
# port cannot distinguish TCP/53 from UDP/53, and the panels say so rather than
# implying a protocol we do not store.
# -----------------------------------------------------------------------------

# ExternalSecret mirroring the rotating goldmane_edges DB password into
# `monitoring`. Grafana picks it up via envFromSecrets in
# grafana_chart_values.yaml; the datasource ConfigMap below reads it as
# $__env{GOLDMANE_EDGES_PG_PASSWORD}. The reloader.stakater.com/match
# annotation plus Grafana's own reloader.stakater.com/auto podAnnotation restart
# Grafana whenever ESO refreshes this secret, so the substituted value stays
# current across the 7-day rotation.
resource "kubernetes_manifest" "grafana_goldmane_edges_db_external_secret" {
  # external-secrets takes server-side-apply ownership of .spec.refreshInterval;
  # force_conflicts lets TF win (values match, so it is stable) — same as
  # grafana_db_creds in grafana.tf.
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-goldmane-edges-pg-creds"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grafana-goldmane-edges-pg-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            GOLDMANE_EDGES_PG_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-goldmane-edges"
          property = "password"
        }
      }]
    }
  }
}

# The datasource itself. Label grafana_datasource=1 is what the Grafana sidecar
# watches; it only reads the release namespace, which is this one.
resource "kubernetes_config_map" "grafana_goldmane_edges_datasource" {
  metadata {
    name      = "grafana-goldmane-edges-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "goldmane-edges-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "Goldmane Edges"
        type   = "postgres"
        access = "proxy"
        url    = "${var.postgresql_host}:5432"
        user   = "goldmane_edges"
        uid    = "goldmane-edges-pg"
        # Grafana 11.2+ reads the database name from jsonData.database; the
        # top-level `database` field is silently ignored by the frontend.
        jsonData = {
          database        = "goldmane_edges"
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
        }
        secureJsonData = {
          password = "$__env{GOLDMANE_EDGES_PG_PASSWORD}"
        }
        editable = true
      }]
    })
  }
  depends_on = [kubernetes_manifest.grafana_goldmane_edges_db_external_secret]
}
