variable "tls_secret_name" {}
variable "homepage_username" {
  default = ""
}
variable "homepage_password" {
  default = ""
}

resource "kubernetes_namespace" "calibre" {
  metadata {
    name = "calibre"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "calibre"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "calibre" {
  metadata {
    name      = "calibre"
    namespace = "calibre"
    labels = {
      app = "calibre"
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
        app = "calibre"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
        labels = {
          app = "calibre"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/calibre-web:0.6.24"
          name  = "calibre"
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "DOCKER_MODS"
            value = "linuxserver/mods:universal-calibre"
          }

          port {
            container_port = 8083
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "data"
            mount_path = "/books"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/calibre"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "calibre" {
  metadata {
    name      = "calibre"
    namespace = "calibre"
    labels = {
      "app" = "calibre"
    }
  }

  spec {
    selector = {
      app = "calibre"
    }
    port {
      name        = "http"
      target_port = 8083
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "calibre"
  name            = "calibre"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "5000m"

    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Book library"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "calibre-web.png"
    "gethomepage.dev/name"            = "Calibre"
    "gethomepage.dev/widget.type"     = "calibreweb"
    "gethomepage.dev/widget.url"      = "https://calibre.viktorbarzin.me"
    "gethomepage.dev/widget.username" = var.homepage_username
    "gethomepage.dev/widget.password" = var.homepage_password
    "gethomepage.dev/pod-selector"    = ""
    # gethomepage.dev/weight: 10 # optional
    # gethomepage.dev/instance: "public" # optional
  }
}
