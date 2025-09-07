variable "tls_secret_name" {}


resource "kubernetes_deployment" "lidarr" {
  metadata {
    name      = "lidarr"
    namespace = "servarr"
    labels = {
      app = "lidarr"
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
      }
      spec {
        container {
          image = "lscr.io/linuxserver/lidarr:latest"
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
          nfs {
            path   = "/mnt/main/servarr/lidarr"
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
        volume {
          name = "deemix-config"
          nfs {
            path   = "/mnt/main/servarr/lidarr"
            server = "10.0.10.15"
          }
        }
      }
    }
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
  source          = "../../ingress_factory"
  namespace       = "servarr"
  name            = "lidarr"
  tls_secret_name = var.tls_secret_name
  protected       = true
  #   extra_annotations = {
  #     "nginx.ingress.kubernetes.io/proxy-body-size" : "1G" // allow uploading .torrent files
  #   }

}

module "ingress-deemix" {
  source          = "../../ingress_factory"
  namespace       = "servarr"
  name            = "deemix"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
