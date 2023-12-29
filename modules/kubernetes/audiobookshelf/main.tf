
variable "tls_secret_name" {}

resource "kubernetes_namespace" "audiobookshelf" {
  metadata {
    name = "audiobookshelf"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "audiobookshelf"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = "audiobookshelf"
    labels = {
      app = "audiobookshelf"
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
        app = "audiobookshelf"
      }
    }
    template {
      metadata {
        labels = {
          app = "audiobookshelf"
        }
      }
      spec {
        container {
          image = "ghcr.io/advplyr/audiobookshelf:latest"
          name  = "audiobookshelf"

          port {
            container_port = 80
          }
          volume_mount {
            name       = "audiobooks"
            mount_path = "/audiobooks"
          }
          volume_mount {
            name       = "podcasts"
            mount_path = "/podcasts"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "metadata"
            mount_path = "/metadata"
          }
        }
        volume {
          name = "audiobooks"
          nfs {
            path   = "/mnt/main/audiobookshelf/audiobooks"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "podcasts"
          nfs {
            path   = "/mnt/main/audiobookshelf/podcasts"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/audiobookshelf/config"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "metadata"
          nfs {
            path   = "/mnt/main/audiobookshelf/metadata"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = "audiobookshelf"
    labels = {
      "app" = "audiobookshelf"
    }
  }

  spec {
    selector = {
      app = "audiobookshelf"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = "audiobookshelf"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "5000m"
    }
  }

  spec {
    tls {
      hosts       = ["audiobookshelf.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "audiobookshelf.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "audiobookshelf"
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

