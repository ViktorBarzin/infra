

resource "kubernetes_persistent_volume_claim" "prometheus_server_pvc" {
  metadata {
    name      = "prometheus-data"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "iscsi-truenas"
    resources {
      requests = {
        storage = "200Gi"
      }
    }
  }
}

resource "helm_release" "prometheus" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  # version    = "15.0.2"
  version = "25.8.2"

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url, tuya_api_key = var.tiny_tuya_service_secret, haos_api_token = var.haos_api_token })]
}
