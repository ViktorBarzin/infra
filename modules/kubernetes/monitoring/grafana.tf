
# resource "kubernetes_persistent_volume" "prometheus_grafana_pv" {
#   metadata {
#     name = "grafana-pv"
#   }
#   spec {
#     capacity = {
#       "storage" = "2Gi"
#     }
#     access_modes = ["ReadWriteOnce"]
#     persistent_volume_source {
#       nfs {
#         path   = "/mnt/main/grafana"
#         server = "10.0.10.15"
#       }
#       # iscsi {
#       #   target_portal = "iscsi.viktorbarzin.lan:3260"
#       #   iqn           = "iqn.2020-12.lan.viktorbarzin:storage:monitoring:grafana"
#       #   lun           = 0
#       #   fs_type       = "ext4"
#       # }
#     }
#   }
# }

resource "kubernetes_persistent_volume" "alertmanager_pv" {
  metadata {
    name = "alertmanager-pv"
  }
  spec {
    capacity = {
      "storage" = "2Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/alertmanager"
        server = "10.0.10.15"
      }
    }
  }
}
# resource "kubernetes_persistent_volume_claim" "grafana_pvc" {
#   metadata {
#     name      = "grafana-pvc"
#     namespace = "monitoring"
#   }
#   spec {
#     access_modes = ["ReadWriteOnce"]
#     resources {
#       requests = {
#         "storage" = "2Gi"
#       }
#     }
#   }
# }

resource "helm_release" "grafana" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "grafana"
  atomic           = true

  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"

  values = [templatefile("${path.module}/grafana_chart_values.yaml", { db_password = var.grafana_db_password })]
}
