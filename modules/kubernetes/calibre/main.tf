variable "tls_secret_name" {}

resource "kubernetes_namespace" "calibre" {
  metadata {
    name = "calibre"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "calibre"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "calibre" {
  metadata {
    name      = "calibre"
    namespace = "calibre"
    labels = {
      app = "calibre"
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
        app = "calibre"
      }
    }
    template {
      metadata {
        labels = {
          app = "calibre"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/calibre-web:latest"
          name  = "calibre"
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "DOCKER_MODS"
            value = "linuxserver/mods:universal-calibre"
          }

          port {
            container_port = 8083
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "data"
            mount_path = "/books"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/calibre"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "calibre" {
  metadata {
    name      = "calibre"
    namespace = "calibre"
    labels = {
      "app" = "calibre"
    }
  }

  spec {
    selector = {
      app = "calibre"
    }
    port {
      name        = "http"
      target_port = 8083
      port        = 80
      protocol    = "TCP"
    }
  }
}
resource "kubernetes_ingress_v1" "calibre" {
  metadata {
    name      = "calibre"
    namespace = "calibre"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "5000m"
    }
  }

  spec {
    tls {
      hosts       = ["calibre.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "calibre.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "calibre"
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

