# OpenTelemetry Collector — the OTLP ingress + redaction backstop in front of
# Tempo (tripit ADR-0032). Apps export OTLP here; it redacts deny-listed values,
# buffers, and forwards to Tempo. Same helm-release pattern as loki.tf/tempo.tf.
resource "helm_release" "otel_collector" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "otel-collector"

  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"

  values  = [file("${path.module}/otel-collector.yaml")]
  timeout = 600

  depends_on = [helm_release.tempo]
}
