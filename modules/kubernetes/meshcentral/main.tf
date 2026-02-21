variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "meshcentral" {
  metadata {
    name = "meshcentral"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    labels = {
      app  = "meshcentral"
      tier = var.tier
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$,latest"
        }
      }
      spec {

        container {
          image = "typhonragewind/meshcentral:latest"
          name  = "meshcentral"
          port {
            name           = "http"
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
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    labels = {
      "app" = "meshcentral"
    }
  }

  spec {
    selector = {
      app = "meshcentral"
    }
    port {
      name     = "http"
      port     = 443
      protocol = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  name            = "meshcentral"
  tls_secret_name = var.tls_secret_name
  port            = 443
}
