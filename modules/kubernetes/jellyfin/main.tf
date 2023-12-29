variable "tls_secret_name" {}

resource "kubernetes_namespace" "jellyfin" {
  metadata {
    name = "jellyfin"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "jellyfin"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = "jellyfin"
    labels = {
      app = "jellyfin"
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
        app = "jellyfin"
      }
    }
    template {
      metadata {
        labels = {
          app = "jellyfin"
        }
      }
      spec {
        container {
          image = "jellyfin/jellyfin"
          name  = "jellyfin"
          env {
            name  = "DOCKER_MODS"
            value = "linuxserver/mods:universal-jellyfin"
          }

          port {
            container_port = 8096
          }
          volume_mount {
            name       = "media"
            mount_path = "/media"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }
        }
        volume {
          name = "media"
          nfs {
            path   = "/mnt/main/jellyfin/media"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/jellyfin/config"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "cache"
          nfs {
            path   = "/mnt/main/jellyfin/cache"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = "jellyfin"
    labels = {
      "app" = "jellyfin"
    }
  }

  spec {
    selector = {
      app = "jellyfin"
    }
    port {
      name        = "http"
      target_port = 8096
      port        = 80
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = "jellyfin"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "5000m"
    }
  }

  spec {
    tls {
      hosts       = ["jellyfin.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "jellyfin.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "jellyfin"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

