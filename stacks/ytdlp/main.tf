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

# Both volumes below moved nfs-truenas -> nfs-pve as part of the class rename
# (bead code-yizt, Class A). Worth knowing before touching them again:
#
# The two storage classes are BYTE-IDENTICAL. Both nfs-truenas and nfs-pve are
# nfs.csi.k8s.io with server 192.168.1.127 and share /srv/nfs, so this rename
# moves no data whatsoever. What makes it a "Class A" change is only that
# storageClassName is immutable on a PVC, so Terraform must destroy and
# recreate the claim, and the pvc-protection finalizer holds that while a pod
# mounts it.
#
# That is exactly how this stack got stuck: an apply on 2026-09-04 at 05:13 UTC
# deleted the ytdlp-data-host PVC while the pod was still running, so it sat
# Terminating for nine hours. The service kept working, because a mounted PVC
# still serves, but it was one restart away from failing to mount. Cleared on
# 2026-09-04 by scaling the deployment to 0, letting the PVC finish deleting,
# deleting the two Released PVs, and re-applying.
#
# Deleting those PVs is safe and does not touch the files: both carry
# reclaimPolicy Retain, and the module hardcodes nfs_path, so the recreated PV
# points back at the same directory. Verified across the operation:
# /srv/nfs/ytdlp 121M / 25 files and /srv/nfs/ytdlp-highlights 3.2G / 21 files,
# identical before and after.
#
# If you change storage_class_name here again, scale the deployment to 0 FIRST.
module "nfs_data_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "ytdlp-data-host"
  namespace          = kubernetes_namespace.ytdlp.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/ytdlp"
  storage_class_name = "nfs-pve"
}

module "nfs_highlights_data_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "ytdlp-highlights-data-host"
  namespace          = kubernetes_namespace.ytdlp.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/ytdlp-highlights"
  storage_class_name = "nfs-pve"
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
          # requests 512Mi -> 256Mi on 2026-09-04 (bead code-hn6k). Measured
          # peak working set over 30 days is 165Mi, a third of the old request.
          # 256Mi is 1.5x that peak.
          #
          # An earlier version of this comment said the deployment is
          # Sablier-parked at 0 replicas most of the time. It is not: it runs
          # 1/1 and has for 248 days, so the reservation is real and worth
          # taking back.
          #
          # The LIMIT stays at 512Mi. Request and limit were equal before, so a
          # download that needs more headroom has exactly as much as it did.
          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
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
      # Scale-to-zero enrollment (ADR-0022), added 2026-08-31. This is a
      # request-driven FastAPI service that recorded ZERO VRAM use across the 7
      # days to 2026-08-31 — 24h of its logs contained only /health probes —
      # while holding a T4 time-slice the whole time. Parked at 0 replicas it
      # holds nothing.
      "sablier.enable" = "true"
      "sablier.group"  = "yt-highlights"
      # 180s: the liveness probe below already allows initial_delay_seconds=180
      # because this container loads torch weights before it can serve, so the
      # held request must wait at least as long or it lands on a cold pod.
      "sablier.ready-after" = "180s"
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
          name  = "yt-highlights"
          image = "viktorbarzin/yt-highlights:v20-20260127"
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
              # No gpumem seat: Sablier parks this at 0 replicas when idle
              # (2026-08-31), and a parked pod requests nothing. Awake it bursts
              # into real slack. Give it a measured seat if it ever becomes
              # always-on — ADR-0016's undeclared-tenant gap is otherwise what
              # the Kyverno require-gpumem policy (audit mode) now reports on.
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
      spec[0].replicas,                                                   # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
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
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): held-request wake, then the group's idle park.
  sablier = {
    group = "yt-highlights"
  }
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
