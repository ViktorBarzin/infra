# Grafana Tempo — trace store for the TripIt observability stack (tripit ADR-0032,
# infra plan docs/plans/2026-06-21-tripit-observability-tempo-otel.md). Phase 2:
# the app already trace-correlates its logs on Loki (Phase 1); this adds the trace
# UI + logs<->traces correlation. Additive to the monitoring stack — same
# helm-release pattern as loki.tf.
resource "helm_release" "tempo" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "tempo"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo" # single-binary (filesystem) — the Loki-scale, single-writer twin

  values  = [file("${path.module}/tempo.yaml")]
  timeout = 600
}

# Grafana Tempo datasource + trace->logs correlation (Tempo span -> its Loki logs
# by trace_id). The reverse (Loki log -> Tempo trace) is the derivedField added to
# the Loki datasource in loki.tf. Discovered by the Grafana sidecar via the
# grafana_datasource label, same as the Loki datasource.
resource "kubernetes_config_map" "grafana_tempo_datasource" {
  metadata {
    name      = "grafana-tempo-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "tempo-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Tempo"
        type      = "tempo"
        access    = "proxy"
        uid       = "tempo"
        url       = "http://tempo.monitoring.svc.cluster.local:3100"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.tempo]
}
