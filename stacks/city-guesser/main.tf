variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "city-guesser" {
  metadata {
    name = "city-guesser"
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
  namespace       = "city-guesser"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      run  = "city-guesser"
      tier = local.tiers.aux
      # Scale-to-zero enrollment (ADR-0022): parked when idle, woken by the
      # first request through the ingress (design doc 2026-07-12).
      "sablier.enable" = "true"
      "sablier.group"  = "city-guesser"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "city-guesser"
      }
    }
    template {
      metadata {
        labels = {
          run = "city-guesser"
        }
      }
      spec {
        container {
          image = "viktorbarzin/city-guesser:latest"
          name  = "city-guesser"
          resources {
            limits = {
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
          }
          port {
            container_port = 80
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].replicas,                                                   # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
    ]
  }
}

resource "kubernetes_service" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      "run" = "city-guesser"
    }
  }

  spec {
    selector = {
      run = "city-guesser"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): held-request wake, 3h idle park.
  sablier = {
    group = "city-guesser"
  }
  dns_type        = "proxied"
  namespace       = "city-guesser"
  name            = "city-guesser"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "City Guesser"
    "gethomepage.dev/description"  = "Geography game"
    "gethomepage.dev/icon"         = "mdi-earth"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
