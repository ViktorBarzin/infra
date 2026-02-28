variable "tls_secret_name" { type = string }
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
    }
    updater = {
      enabled = true
    }
    admissionController = {
      enabled = true
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
  namespace       = kubernetes_namespace.vpa.metadata[0].name
  name            = "goldilocks"
  service_name    = "goldilocks-dashboard"
  port            = 80
  tls_secret_name = var.tls_secret_name
  protected       = true

  depends_on = [helm_release.goldilocks]
}

# -----------------------------------------------------------------------------
# Kyverno policy — label namespaces for VPA mode by tier
# -----------------------------------------------------------------------------
# Goldilocks reads the goldilocks.fairwinds.com/vpa-update-mode label on
# namespaces to decide the updateMode for VPA objects it creates.
# Tier 0-core gets "off" (recommend only — these are critical infra where
# evictions cause downtime). All other namespaces get "auto".

resource "kubernetes_manifest" "vpa_auto_mode_label" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "goldilocks-vpa-auto-mode"
      annotations = {
        "policies.kyverno.io/title"       = "Goldilocks VPA Mode by Tier"
        "policies.kyverno.io/description" = "Sets VPA update mode per namespace: Off for tier-0 critical infra (no evictions), Auto for all others."
      }
    }
    spec = {
      rules = [
        # Tier 0-core: recommend only, never evict
        {
          name = "label-vpa-off-tier-0"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "0-core"
                    }
                  }
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
        # All other namespaces: initial mode (compatible with Terraform —
        # VPA mutates pods at creation, not the deployment spec)
        {
          name = "label-vpa-initial-default"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                }
              }
            ]
          }
          exclude = {
            any = [
              {
                resources = {
                  selector = {
                    matchLabels = {
                      tier = "0-core"
                    }
                  }
                }
              }
            ]
          }
          mutate = {
            patchStrategicMerge = {
              metadata = {
                labels = {
                  "goldilocks.fairwinds.com/vpa-update-mode" = "initial"
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
