variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }


module "nfs_data" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-prowlarr-data"
  namespace  = "servarr"
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/servarr/prowlarr"
}

module "nfs_downloads" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-prowlarr-downloads"
  namespace  = "servarr"
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/servarr/downloads"
}

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
  source          = "../../../modules/kubernetes/ingress_factory"
  namespace       = "servarr"
  name            = "prowlarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
