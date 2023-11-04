variable "tls_secret_name" {}

resource "kubernetes_namespace" "send" {
  metadata {
    name = "send"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "send"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "dashy" {
  metadata {
    name      = "send"
    namespace = "send"
    labels = {
      app = "send"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "send"
      }
    }
    template {
      metadata {
        labels = {
          app = "send"
        }
      }
      spec {
        container {
          image = "registry.gitlab.com/timvisee/send:latest"
          name  = "send"

          port {
            container_port = 1443
          }
          env {
            name  = "FILE_DIR"
            value = "/uploads"
          }
          env {
            name  = "BASE_URL"
            value = "https://send.viktorbarzin.me"
          }
          env {
            name  = "MAX_FILE_SIZE"
            value = "5368709120"
          }
          env {
            name  = "MAX_DOWNLOADS"
            value = 10 # try to minimize abusive behaviour
          }
          env {
            name  = "MAX_EXPIRE_SECONDS"
            value = 7 * 24 * 3600
          }
          volume_mount {
            name       = "data"
            mount_path = "/uploads"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/send"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "send" {
  metadata {
    name      = "send"
    namespace = "send"
    labels = {
      app = "send"
    }
  }

  spec {
    selector = {
      app = "send"
    }
    port {
      name = "http"
      port = 1443
    }
  }
}
resource "kubernetes_ingress_v1" "send" {
  metadata {
    name      = "send"
    namespace = "send"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["send.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "send.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "send"
              port {
                number = 1443
              }
            }
          }
        }
      }
    }
  }
}
