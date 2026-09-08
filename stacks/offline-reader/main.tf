variable "image_tag" {
  type        = string
  default     = "latest"
  description = "offline-reader app image tag. Running tag set by the Woodpecker deploy (kubectl set image); ignore_changes'd below."
}
variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string } # 192.168.1.127 from config.tfvars

locals {
  namespace = "offline-reader"
  app_image = "ghcr.io/viktorbarzin/offline-reader:${var.image_tag}"
  # Capture Jobs (created at runtime by the app) run this image. Keel/CI keep :latest fresh.
  capture_image = "ghcr.io/viktorbarzin/offline-reader-capture:latest"
  labels        = { app = "offline-reader" }
}

resource "kubernetes_namespace" "offline_reader" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.aux
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- NFS RWX PVC (HDD): captured Pages + manifests + SQLite. Also mounted by capture Jobs. ---
module "nfs_pages" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "offline-reader-pages"
  namespace          = kubernetes_namespace.offline_reader.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/offline-reader"
  storage            = "50Gi"
  storage_class_name = "nfs-pve"
}

# --- Job RBAC (ADR-0002): the app creates one single-file-cli capture Job per Capture. ---
resource "kubernetes_service_account" "app" {
  metadata {
    name      = "offline-reader"
    namespace = kubernetes_namespace.offline_reader.metadata[0].name
  }
}
resource "kubernetes_role" "app" {
  metadata {
    name      = "offline-reader-jobs"
    namespace = kubernetes_namespace.offline_reader.metadata[0].name
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
}
resource "kubernetes_role_binding" "app" {
  metadata {
    name      = "offline-reader-jobs"
    namespace = kubernetes_namespace.offline_reader.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.app.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.app.metadata[0].name
    namespace = kubernetes_namespace.offline_reader.metadata[0].name
  }
}

resource "kubernetes_deployment" "offline_reader" {
  metadata {
    name        = "offline-reader"
    namespace   = kubernetes_namespace.offline_reader.metadata[0].name
    labels      = merge(local.labels, { tier = local.tiers.aux })
    annotations = { "reloader.stakater.com/search" = "true" }
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" } # SQLite single-writer on the RWX PVC
    selector { match_labels = local.labels }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = "8000"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.app.metadata[0].name
        image_pull_secrets { name = "registry-credentials" }
        container {
          name  = "offline-reader"
          image = local.app_image
          port { container_port = 8000 }

          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "CAPTURE_MODE"
            value = "k8s"
          }
          env {
            name  = "SINGLEFILE_IMAGE"
            value = local.capture_image
          }
          env {
            name  = "NFS_PVC_CLAIM"
            value = module.nfs_pages.claim_name
          }
          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref { field_path = "metadata.namespace" }
            }
          }
          # Share-ingest token (INGEST_TOKEN) from Vault via the ExternalSecret below,
          # so the token-gated /api/ingest endpoint (iOS Shortcut) can authenticate.
          env_from {
            # optional: pod still starts if the ExternalSecret hasn't synced yet
            # (INGEST_TOKEN then unset -> /api/ingest returns 503 until it syncs).
            secret_ref {
              name     = "offline-reader-secrets"
              optional = true
            }
          }

          volume_mount {
            name       = "pages"
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
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }
        volume {
          name = "pages"
          persistent_volume_claim { claim_name = module.nfs_pages.claim_name }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
  depends_on = [kubernetes_role_binding.app, kubernetes_manifest.offline_reader_secrets]
}

resource "kubernetes_service" "offline_reader" {
  metadata {
    name      = "offline-reader"
    namespace = kubernetes_namespace.offline_reader.metadata[0].name
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8000"
    }
  }
  spec {
    type     = "ClusterIP"
    selector = local.labels
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# Share-ingest token: Vault secret/offline-reader:ingest_token -> k8s Secret
# offline-reader-secrets -> env INGEST_TOKEN on the app. Seed Vault before apply:
#   vault kv put secret/offline-reader ingest_token=<random>
resource "kubernetes_manifest" "offline_reader_secrets" {
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "offline-reader-secrets", namespace = local.namespace }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target = {
        name     = "offline-reader-secrets"
        template = { metadata = { annotations = { "reloader.stakater.com/match" = "true" } } }
      }
      data = [
        { secretKey = "INGEST_TOKEN", remoteRef = { key = "offline-reader", property = "ingest_token" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.offline_reader]
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required" # owner-only Authentik forward-auth; app trusts X-Authentik-Username
  allowed_groups  = ["Home Server Admins"]
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.offline_reader.metadata[0].name
  name            = "offline-reader"
  port            = 8000
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/icon"        = "mdi-book-arrow-down"
    "gethomepage.dev/description" = "Saved articles for offline reading"
  }
}

# Auth-bypass carve-out for /api/ingest only: gated by INGEST_TOKEN INSIDE the app
# (an iOS Shortcut can't replay the Authentik OIDC cookie). Same host as module.ingress;
# mirrors the chrome-service snapshot carve-out.
module "ingress_ingest" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": /api/ingest is gated by a secret INGEST_TOKEN inside the app; an
  # iOS Shortcut can't replay the Authentik OIDC cookie (mirrors chrome-snapshot).
  auth              = "none"
  dns_type          = "none" # DNS already created by module.ingress
  namespace         = kubernetes_namespace.offline_reader.metadata[0].name
  name              = "offline-reader-ingest"
  host              = "offline-reader"
  service_name      = kubernetes_service.offline_reader.metadata[0].name
  port              = 8000
  ingress_path      = ["/api/ingest"]
  tls_secret_name   = var.tls_secret_name
  extra_annotations = { "gethomepage.dev/enabled" = "false" }
}

# --- NetworkPolicy: only traefik (post-forward-auth) + monitoring reach the pod,
# so nothing bypasses Authentik via the pod IP. Egress open -> capture Jobs crawl freely.
resource "kubernetes_network_policy_v1" "ingress" {
  metadata {
    name      = "offline-reader-ingress"
    namespace = kubernetes_namespace.offline_reader.metadata[0].name
  }
  spec {
    pod_selector { match_labels = local.labels }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "traefik" } }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "monitoring" } }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }
  }
}
