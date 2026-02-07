
variable "tls_secret_name" {}
variable "tier" { type = string }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.ebook2audiobook.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "ebook2audiobook" {
  metadata {
    name = "ebook2audiobook"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}


resource "kubernetes_deployment" "ebook2audiobook" {
  metadata {
    name      = "ebook2audiobook"
    namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
    labels = {
      app  = "ebook2audiobook"
      tier = var.tier
    }
  }
  spec {
    replicas = 0 # Disabled - using audiblez instead
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "ebook2audiobook"
      }
    }

    template {
      metadata {
        labels = {
          app = "ebook2audiobook"
        }
      }

      spec {
        node_selector = {
          "gpu" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "ebook2audiobook"
          image = "docker.io/athomasson2/ebook2audiobook:v25.12.30-cu128"

          tty   = true
          stdin = true

          port {
            container_port = 7860
          }

          # LD_LIBRARY_PATH needed for CUDA detection - libcudart.so is in non-standard location
          env {
            name  = "LD_LIBRARY_PATH"
            value = "/usr/local/lib/python3.12/site-packages/nvidia/cuda_runtime/lib:/usr/local/lib/python3.12/site-packages/nvidia/cudnn/lib"
          }

          volume_mount {
            mount_path = "/home/user"
            name       = "data"
          }

          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
        }

        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/ebook2audiobook"
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "ebook2audiobook" {
  metadata {
    name      = "ebook2audiobook"
    namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
    labels = {
      "app" = "ebook2audiobook"
    }
  }

  spec {
    selector = {
      app = "ebook2audiobook"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 7860
    }
  }
}

# resource "kubernetes_deployment" "piper" {
#   metadata {
#     name      = "piper"
#     namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
#     labels = {
#       app = "piper"
#     }
#   }
#   spec {
#     replicas = 1
#     strategy {
#       type = "Recreate"
#     }

#     selector {
#       match_labels = {
#         app = "piper"
#       }
#     }

#     template {
#       metadata {
#         labels = {
#           app = "piper"
#         }
#       }

#       spec {
#         container {
#           name = "piper"
#           # image = "lscr.io/linuxserver/piper:gpu"
#           # image = "piper-tts-wyoming:latest"
#           image = "viktorbarzin/piper"
#           # image = "nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04"

#           # working_dir = "/app"
#           command = ["sleep", "3600"]

#           volume_mount {
#             mount_path = "/config"
#             name       = "data"
#           }

#           resources {
#             limits = {
#               "nvidia.com/gpu" = "1"
#             }
#           }
#           # env {
#           #   name  = "PIPER_VOICE"
#           #   value = "en_US-lessac-medium"
#           # }

#           env {
#             name  = "VOICE_MODEL"
#             value = "en_US-lessac-medium"
#           }
#           env {
#             name  = "LOG_LEVEL"
#             value = "DEBUG"
#           }
#           port {
#             name           = "web"
#             container_port = 10200
#           }
#         }

#         volume {
#           name = "data"
#           nfs {
#             server = "10.0.10.15"
#             path   = "/mnt/main/piper"
#           }
#         }
#       }
#     }
#   }
# }

# resource "kubernetes_service" "piper" {
#   metadata {
#     name      = "piper"
#    namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
#     labels = {
#       "app" = "piper"
#     }
#   }

#   spec {
#     selector = {
#       app = "piper"
#     }
#     port {
#       name        = "http"
#       port        = 80
#       target_port = 10200
#     }
#   }
# }


module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ebook2audiobook.metadata[0].name
  name            = "ebook2audiobook"
  tls_secret_name = var.tls_secret_name
  protected       = true
}


resource "kubernetes_deployment" "audiblez" {
  metadata {
    name      = "audiblez"
    namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
    labels = {
      app  = "audiblez"
      tier = var.tier
    }
  }
  spec {
    replicas = 0 # Disabled - using audiblez-web instead
    selector {
      match_labels = {
        app = "audiblez"
      }
    }
    template {
      metadata {
        labels = {
          app = "audiblez"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          image   = "viktorbarzin/audiblez:latest"
          name    = "audiblez"
          command = ["/usr/bin/sleep", "infinity"]
          volume_mount {
            name       = "data"
            mount_path = "/mnt"
          }
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/audiblez"
          }
        }
      }
    }
  }
}


# Audiblez Web UI
resource "kubernetes_deployment" "audiblez-web" {
  metadata {
    name      = "audiblez-web"
    namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
    labels = {
      app  = "audiblez-web"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "audiblez-web"
      }
    }
    template {
      metadata {
        labels = {
          app = "audiblez-web"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          # Use digest to bypass local registry cache
          image             = "docker.io/viktorbarzin/audiblez-web@sha256:eb6d13e6372b931bcac45ca389c063dfadc7b3fc2a607127fc76c5627b13a34c"
          image_pull_policy = "Always"
          name              = "audiblez-web"

          port {
            container_port = 8000
          }

          volume_mount {
            name       = "data"
            mount_path = "/mnt"
          }

          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }

          # liveness_probe {
          #   http_get {
          #     path = "/health"
          #     port = 8000
          #   }
          #   initial_delay_seconds = 10
          #   period_seconds        = 30
          # }

          # readiness_probe {
          #   http_get {
          #     path = "/health"
          #     port = 8000
          #   }
          #   initial_delay_seconds = 5
          #   period_seconds        = 10
          # }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/audiblez"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "audiblez-web" {
  metadata {
    name      = "audiblez-web"
    namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
    labels = {
      "app" = "audiblez-web"
    }
  }

  spec {
    selector = {
      app = "audiblez-web"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "audiblez-web-ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ebook2audiobook.metadata[0].name
  name            = "audiblez-web"
  host            = "audiblez"
  tls_secret_name = var.tls_secret_name
  protected       = true
  max_body_size   = "500m" # Allow large EPUB uploads
}

