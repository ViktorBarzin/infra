variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "readarr" {
  metadata {
    name = "readarr"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}


module "tls_secret" {
  source          = "../../../modules/kubernetes/setup_tls_secret"
  namespace       = "readarr"
  tls_secret_name = var.tls_secret_name
}

module "nfs_data_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "readarr-data-host"
  namespace  = "readarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/readarr"
}

module "nfs_qbittorrent_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "readarr-qbittorrent-host"
  namespace  = "readarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/qbittorrent"
}

resource "kubernetes_deployment" "readarr" {
  metadata {
    name      = "readarr"
    namespace = "readarr"
    labels = {
      app  = "readarr"
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
        app = "readarr"
      }
    }
    template {
      metadata {
        labels = {
          app = "readarr"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/readarr:develop"
          name  = "readarr"

          port {
            container_port = 8787
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
          volume_mount {
            name       = "qbittorrent"
            mount_path = "/mnt"
            read_only  = true
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
        volume {
          name = "qbittorrent"
          persistent_volume_claim {
            claim_name = module.nfs_qbittorrent_host.claim_name
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

resource "kubernetes_service" "readarr" {
  metadata {
    name      = "readarr"
    namespace = "readarr"
    labels = {
      app = "readarr"
    }
  }

  spec {
    selector = {
      app = "readarr"
    }
    port {
      name = "http"
      port = 8787
    }
  }
}

module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  namespace       = "readarr"
  name            = "readarr"
  port            = 8787
  tls_secret_name = var.tls_secret_name
  protected       = true
}
