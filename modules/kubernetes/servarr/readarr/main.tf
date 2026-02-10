variable "tls_secret_name" {}
variable "tier" { type = string }
resource "kubernetes_namespace" "readarr" {
  metadata {
    name = "readarr"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}


module "tls_secret" {
  source          = "../../setup_tls_secret"
  namespace       = "readarr"
  tls_secret_name = var.tls_secret_name
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
          nfs {
            path   = "/mnt/main/servarr/readarr"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "qbittorrent"
          nfs {
            path   = "/mnt/main/servarr/qbittorrent"
            server = "10.0.10.15"
          }
        }
      }
    }
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
  source          = "../../ingress_factory"
  namespace       = "readarr"
  name            = "readarr"
  port            = 8787
  tls_secret_name = var.tls_secret_name
  protected       = true
}
