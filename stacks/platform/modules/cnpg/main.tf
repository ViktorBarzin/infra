variable "tier" { type = string }

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "cnpg_system" {
  metadata {
    name = "cnpg-system"
    labels = {
      tier = var.tier
    }
  }
}

# -----------------------------------------------------------------------------
# CloudNativePG Operator — manages PostgreSQL clusters via CRDs
# https://cloudnative-pg.io/
# -----------------------------------------------------------------------------
resource "helm_release" "cnpg" {
  namespace        = kubernetes_namespace.cnpg_system.metadata[0].name
  create_namespace = false
  name             = "cnpg"
  atomic           = true
  timeout          = 300

  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "0.27.1"

  values = [yamlencode({
    crds = {
      create = true
    }

    replicaCount = 1

    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        memory = "256Mi"
      }
    }
  })]
}

# NOTE: local-path-provisioner is already installed in the cluster
# (via cloud-init template) with StorageClass "local-path" (default).
# ReclaimPolicy is "Delete" — for CNPG clusters, set
# .spec.storage.pvcTemplate.storageClassName = "local-path" in the
# Cluster CR. CNPG handles PVC lifecycle independently.
