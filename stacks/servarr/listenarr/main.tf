variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }


resource "kubernetes_deployment" "listenarr" {
  metadata {
    name      = "listenarr"
    namespace = "servarr"
    labels = {
      app  = "listenarr"
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
        app = "listenarr"
      }
    }
    template {
      metadata {
        labels = {
          app = "listenarr"
        }
      }
      spec {
        container {
          image = "ghcr.io/therobbiedavis/listenarr:canary"
          name  = "listenarr"

          port {
            container_port = 5000
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/config"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/servarr/listenarr"
            server = var.nfs_server
          }
        }
        volume {
          name = "downloads"
          nfs {
            path   = "/mnt/main/servarr/downloads"
            server = var.nfs_server
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "listenarr" {
  metadata {
    name      = "listenarr"
    namespace = "servarr"
    labels = {
      app = "listenarr"
    }
  }

  spec {
    selector = {
      app = "listenarr"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5000
    }
  }
}


module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  namespace       = "servarr"
  name            = "listenarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
