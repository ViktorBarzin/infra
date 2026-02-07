variable "tls_secret_name" {}
variable "tier" { type = string }


resource "kubernetes_deployment" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "servarr"
    labels = {
      app  = "qbittorrent"
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
        app = "qbittorrent"
      }
    }
    template {
      metadata {
        labels = {
          app = "qbittorrent"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/qbittorrent:latest"
          name  = "qbittorrent"

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
            name  = "WEBUI_PORT"
            value = 8080
          }
          env {
            name  = "TORRENTING_PORT"
            value = 6881
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/servarr/qbittorrent"
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

resource "kubernetes_service" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "servarr"
    labels = {
      app = "qbittorrent"
    }
  }

  spec {
    selector = {
      app = "qbittorrent"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubernetes_service" "qbittorrent-torrenting" {
  metadata {
    name      = "qbittorrent-torrenting"
    namespace = "servarr"
    labels = {
      app = "qbittorrent-torrenting"

    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "qbittorrent"
    }
    port {
      name        = "torrenting"
      port        = 6881
      target_port = 6881
    }
    port {
      name        = "torrenting-udp"
      port        = 6881
      protocol    = "UDP"
      target_port = 6881
    }
  }
}


module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "servarr"
  name            = "qbittorrent"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
