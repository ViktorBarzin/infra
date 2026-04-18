variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }


module "nfs_data_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-lidarr-data-host"
  namespace  = "servarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/lidarr"
}

module "nfs_downloads_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-lidarr-downloads-host"
  namespace  = "servarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/downloads"
}

resource "kubernetes_deployment" "lidarr" {
  metadata {
    name      = "lidarr"
    namespace = "servarr"
    labels = {
      app  = "lidarr"
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
        app = "lidarr"
      }
    }
    template {
      metadata {
        labels = {
          app = "lidarr"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/lidarr:2.9.4"
          # image = "youegraillot/lidarr-on-steroids"
          name = "lidarr"


          port {
            name           = "lidarr"
            container_port = 8686
          }
          port {
            name           = "deemix"
            container_port = 6595
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
            name       = "downloads"
            mount_path = "/downloads"
          }
          volume_mount {
            name       = "data"
            mount_path = "/music"
            sub_path   = "music"
          }
          volume_mount {
            name       = "deemix-config"
            mount_path = "/config_deemix"
            sub_path   = "deemix"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_downloads_host.claim_name
          }
        }
        volume {
          name = "deemix-config"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
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

resource "kubernetes_service" "lidarr" {
  metadata {
    name      = "lidarr"
    namespace = "servarr"
    labels = {
      app = "lidarr"
    }
  }

  spec {
    selector = {
      app = "lidarr"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8686
    }
  }
}

resource "kubernetes_service" "deemix" {
  metadata {
    name      = "deemix"
    namespace = "servarr"
    labels = {
      app = "deemix"
    }
  }

  spec {
    selector = {
      app = "lidarr"
    }
    port {
      name        = "deemix"
      port        = 80
      target_port = 6595
    }
  }
}


module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "servarr"
  name            = "lidarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
  #   extra_annotations = {
  #     "nginx.ingress.kubernetes.io/proxy-body-size" : "1G" // allow uploading .torrent files
  #   }

}

module "ingress-deemix" {
  source          = "../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "servarr"
  name            = "deemix"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
