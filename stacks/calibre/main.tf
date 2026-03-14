variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "calibre" {
  metadata {
    name = "calibre"
    labels = {
      tier = local.tiers.edge
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.calibre.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_library" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "calibre-library"
  namespace  = kubernetes_namespace.calibre.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/calibre-web-automated/calibre-library"
}

module "nfs_config" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "calibre-config"
  namespace  = kubernetes_namespace.calibre.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/calibre-web-automated/config"
}

module "nfs_ingest" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "calibre-ingest"
  namespace  = kubernetes_namespace.calibre.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/calibre-web-automated/cwa-book-ingest"
}

module "nfs_stacks_config" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "calibre-stacks-config"
  namespace  = kubernetes_namespace.calibre.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/calibre-web-automated/stacks"
}

# resource "kubernetes_deployment" "calibre" {
#   metadata {
#     name      = "calibre"
#    namespace = kubernetes_namespace.calibre.metadata[0].name
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
#             server = var.nfs_server
#           }
#         }
#       }
#     }
#   }
# }

resource "kubernetes_deployment" "calibre-web-automated" {
  metadata {
    name      = "calibre-web-automated"
    namespace = kubernetes_namespace.calibre.metadata[0].name
    labels = {
      app  = "calibre-web-automated"
      tier = local.tiers.edge
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
          env {
            name  = "CALIBRE_PORT"
            value = "8083"
          }

          port {
            container_port = 8083
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
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
          persistent_volume_claim {
            claim_name = module.nfs_library.claim_name
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = module.nfs_config.claim_name
          }
        }
        volume {
          name = "ingest"
          persistent_volume_claim {
            claim_name = module.nfs_ingest.claim_name
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "calibre" {
  metadata {
    name      = "calibre"
    namespace = kubernetes_namespace.calibre.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.calibre.metadata[0].name
  name            = "calibre"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Book library"
    "gethomepage.dev/group"       = "Media & Entertainment"
    "gethomepage.dev/icon" : "calibre-web.png"
    "gethomepage.dev/name"            = "Calibre"
    "gethomepage.dev/widget.type"     = "calibreweb"
    "gethomepage.dev/widget.url"      = "http://calibre.calibre.svc.cluster.local"
    "gethomepage.dev/widget.username" = var.homepage_credentials["calibre-web"]["username"]
    "gethomepage.dev/widget.password" = var.homepage_credentials["calibre-web"]["password"]
    "gethomepage.dev/pod-selector"    = ""
    # gethomepage.dev/weight: 10 # optional
    # gethomepage.dev/instance: "public" # optional
  }
  rybbit_site_id                 = "17a5c7fbb077"
  custom_content_security_policy = "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://rybbit.viktorbarzin.me"
}

# Stacks - Anna's Archive Download Manager

resource "kubernetes_deployment" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = kubernetes_namespace.calibre.metadata[0].name
    labels = {
      app  = "annas-archive-stacks"
      tier = local.tiers.edge
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
          persistent_volume_claim {
            claim_name = module.nfs_stacks_config.claim_name
          }
        }
        volume {
          name = "ingest"
          persistent_volume_claim {
            claim_name = module.nfs_ingest.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = kubernetes_namespace.calibre.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.calibre.metadata[0].name
  name            = "stacks"
  service_name    = "annas-archive-stacks"
  tls_secret_name = var.tls_secret_name
  protected       = true
  rybbit_site_id  = "ce5f8aed6bbb"
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}
