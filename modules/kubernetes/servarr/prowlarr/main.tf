variable "tls_secret_name" {}
variable "tier" { type = string }


resource "kubernetes_deployment" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = "servarr"
    labels = {
      app  = "prowlarr"
      tier = var.tier
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
            name       = "downloads"
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
        volume {
          name = "downloads"
          nfs {
            path   = "/mnt/main/servarr/downloads"
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
    namespace = "servarr"
    labels = {
      app = "prowlarr"
    }
  }

  spec {
    selector = {
      app = "prowlarr"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 9696
    }
  }
}


module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "servarr"
  name            = "prowlarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
