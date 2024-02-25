variable "tls_secret_name" {}
resource "kubernetes_namespace" "prowlarr" {
  metadata {
    name = "prowlarr"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}


module "tls_secret" {
  source          = "../../setup_tls_secret"
  namespace       = "prowlarr"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = "prowlarr"
    labels = {
      app = "prowlarr"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "prowlarr"
      }
    }
    template {
      metadata {
        labels = {
          app = "prowlarr"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/prowlarr:latest"
          name  = "prowlarr"

          port {
            container_port = 9696
          }
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "TZ"
            value = "Etc/UTC"
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "data"
            mount_path = "/books"
          }
          volume_mount {
            name       = "data"
            mount_path = "/downloads"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/servarr/prowlarr"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = "prowlarr"
    labels = {
      app = "prowlarr"
    }
  }

  spec {
    selector = {
      app = "prowlarr"
    }
    port {
      name = "http"
      port = 9696
    }
  }
}

resource "kubernetes_ingress_v1" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = "prowlarr"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["prowlarr.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "prowlarr.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "prowlarr"
              port {
                number = 9696
              }
            }
          }
        }
      }
    }
  }
}
