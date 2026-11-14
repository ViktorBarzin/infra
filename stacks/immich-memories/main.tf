# Immich Memories (https://github.com/sam-dumont/immich-memories, MIT): turns
# photos and videos from Immich into MP4 films with titles and music: per
# year (year_in_review), per album, month, trip and person.
# Upstream image, pinned tag; Renovate proposes bumps.
#
# ONE INSTANCE PER PERSON. The app holds one Immich connection per
# installation, and everyone who signs in to an installation uses that
# library, so each person gets their own copy (local.people below): own host,
# own cache volume, own NFS folder. Each person pastes their own Immich API
# key in Settings > Connection on first visit; the app stores it in its own
# store on the encrypted cache volume. IMMICH_URL is fixed by env, so the
# server field cannot be changed from the UI.
#
# Shape follows upstream's Kustomize base (deploy/kubernetes/base), Basic tier
# (CPU only, no model servers), one replica (workflow state is in-process).
#
# Sign-in: Authentik forward-auth gates each host, and the app's "header"
# provider takes the user from X-authentik-username. The header provider has
# no email allow-list, so WHO may open an instance is decided only by its
# `allowed_groups` at Authentik. The app trusts the header only from peers in
# trusted_proxies (the pod CIDR), and the NetworkPolicy lets only Traefik
# reach the pods, so no other pod can present a forged header. Traefik
# deletes client-sent X-Authentik-* headers before every router
# (docs/agents/ingress.md).
#
# Adding a person:
#   1. An Authentik group holding only that person, for example
#      "Immich Memories <Person>", and the host mapped to it in
#      stacks/authentik/forward-auth-apps.json (without that entry the
#      domain catch-all admits Home Server Admins only).
#   2. ssh root@<nfs host> 'mkdir -p /srv/nfs/immich-memories-<person>/{output,models}
#      && chown -R 1000:1000 /srv/nfs/immich-memories-<person>
#      && chmod 750 /srv/nfs/immich-memories-<person>{,/output,/models}'
#   3. An entry in local.people, then apply. The quota grows with the count.
#   4. The person creates an Immich API key (permissions in the service
#      catalog row) and pastes it in Settings > Connection.

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
  image     = "ghcr.io/sam-dumont/immich-memories:${var.image_tag}"

  # key = person; name = Deployment, Service, volume and ingress name, and the
  # host is <name>.viktorbarzin.me; NFS folder /srv/nfs/<name>.
  people = {
    viktor = {
      name           = "immich-memories"
      allowed_groups = ["Home Server Admins"]
    }
  }

  # Every instance pod carries this label; the NetworkPolicy selects it.
  common_labels = {
    "app.kubernetes.io/name" = "immich-memories"
  }

  # Model files live on NFS (regenerable). The paths are what
  # `immich-memories models fetch` writes and the app reads.
  model_env = {
    IMMICH_MEMORIES_DEPLOYMENT_TIER                            = "basic"
    IMMICH_MEMORIES_TRIAGE__ENCODER                            = "/models/triage/dinov2-small.onnx"
    IMMICH_MEMORIES_EDITORIAL__PREPARATION__MARQO_ONNX         = "/models/detectors/nsfw-marqo-384.onnx"
    IMMICH_MEMORIES_EDITORIAL__PREPARATION__DETECTOR_CACHE_DIR = "/models/huggingface"
    IMMICH_MEMORIES_FREE_TEXT__WORDNET                         = "/models/wordnet/wordnet.zip"
  }

  app_env = {
    for person, p in local.people : person => merge(local.model_env, {
      # No IMMICH_API_KEY: a value set by env cannot be saved from the UI.
      IMMICH_URL                         = "http://immich-server.immich.svc.cluster.local:2283"
      IMMICH_MEMORIES_IMMICH__PUBLIC_URL = "https://immich.viktorbarzin.me"
      IMMICH_MEMORIES_OUTPUT__DIRECTORY  = "/app/output"
      TZ                                 = "Europe/London"

      IMMICH_MEMORIES_AUTH__ENABLED      = "true"
      IMMICH_MEMORIES_AUTH__PROVIDER     = "header"
      IMMICH_MEMORIES_AUTH__USER_HEADER  = "X-authentik-username"
      IMMICH_MEMORIES_AUTH__EMAIL_HEADER = "X-authentik-email"
      IMMICH_MEMORIES_AUTH__PUBLIC_URL   = "https://${p.name}.viktorbarzin.me"
      # The immediate peer is a Traefik pod. Its address changes on every
      # restart, so trust the pod CIDR and let the NetworkPolicy admit only
      # Traefik. FORWARDED_ALLOW_IPS must stay unset with header auth.
      IMMICH_MEMORIES_AUTH__TRUSTED_PROXIES  = jsonencode(["10.10.0.0/16"])
      IMMICH_MEMORIES_SERVER__SECURE_COOKIES = "true"
      IMMICH_MEMORIES_SERVER__ALLOWED_HOSTS  = jsonencode(["${p.name}.viktorbarzin.me"])
      # The session signing key is generated on the cache volume at first
      # start, so each instance has its own.
    })
  }
}

