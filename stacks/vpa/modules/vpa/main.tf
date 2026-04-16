variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "tier" { type = string }

resource "kubernetes_namespace" "vpa" {
  metadata {
    name = "vpa"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.vpa.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# -----------------------------------------------------------------------------
# VPA — Vertical Pod Autoscaler (Fairwinds Helm chart)
# -----------------------------------------------------------------------------
resource "helm_release" "vpa" {
  namespace        = kubernetes_namespace.vpa.metadata[0].name
  create_namespace = false
  name             = "vpa"
  atomic           = true

  repository = "https://charts.fairwinds.com/stable"
  chart      = "vpa"

  values = [yamlencode({
    recommender = {
      enabled = true
      resources = {
        requests = {
          cpu    = "50m"
          memory = "200Mi"
        }
        limits = {
          memory = "200Mi"
        }
      }
    }
    updater = {
      enabled = true
      resources = {
        requests = {
          cpu    = "50m"
          memory = "200Mi"
        }
        limits = {
          memory = "200Mi"
        }
      }
    }
    admissionController = {
      enabled = true
      resources = {
        requests = {
          cpu    = "50m"
          memory = "200Mi"
        }
        limits = {
          memory = "200Mi"
        }
      }
    }
  })]
}

# -----------------------------------------------------------------------------
# Goldilocks — VPA dashboard (Fairwinds Helm chart)
# -----------------------------------------------------------------------------
resource "helm_release" "goldilocks" {
  namespace        = kubernetes_namespace.vpa.metadata[0].name
  create_namespace = false
  name             = "goldilocks"
  atomic           = true

  repository = "https://charts.fairwinds.com/stable"
  chart      = "goldilocks"

  values = [yamlencode({
    controller = {
      flags = {
        on-by-default = "true"
      }
    }
    dashboard = {
      replicaCount = 1
      flags = {
        on-by-default = "true"
      }
    }
  })]

  depends_on = [helm_release.vpa]
}

# -----------------------------------------------------------------------------
# Ingress — Goldilocks dashboard at goldilocks.viktorbarzin.me
# -----------------------------------------------------------------------------
module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.vpa.metadata[0].name
  name            = "goldilocks"
  service_name    = "goldilocks-dashboard"
  port            = 80
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Goldilocks"
    "gethomepage.dev/description"  = "Resource recommendations"
    "gethomepage.dev/icon"         = "mdi-scale-balance"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }

  depends_on = [helm_release.goldilocks]
}

# -----------------------------------------------------------------------------
# Kyverno policy — label namespaces for VPA observe-only mode
# -----------------------------------------------------------------------------
# Goldilocks reads the goldilocks.fairwinds.com/vpa-update-mode label on
# namespaces to decide the updateMode for VPA objects it creates.
# All namespaces get "off" — Terraform is the authoritative source of truth
# for container resources. Goldilocks provides recommendations only.

resource "kubernetes_manifest" "vpa_auto_mode_label" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "goldilocks-vpa-auto-mode"
      annotations = {
        "policies.kyverno.io/title"       = "Goldilocks VPA Observe-Only Mode"
        "policies.kyverno.io/description" = "Sets VPA update mode to off for all namespaces. Terraform owns container resources; Goldilocks provides recommendations only."
      }
    }
    spec = {
      rules = [
        {
          name = "label-vpa-off-all"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                }
              }
            ]
          }
          mutate = {
            patchStrategicMerge = {
              metadata = {
                labels = {
                  "goldilocks.fairwinds.com/vpa-update-mode" = "off"
                }
              }
            }
          }
        },
      ]
    }
  }

  depends_on = [helm_release.goldilocks]
}
