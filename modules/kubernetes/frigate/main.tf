variable "tls_secret_name" {}

resource "kubernetes_namespace" "frigate" {
  metadata {
    name = "frigate"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "frigate"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = "frigate"
    labels = {
      app = "frigate"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1 # Temporarily disabled due to high power consumption
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "frigate"
      }
    }
    template {
      metadata {
        labels = {
          app = "frigate"
        }
      }
      spec {
        node_selector = {
          "gpu" : true
        }
        container {
          image = "ghcr.io/blakeblackshear/frigate:stable"
          name  = "frigate"

          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
          env {
            name  = "FRIGATE_RTSP_PASSWORD"
            value = "password"
          }
          # resources {
          #   limits = {
          #     cpu    = "1000m"
          #     memory = "2Gi"
          #   }
          # }

          port {
            container_port = 5000
          }
          port {
            container_port = 8554
          }
          port {
            container_port = 8555
            protocol       = "TCP"
          }
          port {
            container_port = 8555
            protocol       = "UDP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          security_context {
            privileged = true
          }
        }

        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/frigate"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
        volume {
          name = "media"
          nfs {
            path   = "/mnt/main/frigate"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
            # type = "CharDevice"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "frigate" {
  metadata {
    name      = "frigate"
    namespace = "frigate"
    labels = {
      "app" = "frigate"
    }
  }

  spec {
    selector = {
      app = "frigate"
    }
    port {
      name        = "http"
      target_port = 5000
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "frigate"
  name            = "frigate"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "20000m"
    # Websockets
    "nginx.org/websocket-services" : "frigate"
    "nginx.ingress.kubernetes.io/proxy-set-header" : "Upgrade $http_upgrade"
    "nginx.ingress.kubernetes.io/proxy-set-header" : "Connection $connection_upgrade"
    "nginx.ingress.kubernetes.io/proxy-redirect-from" : "off"

    "nginx.ingress.kubernetes.io/limit-rps" : 50000
    "nginx.ingress.kubernetes.io/limit-rpm" : 1000000
    "nginx.ingress.kubernetes.io/limit-burst-multiplier" : 50000
    "nginx.ingress.kubernetes.io/limit-rate-after" : 100000
  }
}
