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
  cleanup_on_fail  = true
  timeout          = 300

  # bitnami.github.io (official per the project README) — the old
  # bitnami-labs.github.io Pages repo went 404 (Broadcom's 2025 Bitnami purge)
  # and failed every CI apply with "Error locating chart".
  # 2.20.0 = controller 0.40.0 (2026-10-09). The chart ships its CRD in crds/,
  # so Helm never upgrades it; the 2.18.3 -> 2.20.0 CRD diff is description-only.
  repository = "https://bitnami.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = "2.22.0"

  values = [yamlencode({
    crds = {
      create = true
    }

    resources = {
      requests = {
        cpu    = "50m"
        memory = "192Mi"
      }
      # 384Mi, 2x the 14-day peak of 191Mi (2026-11-10). After an apiserver
      # blip the controller re-lists every Secret in the cluster, and that
      # spike OOM-killed it at the old 192Mi limit on 2026-11-03 and 11-08.
      limits = {
        memory = "384Mi"
      }
    }
  })]
}
