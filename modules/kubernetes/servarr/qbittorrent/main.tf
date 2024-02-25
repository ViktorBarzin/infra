variable "tls_secret_name" {}
resource "kubernetes_namespace" "qbittorrent" {
  metadata {
    name = "qbittorrent"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}


module "tls_secret" {
  source          = "../../setup_tls_secret"
  namespace       = "qbittorrent"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "qbittorrent"
    labels = {
      app = "qbittorrent"
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
            name       = "data"
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
      }
    }
  }
}

resource "kubernetes_service" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "qbittorrent"
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
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_service" "qbittorrent-torrenting" {
  metadata {
    name      = "qbittorrent-torrenting"
    namespace = "qbittorrent"
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

resource "kubernetes_ingress_v1" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "qbittorrent"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "100000m" // allow uploading .torrent files
    }
  }

  spec {
    tls {
      hosts       = ["qbittorrent.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "qbittorrent.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "qbittorrent"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}
