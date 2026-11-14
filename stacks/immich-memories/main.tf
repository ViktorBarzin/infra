# Immich Memories (https://github.com/sam-dumont/immich-memories, MIT): turns
# photos and videos from Immich into MP4 films with titles and music. Viktor
# uses it for per-year (year_in_review) and per-album films of his own library.
# Upstream image, pinned tag; Renovate proposes bumps.
#
# Shape follows upstream's Kustomize base (deploy/kubernetes/base), Basic tier
# (CPU only, no model servers), one replica (workflow state is in-process).
#
# Sign-in: Authentik forward-auth gates the host (Home Server Admins), and the
# app's own "header" provider takes the user from X-authentik-username. The
# app trusts that header only from peers in trusted_proxies (the pod CIDR),
# and the NetworkPolicy below lets only Traefik reach the pod, so no other pod
# can present a forged header. Traefik deletes client-sent X-Authentik-*
# headers before every router (docs/agents/ingress.md).
#
# Vault secret/immich-memories, seeded by hand 2026-11-14:
#   immich_api_key  Immich API key "immich-memories" on me@viktorbarzin.me,
#                   the upstream read set plus the upload set (asset.upload,
#                   tag.create, tag.asset, asset.update, album.create,
#                   albumAsset.create), no asset.delete. Upload is opt-in per
#                   film. Revoke in Immich > Account Settings > API Keys.
#   storage_secret  session signing key (openssl rand -hex 32).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "nfs_server" { type = string }

variable "image_tag" {
  type = string
  # renovate: datasource=docker depName=ghcr.io/sam-dumont/immich-memories
  default = "1.0.0"
}

locals {
  namespace = "immich-memories"
  host      = "immich-memories.viktorbarzin.me"
  image     = "ghcr.io/sam-dumont/immich-memories:${var.image_tag}"
  labels = {
    app = "immich-memories"
  }

  # Model files live on NFS (regenerable, about 5 GB). The paths are what
  # `immich-memories models fetch` writes and the app reads.
  model_env = {
    IMMICH_MEMORIES_DEPLOYMENT_TIER                            = "basic"
    IMMICH_MEMORIES_TRIAGE__ENCODER                            = "/models/triage/dinov2-small.onnx"
    IMMICH_MEMORIES_EDITORIAL__PREPARATION__MARQO_ONNX         = "/models/detectors/nsfw-marqo-384.onnx"
    IMMICH_MEMORIES_EDITORIAL__PREPARATION__DETECTOR_CACHE_DIR = "/models/huggingface"
    IMMICH_MEMORIES_FREE_TEXT__WORDNET                         = "/models/wordnet/wordnet.zip"
  }

  app_env = merge(local.model_env, {
    IMMICH_URL                         = "http://immich-server.immich.svc.cluster.local:2283"
    IMMICH_MEMORIES_IMMICH__PUBLIC_URL = "https://immich.viktorbarzin.me"
    IMMICH_MEMORIES_OUTPUT__DIRECTORY  = "/app/output"
    TZ                                 = "Europe/London"

    IMMICH_MEMORIES_AUTH__ENABLED      = "true"
    IMMICH_MEMORIES_AUTH__PROVIDER     = "header"
    IMMICH_MEMORIES_AUTH__USER_HEADER  = "X-authentik-username"
    IMMICH_MEMORIES_AUTH__EMAIL_HEADER = "X-authentik-email"
    IMMICH_MEMORIES_AUTH__PUBLIC_URL   = "https://${local.host}"
    # The immediate peer is a Traefik pod. Its address changes on every
    # restart, so trust the pod CIDR and let the NetworkPolicy admit only
    # Traefik. FORWARDED_ALLOW_IPS must stay unset with header auth.
    IMMICH_MEMORIES_AUTH__TRUSTED_PROXIES  = jsonencode(["10.10.0.0/16"])
    IMMICH_MEMORIES_SERVER__SECURE_COOKIES = "true"
    IMMICH_MEMORIES_SERVER__ALLOWED_HOSTS  = jsonencode([local.host])
  })
}

resource "kubernetes_namespace" "immich_memories" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
      # The aux LimitRange caps a container at 4Gi; upstream sizes FFmpeg
      # assembly at 4-8 GB, so this namespace carries its own pair below.
      "resource-governance/custom-limitrange" = "true"
      "resource-governance/custom-quota"      = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_resource_quota" "immich_memories" {
  metadata {
    name      = "immich-memories-quota"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "2"
      "requests.memory" = "4Gi"
      "limits.memory"   = "12Gi"
      pods              = "5"
    }
  }
}

resource "kubernetes_limit_range" "immich_memories" {
  metadata {
    name      = "immich-memories-limits"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "256Mi"
      }
      default_request = {
        cpu    = "25m"
        memory = "64Mi"
      }
      max = {
        memory = "8Gi"
      }
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "immich-memories-secrets"
      namespace = kubernetes_namespace.immich_memories.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "immich-memories-secrets" }
      data = [
        { secretKey = "IMMICH_API_KEY", remoteRef = { key = "immich-memories", property = "immich_api_key" } },
        { secretKey = "IMMICH_MEMORIES_STORAGE_SECRET", remoteRef = { key = "immich-memories", property = "storage_secret" } },
      ]
    }
  }
}

