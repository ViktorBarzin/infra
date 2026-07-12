variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "slack_channel" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "ytdlp-secrets"
      namespace = "ytdlp"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "ytdlp-secrets"
      }
      dataFrom = [{
        extract = {
          key = "ytdlp"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ytdlp]
}

variable "redis_host" { type = string }


resource "kubernetes_namespace" "ytdlp" {
  metadata {
    name = "ytdlp"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ytdlp-data-host"
  namespace  = kubernetes_namespace.ytdlp.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/ytdlp"
}

module "nfs_highlights_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ytdlp-highlights-data-host"
  namespace  = kubernetes_namespace.ytdlp.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/ytdlp-highlights"
}

resource "kubernetes_deployment" "ytdlp" {
  # resource "kubernetes_daemonset" "technitium" {
  metadata {
    name      = "ytdlp"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      app  = "ytdlp"
      tier = local.tiers.aux
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
          resources {
            requests = {
              cpu    = "25m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
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
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
        # }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  name            = "ytdlp"
  tls_secret_name = var.tls_secret_name
  host            = "yt"
  dns_type        = "non-proxied"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "yt-dlp"
    "gethomepage.dev/description"  = "Video downloader"
    "gethomepage.dev/icon"         = "youtube-dl.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# ----------------------
# yt-highlights service
# ----------------------


resource "kubernetes_deployment" "yt_highlights" {
  metadata {
    name      = "yt-highlights"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      app  = "yt-highlights"
      tier = local.tiers.aux
    }
    annotations = {
      "diun.enable"                = "true"
      "reloader.stakater.com/auto" = "true"
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
          "nvidia.com/gpu.present" : "true"
        }
        toleration {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NoSchedule"
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
                name = "ytdlp-secrets"
                key  = "openrouter_api_key"
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
                name = "ytdlp-secrets"
                key  = "slack_bot_token"
              }
            }
          }
          env {
            name  = "SLACK_CHANNEL"
            value = var.slack_channel
          }
          env {
            name  = "REDIS_URL"
            value = "redis://${var.redis_host}:6379/0"
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
          persistent_volume_claim {
            claim_name = module.nfs_highlights_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  name            = "yt-highlights"
  tls_secret_name = var.tls_secret_name
  host            = "yt-highlights"
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "YT Highlights"
    "gethomepage.dev/description"  = "AI video highlights"
    "gethomepage.dev/icon"         = "youtube.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z
