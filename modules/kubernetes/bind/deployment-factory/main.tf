variable "named_conf_mounts" {}
variable "deployment_name" {}

resource "kubernetes_deployment" "bind" {
  metadata {
    name      = var.deployment_name
    namespace = "bind"
    labels = {
      "app" = "bind"
      "kubernetes.io/cluster-service" : "true"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = "3"
    selector {
      match_labels = {
        "app" = var.deployment_name
      }
    }
    template {
      metadata {
        labels = {
          "app" = var.deployment_name
          "kubernetes.io/cluster-service" : "true"
        }
      }
      spec {
        container {
          name              = "bind"
          image             = "resystit/bind9:latest"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 53
            protocol       = "UDP"
          }
          volume_mount {
            mount_path = "/etc/bind/named.conf"
            sub_path   = "named.conf"
            name       = "bindconf"
          }

          dynamic "volume_mount" {
            for_each = [for m in var.named_conf_mounts :
              {
                name       = m.name
                mount_path = m.mount_path
                sub_path   = m.sub_path
            }]
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mount_path
              sub_path   = volume_mount.value.sub_path
            }
          }

          volume_mount {
            mount_path = "/etc/bind/db.viktorbarzin.me"
            sub_path   = "db.viktorbarzin.me"
            name       = "bindconf"
          }
          volume_mount {
            mount_path = "/etc/bind/db.viktorbarzin.lan"
            sub_path   = "db.viktorbarzin.lan"
            name       = "bindconf"
          }
          volume_mount {
            mount_path = "/etc/bind/db.181.191.213.in-addr.arpa"
            sub_path   = "db.181.191.213.in-addr.arpa"
            name       = "bindconf"
          }
        }
        container {
          name              = "bind-exporter"
          image             = "prometheuscommunity/bind-exporter:latest"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 9119
          }
        }

        volume {
          name = "bindconf"
          config_map {
            name = "bind-configmap"
          }
        }
      }
    }
  }
}
