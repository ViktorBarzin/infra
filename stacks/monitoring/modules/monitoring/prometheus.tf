

resource "kubernetes_persistent_volume_claim" "prometheus_server_pvc" {
  metadata {
    name      = "prometheus-data-proxmox"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "90%"
      "resize.topolvm.io/increase"      = "10%"
      "resize.topolvm.io/storage_limit" = "500Gi"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "200Gi"
      }
    }
  }
}

module "nfs_prometheus_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "monitoring-prometheus-backup-host"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/prometheus-backup"
}

resource "helm_release" "prometheus" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  # version    = "15.0.2"
  version = "25.8.2"

  timeout      = 900 # 15 min — Recreate strategy + iSCSI reattach is slow
  force_update = true # Required for StatefulSet volumeClaimTemplate changes (immutable field)

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url, tuya_api_key = var.tiny_tuya_service_secret, haos_api_token = var.haos_api_token })]
}
