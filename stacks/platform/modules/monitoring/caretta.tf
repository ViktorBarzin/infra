resource "helm_release" "caretta" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "caretta"

  repository = "https://helm.groundcover.com/"
  chart      = "caretta"
  version    = "0.0.16"

  set {
    name  = "grafana.enabled"
    value = "false"
  }

  set {
    name  = "victoria-metrics-single.enabled"
    value = "false"
  }
}

resource "kubernetes_config_map" "caretta_grafana_dashboard" {
  metadata {
    name      = "caretta-grafana-dashboard"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }
  data = {
    "caretta-dashboard.json" = file("${path.module}/dashboards/caretta-dashboard.json")
  }
}
