

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
          server = "192.168.1.127"
          share  = "/srv/nfs/alertmanager"
        }
      }
    }
    mount_options = [
      "soft",
      "timeo=30",
      "retrans=3",
      "actimeo=5",
    ]
    storage_class_name               = "nfs-truenas"
    persistent_volume_reclaim_policy = "Retain"
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

# DB credentials from Vault database engine (rotated automatically)
# Provides GF_DATABASE_PASSWORD that auto-updates when password rotates
resource "kubernetes_manifest" "grafana_db_creds" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-db-creds"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grafana-db-creds"
        template = {
          data = {
            GF_DATABASE_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/mysql-grafana"
          property = "password"
        }
      }]
    }
  }
}

locals {
  # Dashboard folder assignments
  dashboard_folders = {
    # Cluster & Kubernetes
    "api_server.json"         = "Cluster"
    "cluster_health.json"     = "Cluster"
    "nodes.json"              = "Cluster"
    "pods.json"               = "Cluster"
    "kube-state-metrics.json" = "Cluster"
    # Networking & DNS
    "core_dns.json"        = "Networking"
    "technitium-dns.json"  = "Networking"
    "nginx_ingress.json"   = "Networking"
    "network_traffic.json" = "Networking"

    # Hardware & Host
    "node_exporter_full.json"    = "Hardware"
    "proxmox_node_exporter.json" = "Hardware"
    "idrac.json"                 = "Hardware"
    "ups.json"                   = "Hardware"
    "nvidia.json"                = "Hardware"

    # Operations
    "backup_health.json" = "Operations"
    "registry.json"      = "Operations"
    "loki.json"          = "Operations"
    "k8s-audit.json"     = "Operations"

    # Applications
    "qbittorrent.json"        = "Applications"
    "realestate-crawler.json" = "Applications"
    "uk-payslip.json"         = "Finance"
    "job-hunter.json"         = "Finance"
    "wealth.json"             = "Finance"
    "fire-planner.json"       = "Finance"
  }
}

resource "kubernetes_config_map" "grafana_dashboards" {
  for_each = fileset("${path.module}/dashboards", "*.json")

  metadata {
    name      = "grafana-dashboard-${replace(trimsuffix(each.value, ".json"), "_", "-")}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = lookup(local.dashboard_folders, each.value, "General")
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

  values     = [templatefile("${path.module}/grafana_chart_values.yaml", { grafana_admin_password = var.grafana_admin_password, mysql_host = var.mysql_host })]
  depends_on = [kubernetes_manifest.grafana_db_creds]
}
