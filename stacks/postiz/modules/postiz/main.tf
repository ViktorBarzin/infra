# ──────────────────────────────────────────────────────────────────────────────
# Postiz — social media post scheduler (Instagram Stories + others).
#
# Chart: oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz (v1.0.5)
# App  : ghcr.io/gitroomhq/postiz-app:v2.21.7
#
# Layout:
#   - Bundled Postgres + Redis (chart subcharts) — fine for v1.
#   - Local file storage for uploads on a `proxmox-lvm` PVC mounted at /uploads.
#   - JWT_SECRET is sourced from Vault via ESO. The chart's helper-templated
#     Secret name is `<release>-secrets`; we pin `fullnameOverride: postiz` so
#     the Secret resolves to `postiz-secrets`. The chart already mounts that
#     Secret via `envFrom: secretRef: <fullname>-secrets`, so ESO patching the
#     same Secret with `creationPolicy: Merge` injects `JWT_SECRET` into the
#     pod env without forking the chart.
#   - OAuth credentials for Meta/X/LinkedIn etc. are NOT pre-seeded — Postiz
#     stores those in its own DB once the user adds providers via the UI.
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "postiz" {
  metadata {
    name = var.namespace
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.postiz.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# /uploads PVC — keeps user-uploaded media across pod restarts.
resource "kubernetes_persistent_volume_claim" "uploads" {
  wait_until_bound = false
  metadata {
    name      = "postiz-uploads"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "50Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# ExternalSecret: patches the chart-managed `postiz-secrets` Secret with
# JWT_SECRET pulled from Vault. `creationPolicy: Merge` means ESO will not
# take ownership — it just adds/updates the keys it manages, leaving the
# Helm-owned Secret resource intact. The chart's deployment already wires
# this Secret in via `envFrom: secretRef: postiz-secrets`.
resource "kubernetes_manifest" "external_secret_jwt" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "postiz-jwt-secret"
      namespace = kubernetes_namespace.postiz.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "postiz-secrets"
        creationPolicy = "Merge"
      }
      data = [{
        secretKey = "JWT_SECRET"
        remoteRef = {
          key      = "instagram-poster"
          property = "postiz_jwt_secret"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.postiz]
}

resource "helm_release" "postiz" {
  namespace        = kubernetes_namespace.postiz.metadata[0].name
  name             = "postiz"
  create_namespace = false
  atomic           = true
  timeout          = 600

  repository = "oci://ghcr.io/gitroomhq/postiz-helmchart/charts"
  chart      = "postiz-app"
  version    = var.chart_version

  values = [yamlencode({
    fullnameOverride = "postiz"

    image = {
      repository = "ghcr.io/gitroomhq/postiz-app"
      tag        = var.image_tag
      pullPolicy = "IfNotPresent"
    }

    service = {
      type = "ClusterIP"
      port = 80 # chart maps Service port 80 -> targetPort http (containerPort 5000)
    }

    # Non-secret env. Note: BACKEND_INTERNAL_URL stays in-pod (Postiz convention).
    env = {
      MAIN_URL                         = "https://postiz.viktorbarzin.me"
      FRONTEND_URL                     = "https://postiz.viktorbarzin.me"
      NEXT_PUBLIC_BACKEND_URL          = "https://postiz.viktorbarzin.me/api"
      BACKEND_INTERNAL_URL             = "http://localhost:3000"
      STORAGE_PROVIDER                 = "local"
      UPLOAD_DIRECTORY                 = "/uploads"
      NEXT_PUBLIC_UPLOAD_DIRECTORY     = "/uploads"
      # Set true after first admin user is created via UI
      DISABLE_REGISTRATION             = "false"
      IS_GENERAL                       = "true"
      NX_ADD_PLUGINS                   = "false"
    }

    # Empty placeholder for chart-rendered Secret. ESO patches JWT_SECRET via
    # creationPolicy=Merge above. DATABASE_URL/REDIS_URL are auto-wired by the
    # chart's bundled subcharts and don't need to be set here.
    secrets = {
      DATABASE_URL                  = ""
      REDIS_URL                     = ""
      JWT_SECRET                    = ""
      X_API_KEY                     = ""
      X_API_SECRET                  = ""
      LINKEDIN_CLIENT_ID            = ""
      LINKEDIN_CLIENT_SECRET        = ""
      REDDIT_CLIENT_ID              = ""
      REDDIT_CLIENT_SECRET          = ""
      GITHUB_CLIENT_ID              = ""
      GITHUB_CLIENT_SECRET          = ""
      RESEND_API_KEY                = ""
      CLOUDFLARE_ACCOUNT_ID         = ""
      CLOUDFLARE_ACCESS_KEY         = ""
      CLOUDFLARE_SECRET_ACCESS_KEY  = ""
      CLOUDFLARE_BUCKETNAME         = ""
      CLOUDFLARE_BUCKET_URL         = ""
    }

    # Use our PVC for uploads (overrides the chart's emptyDir default).
    extraVolumes = [{
      name = "uploads-volume"
      persistentVolumeClaim = {
        claimName = kubernetes_persistent_volume_claim.uploads.metadata[0].name
      }
    }]
    extraVolumeMounts = [{
      name      = "uploads-volume"
      mountPath = "/uploads"
    }]

    resources = {
      requests = {
        cpu    = "100m"
        memory = "256Mi"
      }
      limits = {
        memory = "2Gi"
      }
    }

    # Bundled stateful deps — fine for v1, reconsider promotion to CNPG later.
    # Subchart passwords intentionally left to chart defaults; the bundled
    # PG/Redis Services are ClusterIP and only routable from the postiz
    # namespace, so the credentials never leave the pod network. Promotion to
    # CNPG with Vault-rotated creds is the next step.
    # Bitnami removed bitnami/postgresql + bitnami/redis from DockerHub
    # (Broadcom acquisition, Aug 2025). Older tags moved to bitnamilegacy/*.
    postgresql = {
      enabled = true
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "16.4.0-debian-12-r7"
      }
      auth = {
        username = "postiz"
        database = "postiz"
      }
    }

    redis = {
      enabled = true
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/redis"
        tag        = "7.4.0-debian-12-r2"
      }
    }
  })]

  depends_on = [
    kubernetes_persistent_volume_claim.uploads,
    kubernetes_manifest.external_secret_jwt,
  ]
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.postiz.metadata[0].name
  name            = "postiz"
  host            = var.host
  service_name    = "postiz" # chart Service name resolves to fullnameOverride
  port            = 80
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Postiz"
    "gethomepage.dev/description"  = "Social media post scheduler"
    "gethomepage.dev/icon"         = "postiz.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
  }
}
