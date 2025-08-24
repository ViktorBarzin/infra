
variable "tls_secret_name" {}
variable "headscale_config" {}
variable "headscale_acl" {}

resource "kubernetes_namespace" "headscale" {
  metadata {
    name = "headscale"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "headscale"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "headscale" {
  metadata {
    name      = "headscale"
    namespace = "headscale"
    labels = {
      app = "headscale"
      # scare to try but probably non-http will fail
      # "istio-injection" : "enabled"
    }

    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "headscale"
      }
    }
    template {
      metadata {
        labels = {
          app = "headscale"
        }
        annotations = {
          # "diun.enable"       = "true"
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
      }
      spec {
        container {
          image = "headscale/headscale:0.23.0"
          # image   = "headscale/headscale:0.23.0-debug" # -debug is for debug images
          name    = "headscale"
          command = ["headscale", "serve"]
          port {
            container_port = 8080
          }
          port {
            container_port = 9090
          }
          port {
            container_port = 41641
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/headscale"
          }

          volume_mount {
            mount_path = "/mnt"
            name       = "nfs-config"
          }
        }
        volume {
          name = "config-volume"
          config_map {
            name = "headscale-config"
            items {
              key  = "config.yaml"
              path = "config.yaml"
            }
            items {
              key  = "acl.yaml"
              path = "acl.yaml"
            }
          }
        }

        volume {
          name = "nfs-config"
          nfs {
            path   = "/mnt/main/headscale"
            server = "10.0.10.15"
          }
        }
        # container {
        #   image = "simcu/headscale-ui:0.1.4"
        #   name  = "headscale-ui"
        #   port {
        #     container_port = 80
        #   }
        # }
        container {
          image = "ghcr.io/gurucomputing/headscale-ui:latest"
          # image = "ghcr.io/tale/headplane:0.3.2"
          name = "headscale-ui"
          port {
            container_port = 8081
            # container_port = 3000
          }
          env {
            name  = "HTTP_PORT"
            value = "8081"
          }
          # env {
          #   name  = "HTTPS_PORT"
          #   value = "8082"
          # }
          env {
            name  = "HEADSCALE_URL"
            value = "http://localhost:8080"
          }
          env {
            name  = "COOKIE_SECRET"
            value = "kekekekke"
          }
          env {
            name  = "ROOT_API_KEY"
            value = "kekekekeke"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "headscale" {
  metadata {
    name      = "headscale"
    namespace = "headscale"
    labels = {
      "app" = "headscale"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9090"
    }
    # annotations = {
    #   "metallb.universe.tf/allow-shared-ip" : "shared"
    # }
  }

  spec {
    # type                    = "LoadBalancer"
    # external_traffic_policy = "Cluster"
    selector = {
      app = "headscale"

    }
    port {
      name     = "headscale"
      port     = "8080"
      protocol = "TCP"
    }
    port {
      name        = "headscale-ui"
      port        = "80"
      target_port = 8081
      # target_port = 3000
      protocol = "TCP"
    }
    port {
      name     = "metrics"
      port     = "9090"
      protocol = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "headscale" {
  metadata {
    name      = "headscale-ingress"
    namespace = "headscale"
    annotations = {
      // DO NOT ADD CLIENT TLS AUTH as this breaks vpn auth
      "kubernetes.io/ingress.class"              = "nginx"
      "nginx.ingress.kubernetes.io/ssl-redirect" = false # Disable SSL redirection for this Ingress
      "nginx.org/websocket-services"             = "headscale"

    }
  }

  spec {
    tls {
      hosts       = ["headscale.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "headscale.viktorbarzin.me"
      http {
        path {
          path = "/web"
          # path = "/admin"
          backend {
            service {
              name = "headscale"
              port {
                number = 8081
              }
            }
          }
        }
        path {
          path = "/"
          backend {
            service {
              name = "headscale"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "headscale-server" {
  metadata {
    name      = "headscale-server"
    namespace = "headscale"
    labels = {
      "app" = "headscale"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" : "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "headscale"

    }
    # port {
    #   name     = "headscale-tcp"
    #   port     = "41641"
    #   protocol = "TCP"
    # }
    port {
      name     = "headscale-udp"
      port     = "41641"
      protocol = "UDP"
    }
  }
}

resource "kubernetes_config_map" "headscale-config" {
  metadata {
    name      = "headscale-config"
    namespace = "headscale"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "config.yaml" = var.headscale_config
    "acl.yaml"    = var.headscale_acl
  }
}
