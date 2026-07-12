# Sablier — scale-to-zero wake layer (ADR-0022, design
# docs/plans/2026-07-12-scale-to-zero-sablier-design.md).
#
# One small Go service. The vendored Traefik plugin (stacks/traefik) asks it
# for session state per enrolled ingress; Sablier scales enrolled Deployments
# (label sablier.enable=true) 0<->N via the scale subresource and parks them
# again when the per-group session (middleware sessionDuration, default 3h)
# expires. Server-side timer does the scale-down — no request needed.
#
# Deliberately hand-rolled instead of the upstream helm chart (sablier 1.3.0):
# the chart hardcodes `sablier-<release>` naming, imagePullPolicy, and has no
# serviceAnnotations/volumes surface — this ~100-line spec buys clean naming
# ("sablier" everywhere), Prometheus scrape annotations, and repo-standard
# lifecycle/tier handling. The reused OSS is the pinned upstream image.
#
# Sessions are IN-MEMORY (stateless, no --storage.file) and
# --provider.auto-stop-on-startup defaults true: a Sablier pod restart parks
# every enrolled workload that has no live session. For rarely-used enrolled
# services that is the desired clean-slate; next request re-wakes them.

variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

locals {
  namespace = "sablier"
  # Pin the app version (plugin v1.3.0 <-> server compatibility is verified
  # as a pair). Diun watches for upstream releases; bump deliberately.
  image = "sablierapp/sablier:1.15.0"
}

resource "kubernetes_namespace" "sablier" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_service_account" "sablier" {
  metadata {
    name      = "sablier"
    namespace = kubernetes_namespace.sablier.metadata[0].name
  }
}

# Least-privilege scale access — mirrors the upstream chart's RBAC exactly
# (kubernetes provider needs read on workloads + write on the scale
# subresource only; it never touches pods/secrets). CNPG/Redis-operator
# integrations deliberately omitted (DBs are out of scale-to-zero scope).
resource "kubernetes_cluster_role" "sablier" {
  metadata {
    name = "sablier"
  }
  rule {
    api_groups = ["apps", ""]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps", ""]
    resources  = ["deployments/scale", "statefulsets/scale"]
    verbs      = ["get", "list", "watch", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding" "sablier" {
  metadata {
    name = "sablier"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.sablier.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.sablier.metadata[0].name
    namespace = kubernetes_namespace.sablier.metadata[0].name
  }
}

resource "kubernetes_deployment" "sablier" {
  metadata {
    name      = "sablier"
    namespace = kubernetes_namespace.sablier.metadata[0].name
    labels = {
      app  = "sablier"
      tier = local.tiers.cluster
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "sablier"
      }
    }
    template {
      metadata {
        labels = {
          app = "sablier"
        }
        annotations = {
          "diun.enable" = "true"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.sablier.metadata[0].name
        container {
          name  = "sablier"
          image = local.image
          args = [
            "start",
            "--provider.name=kubernetes",
            "--logging.level=info",
            # Server-side default for sessions opened without an explicit
            # duration; enrolled ingresses pass sessionDuration (3h default)
            # from their Middleware CR anyway.
            "--sessions.default-duration=3h",
            "--server.metrics.enabled=true",
          ]
          port {
            container_port = 10000
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 10000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 10000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
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
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
}

# The URL the Traefik plugin middlewares call:
# http://sablier.sablier.svc.cluster.local:10000 (ingress_factory default).
# Scrape annotations feed sablier_* session/wake metrics into Prometheus
# (prefix admitted in the kubernetes-service-endpoints keep-list,
# stacks/monitoring).
resource "kubernetes_service" "sablier" {
  metadata {
    name      = "sablier"
    namespace = kubernetes_namespace.sablier.metadata[0].name
    labels = {
      app = "sablier"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "10000"
    }
  }
  spec {
    selector = {
      app = "sablier"
    }
    port {
      name        = "api"
      port        = 10000
      target_port = 10000
      protocol    = "TCP"
    }
  }
}
