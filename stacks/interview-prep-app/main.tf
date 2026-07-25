variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "interview-prep-app" {
  metadata {
    name = "interview-prep-app"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true" # Keel watches this ns for :latest digest rolls
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.interview-prep-app.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "interview-prep-app" {
  metadata {
    name      = "interview-prep-app"
    namespace = kubernetes_namespace.interview-prep-app.metadata[0].name
    labels = {
      app  = "interview-prep-app"
      tier = local.tiers.aux
    }
    # Keel rolls new ghcr:latest digests. Seeds only — keys are in
    # ignore_changes below, so live annotations win on an existing deployment.
    annotations = {
      "keel.sh/policy"       = "force"
      "keel.sh/trigger"      = "poll"
      "keel.sh/match-tag"    = "true"
      "keel.sh/pollSchedule" = "@every 5m"
    }
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = { app = "interview-prep-app" } }
    template {
      metadata {
        labels = { app = "interview-prep-app" }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^latest$"
        }
      }
      spec {
        # ghcr-credentials Secret is cloned into this ns by the kyverno stack's
        # sync-ghcr-credentials ClusterPolicy (allowlist — see ghcr-credentials.tf).
        image_pull_secrets { name = "ghcr-credentials" }
        container {
          image             = "ghcr.io/viktorbarzin/interview-prep-app:latest"
          image_pull_policy = "Always"
          name              = "interview-prep-app"
          port { container_port = 80 } # Dockerfile EXPOSEs 80 (nginx)
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
}

resource "kubernetes_service" "interview-prep-app" {
  metadata {
    name      = "interview-prep-app"
    namespace = kubernetes_namespace.interview-prep-app.metadata[0].name
    labels    = { app = "interview-prep-app" }
  }
  spec {
    selector = { app = "interview-prep-app" }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied" # rides the wildcard CNAME; no record created (ADR-0021)
  namespace       = kubernetes_namespace.interview-prep-app.metadata[0].name
  name            = "interview-prep"     # → interview-prep.viktorbarzin.me
  service_name    = "interview-prep-app" # app/ns name differs from the ingress name
  tls_secret_name = var.tls_secret_name
  auth            = "required" # Authentik forward-auth gates every request
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Interview Prep"
    "gethomepage.dev/description"  = "Interview preparation PWA"
    "gethomepage.dev/icon"         = "mdi-school"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = "app=interview-prep-app"
  }
}

# re-fire apply 2026-07-25: prior merge pipeline (832) was superseded by a
# following push before applying (infra CI HEAD~1/supersession gap, mem #5028).
