
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


# resource "kubernetes_deployment" "ebook2audiobook" {
#   metadata {
#     name      = "ebook2audiobook"
#     namespace = kubernetes_namespace.ebook2audiobook.metadata[0].name
#     labels = {
#       app = "ebook2audiobook"
#     }
#   }
#   spec {
#     replicas = 1
#     strategy {
#       type = "Recreate"
#     }

#     selector {
#       match_labels = {
#         app = "ebook2audiobook"
#       }
#     }

#     template {
#       metadata {
#         labels = {
#           app = "ebook2audiobook"
#         }
#       }

#       spec {
#         container {
#           name = "ebook2audiobook"
#           # image = "docker.io/athomasson2/ebook2audiobook:latest"
#           image = "docker.io/athomasson2/ebook2audiobook:v25.12.30-cu128"

#           working_dir = "/app"
#           # command     = ["python", "app.py", "--script_mode", "full_docker"]
#           # command = ["/bin/bash", "-c", <<-EOT
#           #   # echo "Uninstalling current pytorch"
#           #   # pip uninstall -y torch torchvision torchaudio coqui-tts pyannote.audio torchcodec || true
#           #   # echo "Installing cuda13 compatible pytorch"
#           #   # pip install --pre --extra-index-url https://download.pytorch.org/whl/nightly/cu130 torch torchvision torchaudio pyannote.audio torchcodec triton deepspeed coqui-tts-trainer
#           #   # #pip install torch==2.9.0 torchvision==0.24.0 torchaudio==2.9.0 --index-url https://download.pytorch.org/whl/cu130
#           #   # echo "Starting main container"
#           #   #python app.py --script_mode full_docker
#           #   sleep 3600
#           # EOT
#           # ]

#           tty   = true
#           stdin = true

#           port {
#             container_port = 7860
#           }

#           volume_mount {
#             mount_path = "/app"
#             name       = "data"
#           }

#           resources {
#             limits = {
#               "nvidia.com/gpu" = "1"
#             }
#           }
#           security_context {
#             privileged = true
#           }
#         }

#         volume {
#           name = "data"
#           nfs {
#             server = "10.0.10.15"
#             path   = "/mnt/main/ebook2audiobook"
#           }
#         }
#       }
#     }
#   }
# }


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
    replicas = 1
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
        container {
          image   = "viktorbarzin/audiblez:latest"
          name    = "audiblez"
          command = ["/usr/bin/sleep", "86400"]
          volume_mount {
            name       = "data"
            mount_path = "/mnt"
          }
          # security_context {
          #   privileged = true
          #   capabilities {
          #     add = ["SYS_ADMIN"]
          #   }
          # }
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

