
variable "tls_secret_name" {}
variable "headscale_config" {}

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
    }

    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
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
      }
      spec {
        container {
          image   = "headscale/headscale:latest"
          name    = "headscale"
          command = ["headscale", "serve"]
          resources {
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
            requests = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
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
            # name = kubernetes_config_map.headscale-config.metadata[0].name
            name = "headscale-config"
            items {
              key  = "config.yaml"
              path = "config.yaml"
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
        container {
          image = "simcu/headscale-ui"
          name  = "headscale-ui"
          port {
            container_port = 80
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
      name     = "headscale-ui"
      port     = "80"
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
      "kubernetes.io/ingress.class" = "nginx"
      # "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      # "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["headscale-ui.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "headscale.viktorbarzin.me"
      http {
        path {
          path = "/manager"
          backend {
            service {
              name = "headscale"
              port {
                number = 80
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
  }
}