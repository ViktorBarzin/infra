

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
#         server = var.nfs_server
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
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = "alertmanager-pv"
        volume_attributes = {
          server = var.nfs_server
          share  = "/mnt/main/alertmanager"
        }
      }
    }
    mount_options = [
      "soft",
      "timeo=30",
      "retrans=3",
      "actimeo=5",
    ]
    storage_class_name = "nfs-truenas"
  }
}
# resource "kubernetes_persistent_volume_claim" "grafana_pvc" {
#   metadata {
#     name      = "grafana-pvc"
#    namespace = kubernetes_namespace.monitoring.metadata[0].name
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

resource "kubernetes_config_map" "grafana_dashboards" {
  for_each = fileset("${path.module}/dashboards", "*.json")

  metadata {
    name      = "grafana-dashboard-${replace(trimsuffix(each.value, ".json"), "_", "-")}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }
  data = {
    (each.value) = file("${path.module}/dashboards/${each.value}")
  }
}

resource "helm_release" "grafana" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "grafana"
  atomic           = true
  timeout          = 600

  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"

  values = [templatefile("${path.module}/grafana_chart_values.yaml", { db_password = var.grafana_db_password, grafana_admin_password = var.grafana_admin_password, mysql_host = var.mysql_host })]
}