# The single-instance stack (2026-11-14) had these at unindexed addresses.
moved {
  from = kubernetes_persistent_volume_claim.cache
  to   = kubernetes_persistent_volume_claim.cache["viktor"]
}
moved {
  from = module.data
  to   = module.data["viktor"]
}
moved {
  from = kubernetes_deployment.immich_memories
  to   = kubernetes_deployment.immich_memories["viktor"]
}
moved {
  from = kubernetes_service.immich_memories
  to   = kubernetes_service.immich_memories["viktor"]
}
moved {
  from = module.ingress
  to   = module.ingress["viktor"]
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

# Per instance: 1 CPU and 2Gi requested, 8Gi limit, plus room for the init
# container and a Recreate rollout.
resource "kubernetes_resource_quota" "immich_memories" {
  metadata {
    name      = "immich-memories-quota"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = tostring(length(local.people) + 1)
      "requests.memory" = "${2 * length(local.people) + 2}Gi"
      "limits.memory"   = "${8 * length(local.people) + 4}Gi"
      pods              = tostring(2 * length(local.people) + 3)
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

# The store (SQLite: the Immich key, people and editing decisions) and the
# preview cache: face and photo data, so encrypted; SQLite refuses NFS, so
# block. On the SAS pool to keep preview reads off sdc, which also serves
# Immich's originals. Cache budget: 30 GB previews + 10 GB clips + 10 GB
# prepared sources + 5 GB past cuts, plus the store.
resource "kubernetes_persistent_volume_claim" "cache" {
  for_each         = local.people
  wait_until_bound = false
  metadata {
    name      = "${each.value.name}-cache-encrypted"
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

# Finished films (output/) and model files (models/) in /srv/nfs/<name>.
# The folder and both subfolders are created on the PVE host owned by
# 1000:1000, mode 750, before the first apply (docs/runbooks/nfs-prerequisites.md).
module "data" {
  for_each           = local.people
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "${each.value.name}-data"
  namespace          = kubernetes_namespace.immich_memories.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/${each.value.name}"
  storage            = "100Gi"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "immich_memories" {
  for_each = local.people
  metadata {
    name      = each.value.name
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
    labels = {
      app  = each.value.name
      tier = local.tiers.aux
    }
  }
  spec {
    # Single replica: workflow state lives in the process.
    replicas = 1
    strategy {
      type = "Recreate" # RWO cache volume
    }
    selector {
      match_labels = { app = each.value.name }
    }
    template {
      metadata {
        labels = merge(local.common_labels, { app = each.value.name })
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

        # Downloads missing model files; later starts only check digests.
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
          dynamic "env" {
            for_each = local.app_env[each.key]
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
          # /health/live, not upstream's /health/ready: ready answers 503
          # until an Immich key is configured, which would keep a new
          # instance out of its Service, and the key is pasted in the UI.
          readiness_probe {
            http_get {
              path = "/health/live"
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
            claim_name = kubernetes_persistent_volume_claim.cache[each.key].metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.data[each.key].claim_name
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
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_limit_range.immich_memories]
}

resource "kubernetes_service" "immich_memories" {
  for_each = local.people
  metadata {
    name      = each.value.name
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
    labels    = { app = each.value.name }
  }
  spec {
    selector = { app = each.value.name }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# Only Traefik may reach the instances: header sign-in trusts any peer in the
# pod CIDR, so every other pod must be kept out. Kubelet probes come from the
# node and are not affected.
resource "kubernetes_network_policy" "immich_memories" {
  metadata {
    name      = "immich-memories-ingress"
    namespace = kubernetes_namespace.immich_memories.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.common_labels
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
  for_each        = local.people
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  allowed_groups  = each.value.allowed_groups
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.immich_memories.metadata[0].name
  name            = each.value.name
  service_name    = kubernetes_service.immich_memories[each.key].metadata[0].name
  port            = 80
  tls_secret_name = var.tls_secret_name
  homepage_group  = "Media & Entertainment"
  extra_annotations = {
    "gethomepage.dev/description" = "Year-in-review and album films from Immich photos (${each.key})"
    "gethomepage.dev/icon"        = "immich.png"
  }
}
