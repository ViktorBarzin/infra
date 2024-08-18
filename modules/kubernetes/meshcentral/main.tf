variable "tls_secret_name" {}

resource "kubernetes_namespace" "meshcentral" {
  metadata {
    name = "meshcentral"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "meshcentral"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = "meshcentral"
    labels = {
      app = "meshcentral"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "meshcentral.enable"           = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "meshcentral"
      }
    }
    template {
      metadata {
        labels = {
          app = "meshcentral"
        }
      }
      spec {

        container {
          image = "typhonragewind/meshcentral:latest"
          name  = "meshcentral"
          port {
            name           = "https"
            container_port = 443
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "HOSTNAME"
            value = "meshcentral.viktorbarzin.me"
          }
          env {
            name  = "REVERSE_PROXY"
            value = "true"
          }
          env {
            name  = "ALLOW_NEW_ACCOUNTS"
            value = "true"
          }
          env {
            name  = "WEBRTC"
            value = "false"
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-data"
          }
          volume_mount {
            name       = "files"
            mount_path = "/opt/meshcentral/meshcentral-files"
          }
          volume_mount {
            name       = "backups"
            mount_path = "/opt/meshcentral/meshcentral-backups"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/meshcentral/meshcentral-data"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "files"
          nfs {
            path   = "/mnt/main/meshcentral/meshcentral-files"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "backups"
          nfs {
            path   = "/mnt/main/meshcentral/meshcentral-backups"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = "meshcentral"
    labels = {
      "app" = "meshcentral"
    }
  }

  spec {
    selector = {
      app = "meshcentral"
    }
    port {
      name     = "https"
      port     = "443"
      protocol = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = "meshcentral"
    annotations = {
      "kubernetes.io/ingress.class"          = "nginx"
      "nginx.ingress.kubernetes.io/affinity" = "cookie"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" : "600s",
      "nginx.ingress.kubernetes.io/proxy-send-timeout" : "600s",
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" : "600s"
      # "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }

  spec {
    tls {
      hosts       = ["meshcentral.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "meshcentral.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "meshcentral"
              port {
                number = 443
              }
            }
          }
        }
      }
    }
  }
}
