resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.12.1"

  values = [yamlencode({
    installCRDs = true
  })]
}

# --- ClusterSecretStore for Vault KV v2 ---

resource "kubernetes_manifest" "css_vault_kv" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "vault-kv" }
    spec = {
      provider = {
        vault = {
          server  = "http://vault-active.vault.svc.cluster.local:8200"
          path    = "secret"
          version = "v2"
          auth = {
            kubernetes = {
              mountPath = "kubernetes"
              role      = "eso"
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.external_secrets]
}

# --- ClusterSecretStore for Vault Database Engine ---

resource "kubernetes_manifest" "css_vault_db" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "vault-database" }
    spec = {
      provider = {
        vault = {
          server  = "http://vault-active.vault.svc.cluster.local:8200"
          path    = "database"
          version = "v1"
          auth = {
            kubernetes = {
              mountPath = "kubernetes"
              role      = "eso"
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.external_secrets]
}
