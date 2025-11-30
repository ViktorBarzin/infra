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

# resource "kubernetes_deployment" "calibre" {
#   metadata {
#     name      = "calibre"
#     namespace = "calibre"
#     labels = {
#       app = "calibre"
#     }
#     annotations = {
#       "reloader.stakater.com/search" = "true"
#     }
#   }
#   spec {
#     replicas = 1
#     strategy {
#       type = "Recreate"
#     }
#     selector {
#       match_labels = {
#         app = "calibre"
#       }
#     }
#     template {
#       metadata {
#         annotations = {
#           # "diun.enable"       = "true"
#           "diun.enable"       = "false"
#           "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
#         }
#         labels = {
#           app = "calibre"
#         }
#       }
#       spec {
#         container {
#           image = "lscr.io/linuxserver/calibre-web:latest"
#           name  = "calibre"
#           env {
#             name  = "PUID"
#             value = 1000
#           }
#           env {
#             name  = "PGID"
#             value = 1000
#           }
#           env {
#             name  = "DOCKER_MODS"
#             value = "linuxserver/mods:universal-calibre"
#           }

#           port {
#             container_port = 8083
#           }
#           volume_mount {
#             name       = "data"
#             mount_path = "/config"
#           }
#           volume_mount {
#             name       = "data"
#             mount_path = "/books"
#           }
#         }
#         volume {
#           name = "data"
#           nfs {
#             path   = "/mnt/main/calibre"
#             server = "10.0.10.15"
#           }
#         }
#       }
#     }
#   }
# }

resource "kubernetes_deployment" "calibre-web-automated" {
  metadata {
    name      = "calibre-web-automated"
    namespace = "calibre"
    labels = {
      app = "calibre-web-automated"
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
        app = "calibre-web-automated"
      }
    }
    template {
      metadata {
        annotations = {
          # "diun.enable"       = "true"
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
        labels = {
          app = "calibre-web-automated"
        }
      }
      spec {
        container {
          image = "crocodilestick/calibre-web-automated:latest"
          name  = "calibre-web-automated"
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
          env {
            # If your library is on a network share (e.g., NFS/SMB), disable WAL to reduce locking issues
            name  = "NETWORK_SHARE_MODE"
            value = "true"
          }

          port {
            container_port = 8083
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "library"
            mount_path = "/calibre-library"
          }
          volume_mount {
            name       = "ingest"
            mount_path = "/cwa-book-ingest"
          }
        }
        volume {
          name = "library"
          nfs {
            path   = "/mnt/main/calibre-web-automated/calibre-library"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/calibre-web-automated/config"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "ingest"
          nfs {
            path   = "/mnt/main/calibre-web-automated/cwa-book-ingest"
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
      # app = "calibre"
      app = "calibre-web-automated"
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

# Stacks - Anna's Archive Download Manager

resource "kubernetes_deployment" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = "calibre"
    labels = {
      app = "annas-archive-stacks"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "annas-archive-stacks"
      }
    }
    template {
      metadata {
        labels = {
          app = "annas-archive-stacks"
        }
      }
      spec {
        container {
          image = "zelest/stacks:latest"
          name  = "annas-archive-stacks"
          port {
            container_port = 7788
          }
          volume_mount {
            name       = "config"
            mount_path = "/opt/stacks/config"
          }
          volume_mount {
            name       = "ingest"
            mount_path = "/opt/stacks/download" # this must be the same as CWA ingest dir to auto ingest
          }
        }
        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/calibre-web-automated/stacks"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "ingest"
          nfs {
            path   = "/mnt/main/calibre-web-automated/cwa-book-ingest"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = "calibre"
    labels = {
      "app" = "annas-archive-stacks"
    }
  }

  spec {
    selector = {
      app = "annas-archive-stacks"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = 7788
    }
  }
}

module "stacks-ingress" {
  source          = "../ingress_factory"
  namespace       = "calibre"
  name            = "stacks"
  service_name    = "annas-archive-stacks"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
