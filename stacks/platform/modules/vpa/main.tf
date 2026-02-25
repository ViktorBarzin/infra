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