# The store (SQLite, people and editing decisions) and the preview cache:
# face and photo data, so encrypted; SQLite refuses NFS, so block. On the SAS
# pool to keep preview reads off sdc, which also serves Immich's originals.
# Cache budget: 30 GB previews + 10 GB clips + 10 GB prepared sources + 5 GB
# past cuts, plus the store (docs maintenance/storage-backups.md).
resource "kubernetes_persistent_volume_claim" "cache" {
  wait_until_bound = false
  metadata {
    name      = "immich-memories-cache-encrypted"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "120Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted-sas"
    resources {
      requests = { storage = "60Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer grows this claim; do not shrink it back.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# Finished films (output/) and model files (models/). /srv/nfs/immich-memories
# and both subdirectories were created on the PVE host owned by 1000:1000,
# mode 750, before the first apply (docs/runbooks/nfs-prerequisites.md).
module "data" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-memories-data"
  namespace          = kubernetes_namespace.immich_memories.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/immich-memories"
  storage            = "100Gi"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "immich_memories" {
  metadata {
    name      = "immich-memories"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "secret.reloader.stakater.com/reload" = "immich-memories-secrets"
    }
  }
  spec {
    # Single replica: workflow state lives in the process.
    replicas = 1
    strategy {
      type = "Recreate" # RWO cache volume
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "dependency.kyverno.io/wait-for" = "immich-server.immich:2283"
        }
      }
      spec {
        # A Service named immich-memories would inject IMMICH_MEMORIES_* env
        # vars that collide with the app's own settings prefix.
        enable_service_links            = false
        automount_service_account_token = false
        security_context {
          run_as_non_root        = true
          run_as_user            = 1000
          run_as_group           = 1000
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Downloads missing model files on first start; later starts only
        # check digests.
        init_container {
          name    = "fetch-models"
          image   = local.image
          command = ["/bin/sh", "-c", "test -s /models/triage/dinov2-small.onnx && test -s /models/detectors/nsfw-marqo-384.onnx && test -d /models/huggingface && test -s /models/wordnet/wordnet.zip || immich-memories models fetch"]
          dynamic "env" {
            for_each = local.model_env
            content {
              name  = env.key
              value = env.value
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }
          volume_mount {
            name       = "cache"
            mount_path = "/home/immich/.immich-memories"
          }
          volume_mount {
            name       = "cache"
            mount_path = "/home/immich/.cache"
          }
          volume_mount {
            name       = "data"
            mount_path = "/models"
            sub_path   = "models"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        container {
          name  = "immich-memories"
          image = local.image
          port {
            name           = "http"
            container_port = 8080
          }
          env_from {
            secret_ref {
              name = "immich-memories-secrets"
            }
          }
          dynamic "env" {
            for_each = local.app_env
            content {
              name  = env.key
              value = env.value
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          # Upstream: idle about 100 MB, analysis 2-4 GB, FFmpeg assembly
          # 4-8 GB at 1080p. Burstable: the request covers analysis and the
          # limit covers a render. No CPU limit (cluster policy).
          resources {
            requests = {
              cpu    = "1"
              memory = "2Gi"
            }
            limits = {
              memory = "8Gi"
            }
          }
          volume_mount {
            name       = "cache"
            mount_path = "/home/immich/.immich-memories"
          }
          volume_mount {
            name       = "cache"
            mount_path = "/home/immich/.cache"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/output"
            sub_path   = "output"
          }
          volume_mount {
            name       = "data"
            mount_path = "/models"
            sub_path   = "models"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          liveness_probe {
            http_get {
              path = "/health/live"
              port = "http"
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          # 503 until config is present and Immich answers.
          readiness_probe {
            http_get {
              path = "/health/ready"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 15
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.cache.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.data.claim_name
          }
        }
        # FFmpeg intermediates: 4Gi is enough for 1080p (8Gi for 4K).
        volume {
          name = "tmp"
          empty_dir {
            size_limit = "4Gi"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret, kubernetes_limit_range.immich_memories]
}

resource "kubernetes_service" "immich_memories" {
  metadata {
    name      = "immich-memories"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# Only Traefik may reach the app: header sign-in trusts any peer in the pod
# CIDR, so every other pod must be kept out. Kubelet probes come from the
# node and are not affected.
resource "kubernetes_network_policy" "immich_memories" {
  metadata {
    name      = "immich-memories-ingress"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "traefik"
          }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.immich_memories.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.immich_memories.metadata[0].name
  name            = "immich-memories"
  service_name    = kubernetes_service.immich_memories.metadata[0].name
  port            = 80
  tls_secret_name = var.tls_secret_name
  homepage_group  = "Media & Entertainment"
  extra_annotations = {
    "gethomepage.dev/description" = "Year-in-review and album films from Immich photos"
    "gethomepage.dev/icon"        = "immich.png"
  }
}
