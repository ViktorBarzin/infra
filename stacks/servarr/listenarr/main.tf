variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }


module "nfs_data" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-listenarr-data"
  namespace  = "servarr"
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/servarr/listenarr"
}

module "nfs_downloads" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-listenarr-downloads"
  namespace  = "servarr"
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/servarr/downloads"
}

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
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_downloads.claim_name
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
