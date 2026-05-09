locals {
  namespace = "instagram-poster"
  # Forgejo registry consolidation (2026-05-07): all custom service images
  # live under forgejo.viktorbarzin.me/viktor/<name>. The old 10.0.20.10
  # private registry was decommissioned the same day.
  image = "forgejo.viktorbarzin.me/viktor/instagram-poster:${var.image_tag}"
  labels = {
    app = "instagram-poster"
  }
}

resource "kubernetes_namespace" "instagram_poster" {
  metadata {
    name = local.namespace
    labels = {
      tier              = var.tier
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets sourced from Vault KV `secret/instagram-poster`.
# Seed these manually in Vault before applying:
#   secret/instagram-poster -> properties:
#     - immich_api_key            (required)
#     - postiz_api_token          (required)
#     - immich_tag_instagram      (optional — auto-resolved if missing)
#     - immich_tag_posted         (optional — auto-resolved if missing)
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "instagram-poster-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "instagram-poster-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        {
          secretKey = "IMMICH_API_KEY"
          remoteRef = {
            key      = "instagram-poster"
            property = "immich_api_key"
          }
        },
        {
          secretKey = "POSTIZ_API_TOKEN"
          remoteRef = {
            key      = "instagram-poster"
            property = "postiz_api_token"
          }
        },
        {
          secretKey = "IMMICH_TAG_INSTAGRAM"
          remoteRef = {
            key      = "instagram-poster"
            property = "immich_tag_instagram"
          }
        },
        {
          secretKey = "IMMICH_TAG_POSTED"
          remoteRef = {
            key      = "instagram-poster"
            property = "immich_tag_posted"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.instagram_poster]
}

# Persistent state: SQLite + image cache. Sensitive (API tokens may end up
# in cached images / debug logs), but the proxmox-lvm-encrypted SC is for
# user-data DBs; this is a small app cache so plain proxmox-lvm fits the
# infra/.claude/CLAUDE.md decision rule.
resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "instagram-poster-data"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "instagram_poster" {
  metadata {
    name      = "instagram-poster"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels = merge(local.labels, {
      tier = var.tier
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    replicas = 1
    # RWO PVC — cannot rolling-update.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Diun watches this image tag and POSTs the auto-upgrade pipeline.
          "diun.enable" = "true"
        }
      }

      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        container {
          name  = "instagram-poster"
          image = local.image

          port {
            container_port = 8000
          }

          env_from {
            secret_ref {
              name = "instagram-poster-secrets"
            }
          }

          env {
            name  = "IMMICH_BASE_URL"
            value = "https://immich.viktorbarzin.me"
          }
          env {
            name  = "POSTIZ_BASE_URL"
            value = "http://postiz.postiz.svc.cluster.local"
          }
          env {
            name  = "PUBLIC_BASE_URL"
            value = "https://instagram-poster.viktorbarzin.me"
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "LOG_LEVEL"
            value = "INFO"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }

  depends_on = [
    kubernetes_manifest.external_secret,
  ]
}

resource "kubernetes_service" "instagram_poster" {
  metadata {
    name      = "instagram-poster"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels    = local.labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

# Public ingress. No UI — entire host is API-only and Meta needs to fetch
# /image/<asset_id> unauthenticated to render preview cards. We therefore
# leave `protected = false` so Authentik forward-auth doesn't run on any
# path. Inbound auth is the API's own concern (Postiz webhook signature
# / shared secret as configured by the parallel agent).
module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.instagram_poster.metadata[0].name
  name            = "instagram-poster"
  tls_secret_name = var.tls_secret_name
  protected       = false
  port            = 80
}
