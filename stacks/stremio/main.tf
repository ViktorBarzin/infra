# =============================================================================
# stremio — self-hosted Stremio streaming server with NVENC transcoding (infra#80)
# =============================================================================
# Custom image ghcr.io/viktorbarzin/stremio-nvenc (repo ~/code/stremio-nvenc):
# tsaridas layout re-based to Debian/glibc + jellyfin-ffmpeg 4.4.1-4 NVENC,
# bundled web client + nginx HTTP basic-auth on ALL paths INCLUDING the
# /{infohash} torrent path (no open torrent gateway). Behind Traefik (TLS
# terminated at the edge), the pod serves plain HTTP on 8080.
#
# GPU: one time-slice of the shared T4 + a reserved 1500 MiB gpumem seat (ADR-0016).
# The seat fits under the 14000 advertised budget once portal-stt is decommissioned
# (13600 - 1500 + 1500 = 13600). Torrenting stays enabled as a debrid backup
# (Sofia egress; egress left open — no restrictive NetworkPolicy — for BitTorrent).
#
# Effectively stateless: addons/library live in the Stremio account (api.strem.io),
# not on disk. /data is an emptyDir (transcode/torrent scratch); an
# ephemeral-storage limit bounds cache growth (llama-swap hardening pattern).
#
# HITL: agent drafts; operator presence-claims the T4 + applies from the MAIN
# checkout (git-crypt) — never a worktree.
# =============================================================================

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "stremio"
  labels    = { app = "stremio" }
  image     = "ghcr.io/viktorbarzin/stremio-nvenc:latest"
}

resource "kubernetes_namespace" "stremio" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.gpu
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# TLS: the wildcard `tls-secret` is auto-synced into every namespace by the
# Kyverno `sync-tls-secret` ClusterPolicy (match: all Namespaces), so this stack
# does NOT call setup_tls_secret (which reads a per-stack secrets/fullchain.pem
# this stack doesn't ship). The ingress references tls_secret_name directly.

# basic-auth USERNAME/PASSWORD from Vault secret/stremio -> k8s Secret stremio-secrets.
resource "kubernetes_manifest" "external_secret" {
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "stremio-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "stremio-secrets" }
      data = [
        { secretKey = "webui_user", remoteRef = { key = "stremio", property = "webui_user" } },
        { secretKey = "webui_password", remoteRef = { key = "stremio", property = "webui_password" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.stremio]
}

resource "kubernetes_deployment" "stremio" {
  metadata {
    name      = "stremio"
    namespace = local.namespace
    labels    = merge(local.labels, { tier = local.tiers.gpu })
  }
  spec {
    replicas = 1
    # Recreate: only one pod should hold the T4 slice + emptyDir cache at a time.
    strategy { type = "Recreate" }
    selector { match_labels = { app = "stremio" } }
    template {
      metadata { labels = { app = "stremio" } }
      spec {
        node_selector = { "nvidia.com/gpu.present" = "true" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        priority_class_name = "gpu-workload"
        image_pull_secrets { name = "ghcr-credentials" } # Kyverno-synced (allowlist in stacks/kyverno)

        container {
          name              = "stremio"
          image             = local.image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          # basic-auth creds (entrypoint generates htpasswd from these).
          env {
            name = "USERNAME"
            value_from {
              secret_key_ref {
                name = "stremio-secrets"
                key  = "webui_user"
              }
            }
          }
          env {
            name = "PASSWORD"
            value_from {
              secret_key_ref {
                name = "stremio-secrets"
                key  = "webui_password"
              }
            }
          }
          # Web client points its streaming-server URL at the browser origin
          # (same-origin https://stremio.viktorbarzin.me) so basic-auth carries.
          env {
            name  = "AUTO_SERVER_URL"
            value = "1"
          }
          env {
            name  = "NO_CORS"
            value = "1"
          }
          env {
            name  = "APP_PATH"
            value = "/data"
          }
          # NVENC needs the `video` driver capability; operator injects only
          # compute,utility by default. `compute` covers the nvenc-linux probe's
          # CUDA context.
          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "all"
          }
          env {
            name  = "NVIDIA_VISIBLE_DEVICES"
            value = "all"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          # /manifest.json is served statically by nginx WITHOUT basic-auth, so
          # it's a valid probe target (every other path 401s pre-auth).
          startup_probe {
            http_get {
              path = "/manifest.json"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 24 # ~2 min for nginx + server.js to come up
          }
          readiness_probe {
            http_get {
              path = "/manifest.json"
              port = 8080
            }
            period_seconds    = 15
            failure_threshold = 4
          }
          liveness_probe {
            http_get {
              path = "/manifest.json"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu                 = "100m"
              memory              = "512Mi"
              "ephemeral-storage" = "2Gi"
            }
            limits = {
              memory              = "2Gi"
              "ephemeral-storage" = "20Gi" # bounds emptyDir + writable-layer cache growth
              "nvidia.com/gpu"    = "1"    # ONE time-slice (operator advertises 100), NOT the whole card
              # GPU VRAM budget (ADR-0016): NVENC transcode sessions (~1.2-1.5 GiB).
              "viktorbarzin.me/gpumem" = "1500"
            }
          }
        }

        volume {
          name = "data"
          empty_dir { size_limit = "20Gi" }
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
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Woodpecker/Keel manage the tag
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

resource "kubernetes_service" "stremio" {
  metadata {
    name      = "stremio"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    selector = { app = "stremio" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the stremio-nvenc image serves its OWN HTTP basic-auth (nginx)
  # on ALL paths incl. the /{infohash} torrent path. Authentik forward-auth breaks
  # Stremio's browser client (can't follow the OAuth 302), and basic-auth is the
  # proven-working gate for the media/HLS/torrent paths. Non-proxied (bypasses
  # Cloudflare's CDN-video ToS); CrowdSec nftables covers the origin IP. See infra#80.
  auth            = "none"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.stremio.metadata[0].name
  name            = "stremio"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Stremio"
    "gethomepage.dev/description"  = "Self-hosted Stremio (NVENC transcode)"
    "gethomepage.dev/icon"         = "stremio.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
