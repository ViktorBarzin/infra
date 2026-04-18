variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }


resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "servarr-listenarr-data-proxmox"
    namespace = "servarr"
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

module "nfs_downloads_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-listenarr-downloads-host"
  namespace  = "servarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/downloads"
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
    strategy {
      type = "Recreate"
    }
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
              memory = "896Mi"
            }
            limits = {
              memory = "896Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_downloads_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  dns_type        = "proxied"
  namespace       = "servarr"
  name            = "listenarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Listenarr"
    "gethomepage.dev/description"  = "Podcast manager"
    "gethomepage.dev/icon"         = "mdi-podcast"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
