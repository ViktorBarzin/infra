variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "tor-proxy" {
  metadata {
    name = "tor-proxy"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
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
      tier = var.tier
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
