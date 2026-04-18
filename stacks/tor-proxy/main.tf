variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "tor-proxy" {
  metadata {
    name = "tor-proxy"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "tor-proxy"
  tls_secret_name = var.tls_secret_name
}

# resource "kubernetes_config_map" "tor_config" {
#   metadata {
#     name      = "tor-config"
#     namespace = "tor-proxy"
#     annotations = {
#       "reloader.stakater.com/match" = "true"
#     }
#   }

#   data = {
#     "torrc" = file("${path.module}/.torrc")
#   }
# }

resource "kubernetes_deployment" "tor-proxy" {
  metadata {
    name      = "tor-proxy"
    namespace = "tor-proxy"
    labels = {
      app  = "tor-proxy"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "tor-proxy"
      }
    }
    template {
      metadata {
        labels = {
          app = "tor-proxy"
        }
      }
      spec {
        container {
          name  = "tor-proxy"
          image = "dperson/torproxy:latest"
          port {
            name           = "http"
            container_port = 8118
            protocol       = "TCP"
          }
          port {
            name           = "tor"
            container_port = 9050
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          #   volume_mount {
          #     name       = "tor-config"
          #     mount_path = "/etc/tor/torrc"
          #     sub_path   = "torrc"
          #   }
        }
        # volume {
        #   name = "tor-config"
        #   config_map {
        #     name = kubernetes_config_map.tor_config.metadata[0].name
        #   }
        # }
      }
    }
  }
}

resource "kubernetes_service" "tor-proxy" {
  metadata {
    name      = "tor-proxy"
    namespace = "tor-proxy"
    labels = {
      "app" = "tor-proxy"
    }
  }

  spec {
    selector = {
      app = "tor-proxy"
    }
    port {
      name = "http"
      port = 8118
    }
    port {
      name = "tor"
      port = 9050
    }
  }
}

# --- TorrServer ---

resource "kubernetes_persistent_volume_claim" "torrserver_data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "tor-proxy-torrserver-data-proxmox"
    namespace = kubernetes_namespace.tor-proxy.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "torrserver" {
  metadata {
    name      = "torrserver"
    namespace = kubernetes_namespace.tor-proxy.metadata[0].name
    labels = {
      app  = "torrserver"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "torrserver"
      }
    }
    template {
      metadata {
        labels = {
          app = "torrserver"
        }
      }
      spec {
        container {
          name  = "torrserver"
          image = "ghcr.io/yourok/torrserver:MatriX.141"
          port {
            name           = "http"
            container_port = 8090
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/echo"
              port = 8090
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/echo"
              port = 8090
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }
          volume_mount {
            name       = "torrserver-data"
            mount_path = "/opt/ts"
          }
        }
        volume {
          name = "torrserver-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.torrserver_data_proxmox.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "torrserver" {
  metadata {
    name      = "torrserver"
    namespace = kubernetes_namespace.tor-proxy.metadata[0].name
    labels = {
      "app" = "torrserver"
    }
  }

  spec {
    selector = {
      app = "torrserver"
    }
    port {
      name        = "http"
      port        = 8090
      target_port = 8090
    }
  }
}

# Expose BT peer port for better torrent connectivity
resource "kubernetes_service" "torrserver-bt" {
  metadata {
    name      = "torrserver-bt"
    namespace = kubernetes_namespace.tor-proxy.metadata[0].name
    labels = {
      app = "torrserver-bt"
    }
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "torrserver"
    }
    port {
      name        = "bt-tcp"
      port        = 5665
      target_port = 5665
      protocol    = "TCP"
    }
    port {
      name        = "bt-udp"
      port        = 5665
      target_port = 5665
      protocol    = "UDP"
    }
  }
}

module "torrserver_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.tor-proxy.metadata[0].name
  name            = "torrserver"
  tls_secret_name = var.tls_secret_name
  port            = "8090"
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "TorrServer"
    "gethomepage.dev/description"  = "Torrent streaming server"
    "gethomepage.dev/icon"         = "torrserver.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
