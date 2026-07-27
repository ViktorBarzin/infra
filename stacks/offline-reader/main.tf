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
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "offline-reader-pages"
  namespace  = kubernetes_namespace.offline_reader.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/offline-reader"
  storage    = "50Gi"
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
          # Notifications (finish-notification) wired in a follow-up via an ExternalSecret;
          # the app treats SLACK_WEBHOOK/NTFY_* as optional and no-ops when unset.

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
  depends_on = [kubernetes_role_binding.app]
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

module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  auth              = "required" # owner-only Authentik forward-auth; app trusts X-Authentik-Username
  allowed_groups    = ["Home Server Admins"]
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.offline_reader.metadata[0].name
  name              = "offline-reader"
  port              = 8000
  tls_secret_name   = var.tls_secret_name
  extra_annotations = { "gethomepage.dev/icon" = "mdi-book-arrow-down" }
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
