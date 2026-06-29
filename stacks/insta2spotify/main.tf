variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "insta2spotify" {
  metadata {
    name = "insta2spotify"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
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
      name      = "insta2spotify-secrets"
      namespace = "insta2spotify"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "insta2spotify-secrets"
      }
      dataFrom = [{
        extract = {
          key = "insta2spotify"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.insta2spotify]
}

# Data on NFS. Migrated off proxmox-lvm 2026-06-05 (Phase 1, LUN relief) —
# insta2spotify is config-only, no embedded DB. See
# docs/plans/2026-06-05-block-storage-harden-nfs-design.md
module "nfs_insta2spotify" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "insta2spotify-data-nfs"
  namespace  = kubernetes_namespace.insta2spotify.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/insta2spotify"
  storage    = "5Gi"
}

resource "kubernetes_deployment" "insta2spotify" {
  metadata {
    name      = "insta2spotify"
    namespace = kubernetes_namespace.insta2spotify.metadata[0].name
    labels = {
      app  = "insta2spotify"
      tier = local.tiers.aux
    }
    annotations = {
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
        app = "insta2spotify"
      }
    }
    template {
      metadata {
        labels = {
          app = "insta2spotify"
        }
      }
      spec {
        container {
          name  = "frontend"
          image = "viktorbarzin/insta2spotify-frontend:latest"
          port {
            container_port = 3000
          }
          env {
            name  = "BACKEND_URL"
            value = "http://127.0.0.1:8000"
          }
          env {
            name  = "ORIGIN"
            value = "https://insta2spotify.viktorbarzin.me"
          }
          resources {
            limits = {
              memory = "128Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
          }
        }
        container {
          name  = "backend"
          image = "viktorbarzin/insta2spotify-backend:latest"
          port {
            container_port = 8000
          }
          env {
            name  = "DATABASE_PATH"
            value = "/data/insta2spotify.db"
          }
          env {
            name  = "SPOTIFY_CACHE_PATH"
            value = "/data/.spotify_cache"
          }
          env {
            name  = "SPOTIFY_REDIRECT_URI"
            value = "https://insta2spotify.viktorbarzin.me/api/auth/callback"
          }
          env {
            name  = "SPOTIFY_PLAYLIST_ID"
            value = "7lcLakPy8pwwegFoOQ7MoG"
          }
          env {
            name = "SPOTIFY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "insta2spotify-secrets"
                key  = "spotify_client_id"
              }
            }
          }
          env {
            name = "SPOTIFY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "insta2spotify-secrets"
                key  = "spotify_client_secret"
              }
            }
          }
          env {
            name = "API_KEY"
            value_from {
              secret_key_ref {
                name = "insta2spotify-secrets"
                key  = "api_key"
              }
            }
          }
          env {
            name = "SPOTIFY_REFRESH_TOKEN"
            value_from {
              secret_key_ref {
                name = "insta2spotify-secrets"
                key  = "spotify_refresh_token"
              }
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            limits = {
              memory = "256Mi"
            }
            requests = {
              cpu    = "50m"
              memory = "160Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_insta2spotify.claim_name
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
      spec[0].template[0].spec[0].container[1].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "insta2spotify" {
  metadata {
    name      = "insta2spotify"
    namespace = kubernetes_namespace.insta2spotify.metadata[0].name
    labels = {
      app = "insta2spotify"
    }
  }
  spec {
    selector = {
      app = "insta2spotify"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

# TLS secret is auto-synced by Kyverno ClusterPolicy sync-tls-secret
# No need for setup_tls_secret module

# Main ingress — protected by Authentik (frontend)
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.insta2spotify.metadata[0].name
  name            = "insta2spotify"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  max_body_size   = "50m"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "insta2spotify"
    "gethomepage.dev/description"  = "Instagram Reels to Spotify"
    "gethomepage.dev/icon"         = "si-spotify"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# API ingress — unprotected (API key auth handled by backend). XHR-based
# endpoints; `auth = "public"` would 302+cookie-dance and break CORS
# preflight, so we stay at `auth = "none"`.
module "ingress_api" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.insta2spotify.metadata[0].name
  name            = "insta2spotify-api"
  host            = "insta2spotify"
  service_name    = "insta2spotify"
  tls_secret_name = var.tls_secret_name
  # auth = "none": API endpoints consumed by browser fetch() XHRs; forward-auth 302 breaks CORS preflight.
  auth            = "none"
  ingress_path    = ["/api/identify", "/api/auth", "/api/health", "/api/history"]
  max_body_size   = "50m"
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
