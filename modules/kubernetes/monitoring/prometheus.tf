
resource "kubernetes_persistent_volume_claim" "prometheus_server_pvc" {
  metadata {
    name      = "prometheus-iscsi-pvc"
    namespace = "monitoring"
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "15Gi"
      }
    }
    # storage_class_name = "standard"
    volume_name = "prometheus-iscsi-pv"
  }
}

resource "kubernetes_persistent_volume" "prometheus_server_pvc" {
  metadata {
    name = "prometheus-iscsi-pv"
  }
  spec {
    capacity = {
      storage = "15Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/prometheus"
        server = "10.0.10.15"
      }
      # iscsi {
      #   fs_type       = "ext4"
      #   iqn           = "iqn.2020-12.lan.viktorbarzin:storage:monitoring:prometheus"
      #   lun           = 0
      #   target_portal = "iscsi.viktorbarzin.me:3260"
      # }

    }
    persistent_volume_reclaim_policy = "Retain"
    volume_mode                      = "Filesystem"
  }
}

resource "helm_release" "prometheus" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  # version    = "15.0.2"
  version = "25.8.2"

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url, tuya_api_key = var.tiny_tuya_service_secret, haos_api_token = var.haos_api_token })]
}
