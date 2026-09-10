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
# SCHEMA CONTRACT — the DASHBOARD needs the aggregator's widening migration
# (design step 2, `migrations/0002_widen_edge.sql` in the aggregator repo). The
# datasource works either way; the panels read the columns that migration adds.
# Table `public.edge` in database `goldmane_edges`, as the migration actually
# creates it (seven nullable columns plus the generated pre_widening flag):
#
#   src_ns         text NOT NULL   (from 0001)
#   dst_ns         text NOT NULL   (from 0001)
#   action         text NOT NULL   (from 0001) allow | deny | pass | unspecified
#   first_seen     timestamptz     (from 0001)
#   last_seen      timestamptz     (from 0001)
#   flow_count     bigint          (from 0001) cumulative, never a rate
#   src_workload   text NULL       the workload, i.e. the set of pods sharing a
#                                  generateName with the generated part removed
#                                  (edge.NormalizeWorkload); for a non-pod end
#                                  the node / network-set name, or 'pub'/'pvt'
#   src_type       text NULL       workload | host | networkset | network |
#                                  unknown — LOWERCASE. These are the
#                                  aggregator's own constants
#                                  (internal/edge/edge.go), not Goldmane's
#                                  EndpointType enum spelling, which is
#                                  WorkloadEndpoint / HostEndpoint / NetworkSet
#                                  / Network. Comparing against the enum
#                                  spelling matches nothing.
#   dst_workload   text NULL
#   dst_type       text NULL
#   dst_service    text NULL       the Service the flow was addressed to, '-'
#                                  when it did not go through one. '-' is the
#                                  unset sentinel throughout (edge.Unset), never
#                                  the empty string, so the panels blank it with
#                                  NULLIF(dst_service, '-').
#   dst_service_ns text NULL
#   dst_port       bigint NULL     0 means not recorded, which deliberately
#                                  covers every bare external destination — the
#                                  port there belongs to the remote peer and is
#                                  unbounded (see edge.portIsOurs)
#   pre_widening   boolean         GENERATED ALWAYS AS (src_type IS NULL) STORED
#
# PRE-WIDENING ROWS. The seven added columns are nullable with no default, so
# rows written before the migration read NULL rather than a sentinel — a
# sentinel would be indistinguishable from a real observation ('-' is a real
# unset service, 'unknown' a real endpoint type, 0 a real unrecorded port).
# Nothing is deleted. They cannot be plotted on these axes, so the migration's
# stated dashboard contract is to filter on `NOT pre_widening`, and all 17 SQL
# statements in dashboards/east-west-traffic.json do.
#
# The scale of what that predicate excludes, read off the live table on
# 2026-09-01: ALL 710 rows currently in it are pre-widening, and they carry
# 389,663,018 accumulated flows going back to 2026-06-24. The moment the
# migration lands, every panel here is therefore empty, and it fills as the
# aggregator re-observes each edge under the wider identity. An unfiltered total
# would be dominated by those rows indefinitely, because a wider identity means
# they are never updated again.
#
# `homelab edges` does not filter them and does not aggregate — its query is a
# bare SELECT of the namespace-pair columns — so after the migration it lists a
# legacy row alongside each widened row for the same pair. Reading pre-widening
# history there means asking for it explicitly (`WHERE src_type IS NULL`).
#
# The aggregator owns that DDL; this comment is the dashboard's side of the
# contract. If the column names ever move again, the fix is confined to
# dashboards/east-west-traffic.json — nothing else here depends on them.
#
# Two columns on Goldmane's wire the dashboard does NOT use, so it cannot break
# on them: FlowKey.Proto, which we do not store at all, and dst_service_ns,
# which is near-always equal to dst_ns. Proto's absence is a real gap — without
# it a port cannot distinguish TCP/53 from UDP/53, and the panels say so rather
# than implying a protocol we do not store.
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
