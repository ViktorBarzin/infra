variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}


resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "servarr-prowlarr-data-proxmox"
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
  name       = "servarr-prowlarr-downloads-host"
  namespace  = "servarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/downloads"
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
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/prowlarr:2.3.5"
          name  = "prowlarr"

          resources {
            requests = {
              cpu    = "10m"
              memory = "192Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
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
  dns_type        = "proxied"
  namespace       = "servarr"
  name            = "prowlarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Prowlarr"
    "gethomepage.dev/description"  = "Indexer manager"
    "gethomepage.dev/icon"         = "prowlarr.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "prowlarr"
    "gethomepage.dev/widget.url"   = "http://prowlarr.servarr.svc.cluster.local"
    "gethomepage.dev/widget.key"   = var.homepage_credentials["prowlarr"]["api_key"]
  }
}
