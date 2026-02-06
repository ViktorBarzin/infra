variable "tls_secret_name" {}
variable "tier" { type = string }

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
  namespace       = kubernetes_namespace.frigate.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
    labels = {
      app  = "frigate"
      tier = var.tier
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
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          # image = "ghcr.io/blakeblackshear/frigate:stable"
          # image = "ghcr.io/blakeblackshear/frigate:stable-tensorrt"
          image = "ghcr.io/blakeblackshear/frigate:0.17.0-beta1-tensorrt"
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
          volume_mount {
            name       = "media"
            mount_path = "/media/frigate"
          }
          security_context {
            privileged = true
          }
        }

        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/frigate/config"
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
            path   = "/mnt/main/frigate/media"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
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

resource "kubernetes_service" "frigate-rtsp" {
  metadata {
    name      = "frigate-rtsp"
    namespace = kubernetes_namespace.frigate.metadata[0].name
    labels = {
      "app" = "frigate"
    }
  }

  spec {
    type = "NodePort" # Should always live on node1 where the gpu is
    selector = {
      app = "frigate"
    }
    port {
      name        = "rtsp-tcp"
      target_port = 8554
      port        = 8554
      protocol    = "TCP"
      node_port   = 30554
    }
    port {
      name        = "rtsp-udp"
      target_port = 8554
      port        = 8554
      protocol    = "UDP"
      node_port   = 30554
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.frigate.metadata[0].name
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
  rybbit_site_id = "0d4044069ff5"
}

module "ingress-internal" {
  source                  = "../ingress_factory"
  namespace               = kubernetes_namespace.frigate.metadata[0].name
  name                    = "frigate-lan"
  host                    = "frigate-lan"
  root_domain             = "viktorbarzin.lan"
  service_name            = "frigate"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
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
