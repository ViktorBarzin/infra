variable "tls_secret_name" {}

resource "kubernetes_namespace" "navidrome" {
  metadata {
    name = "navidrome"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "navidrome"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "navidrome" {
  metadata {
    name      = "navidrome"
    namespace = "navidrome"
    labels = {
      app                             = "navidrome"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "navidrome"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "navidrome"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          name  = "navidrome"
          image = "deluan/navidrome:latest"
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "music"
            mount_path = "/music"
            read_only  = true
          }
          volume_mount {
            name       = "lidarr"
            mount_path = "/lidarr"
            read_only  = true
          }
          port {
            name           = "http"
            container_port = 4533
            protocol       = "TCP"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/navidrome"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "music"
          nfs {
            path   = "/volume1/music"
            server = "192.168.1.13"
          }
        }
        volume {
          name = "lidarr"
          nfs {
            path   = "/mnt/main/servarr/lidarr"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "navidrome" {
  metadata {
    name      = "navidrome"
    namespace = "navidrome"
    labels = {
      "app" = "navidrome"
    }
  }

  spec {
    selector = {
      app = "navidrome"
    }
    port {
      port        = "80"
      target_port = "4533"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "navidrome"
  name            = "navidrome"
  tls_secret_name = var.tls_secret_name
}
