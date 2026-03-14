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
        memory = "768Mi"
      }
      limits = {
        memory = "768Mi"
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

# Caretta dashboard is now loaded via the grafana_dashboards for_each in grafana.tf
