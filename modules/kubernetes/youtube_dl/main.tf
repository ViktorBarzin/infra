variable "tls_secret_name" {}
variable "tier" { type = string }
variable "openrouter_api_key" { type = string }
variable "slack_bot_token" { type = string }
variable "slack_channel" { type = string }

resource "kubernetes_namespace" "ytdlp" {
  metadata {
    name = "ytdlp"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "ytdlp" {
  # resource "kubernetes_daemonset" "technitium" {
  metadata {
    name      = "ytdlp"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      app  = "ytdlp"
      tier = var.tier
    }
    annotations = {
      "diun.enable" = "true"
    }
  }
  spec {
    # strategy {
    #   type = "Recreate"
    # }
    # replicas = 1
    selector {
      match_labels = {
        app = "ytdlp"
      }
    }
    template {
      metadata {
        labels = {
          app = "ytdlp"
        }
      }
      spec {
        container {
          image = "tzahi12345/youtubedl-material:nightly"
          name  = "ytdlp"
          # resources {
          #   limits = {
          #     cpu    = "1"
          #     memory = "1Gi"
          #   }
          # requests = {
          #   cpu    = "1"
          #   memory = "1Gi"
          # }
          # }
          port {
            container_port = 17442
          }
          volume_mount {
            mount_path = "/app/appdata"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/audio"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/video"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/users"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/subscriptions"
            name       = "data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/ytdlp"
            server = "10.0.10.15"
          }
        }
        # }
      }
    }
  }
}

resource "kubernetes_service" "ytdlp" {
  metadata {
    name      = "ytdlp"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      "app" = "ytdlp"
    }
  }

  spec {
    selector = {
      app = "ytdlp"
    }
    port {
      name        = "ytdlp"
      port        = 80
      target_port = 17442
      protocol    = "TCP"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  name            = "ytdlp"
  tls_secret_name = var.tls_secret_name
  host            = "yt"
  extra_annotations = {
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
  }
}

# ----------------------
# yt-highlights service
# ----------------------

resource "kubernetes_secret" "openrouter" {
  metadata {
    name      = "openrouter-credentials"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
  }
  data = {
    "api-key" = var.openrouter_api_key
  }
}

resource "kubernetes_secret" "slack" {
  metadata {
    name      = "slack-credentials"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
  }
  data = {
    "bot-token" = var.slack_bot_token
    "channel"   = var.slack_channel
  }
}

resource "kubernetes_deployment" "yt_highlights" {
  metadata {
    name      = "yt-highlights"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      app  = "yt-highlights"
      tier = var.tier
    }
    annotations = {
      "diun.enable" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "yt-highlights"
      }
    }
    template {
      metadata {
        labels = {
          app = "yt-highlights"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
        }
        container {
          name              = "yt-highlights"
          image             = "viktorbarzin/yt-highlights:v20-20260127"
          image_pull_policy = "Always"
          port {
            container_port = 8000
          }
          env {
            name  = "ASR_MODEL"
            value = "large-v3"
          }
          env {
            name  = "ASR_DEVICE"
            value = "cuda"
          }
          env {
            name  = "OPENROUTER_MODEL"
            value = "deepseek/deepseek-r1-0528:free"
          }
          env {
            name = "OPENROUTER_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.openrouter.metadata[0].name
                key  = "api-key"
              }
            }
          }
          env {
            name  = "DATA_PATH"
            value = "/data"
          }
          env {
            name = "SLACK_BOT_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.slack.metadata[0].name
                key  = "bot-token"
              }
            }
          }
          env {
            name = "SLACK_CHANNEL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.slack.metadata[0].name
                key  = "channel"
              }
            }
          }
          env {
            name  = "REDIS_URL"
            value = "redis://redis.redis.svc.cluster.local:6379/0"
          }
          # Store model cache on NFS to avoid ephemeral storage eviction
          env {
            name  = "HF_HOME"
            value = "/data/cache/huggingface"
          }
          env {
            name  = "TORCH_HOME"
            value = "/data/cache/torch"
          }
          # Ollama fallback for when OpenRouter models fail
          env {
            name  = "OLLAMA_URL"
            value = "http://ollama.ollama.svc.cluster.local:11434"
          }
          env {
            name  = "OLLAMA_MODEL"
            value = "qwen2.5:14b"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 180
            period_seconds        = 60
            timeout_seconds       = 60
            failure_threshold     = 10
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/ytdlp-highlights"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "yt_highlights" {
  metadata {
    name      = "yt-highlights"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      "app" = "yt-highlights"
    }
  }
  spec {
    selector = {
      app = "yt-highlights"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
      protocol    = "TCP"
    }
  }
}

module "highlights_ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  name            = "yt-highlights"
  tls_secret_name = var.tls_secret_name
  host            = "yt-highlights"
  protected       = true
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-read-timeout" : "300"
    "nginx.ingress.kubernetes.io/proxy-send-timeout" : "300"
  }
}
