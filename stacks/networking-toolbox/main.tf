variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "networking-toolbox" {
  metadata {
    name = "networking-toolbox"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.networking-toolbox.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "networking-toolbox" {
  metadata {
    name      = "networking-toolbox"
    namespace = kubernetes_namespace.networking-toolbox.metadata[0].name
    labels = {
      app  = "networking-toolbox"
      tier = local.tiers.aux
      # Scale-to-zero enrollment (ADR-0022): parked when idle, woken by the
      # first request through the ingress (design doc 2026-07-12).
      "sablier.enable" = "true"
      "sablier.group"  = "networking-toolbox"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "networking-toolbox"
      }
    }
    template {
      metadata {
        labels = {
          app = "networking-toolbox"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "lissy93/networking-toolbox:1.6.0"
          name  = "networking-toolbox"
          port {
            container_port = 3000
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
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
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].replicas,                                                   # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
    ]
  }
}

resource "kubernetes_service" "networking-toolbox" {
  metadata {
    name      = "networking-toolbox"
    namespace = kubernetes_namespace.networking-toolbox.metadata[0].name
    labels = {
      "app" = "networking-toolbox"
    }
  }

  spec {
    selector = {
      app = "networking-toolbox"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "3000"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): held-request wake, 3h idle park.
  sablier = {
    group = "networking-toolbox"
  }
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.networking-toolbox.metadata[0].name
  name            = "networking-toolbox"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Networking Toolbox"
    "gethomepage.dev/description"  = "Network diagnostic tools"
    "gethomepage.dev/icon"         = "mdi-lan"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
