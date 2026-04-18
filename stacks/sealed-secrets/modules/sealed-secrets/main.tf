variable "tier" { type = string }

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "sealed_secrets" {
  metadata {
    name = "sealed-secrets"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# -----------------------------------------------------------------------------
# Sealed Secrets — encrypts secrets for safe git storage
# https://github.com/bitnami-labs/sealed-secrets
# -----------------------------------------------------------------------------
resource "helm_release" "sealed_secrets" {
  namespace        = kubernetes_namespace.sealed_secrets.metadata[0].name
  create_namespace = false
  name             = "sealed-secrets"
  atomic           = true
  timeout          = 300

  repository = "https://bitnami-labs.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = "2.18.3"

  values = [yamlencode({
    crds = {
      create = true
    }

    resources = {
      requests = {
        cpu    = "50m"
        memory = "192Mi"
      }
      limits = {
        memory = "192Mi"
      }
    }
  })]
}
