resource "helm_release" "caretta" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "caretta"

  repository = "https://helm.groundcover.com/"
  chart      = "caretta"
  version    = "0.0.16"

  values = [yamlencode({
    grafana = {
      enabled = false
    }
    victoria-metrics-single = {
      enabled = false
    }
    tolerations = [
      {
        key      = "node-role.kubernetes.io/control-plane"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      }
    ]
    resources = {
      requests = {
        cpu    = "10m"
        memory = "300Mi"
      }
      limits = {
        cpu    = "200m"
        memory = "512Mi"
      }
    }
  })]
}

resource "kubernetes_service" "caretta_metrics" {
  metadata {
    name      = "caretta-metrics"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "caretta"
    }
  }
  spec {
    selector = {
      app = "caretta"
    }
    port {
      name        = "metrics"
      port        = 7117
      target_port = 7117
      protocol    = "TCP"
    }
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
