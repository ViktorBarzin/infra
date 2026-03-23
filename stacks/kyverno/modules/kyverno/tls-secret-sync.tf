
# =============================================================================
# TLS Certificate — Auto-sync to all namespaces
# =============================================================================
# Source wildcard cert (*.viktorbarzin.me) in kyverno namespace, cloned by
# ClusterPolicy into every NS. Renewal pipeline updates this source secret,
# Kyverno propagates to all namespaces within seconds.

resource "kubernetes_secret" "tls_secret" {
  metadata {
    name      = "tls-secret"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = file("${path.root}/secrets/fullchain.pem")
    "tls.key" = file("${path.root}/secrets/privkey.pem")
  }
}

resource "kubernetes_manifest" "sync_tls_secret" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "sync-tls-secret"
    }
    spec = {
      rules = [
        {
          name = "sync-tls-secret"
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
                  namespaces = ["kube-system", "kube-public", "kube-node-lease"]
                }
              }
            ]
          }
          generate = {
            apiVersion  = "v1"
            kind        = "Secret"
            name        = "tls-secret"
            namespace   = "{{request.object.metadata.name}}"
            synchronize = true
            clone = {
              namespace = "kyverno"
              name      = "tls-secret"
            }
          }
        }
      ]
    }
  }

  depends_on = [
    helm_release.kyverno,
    kubernetes_secret.tls_secret,
    kubernetes_cluster_role_binding.kyverno_admission_secret_manager,
    kubernetes_cluster_role_binding.kyverno_background_secret_manager,
  ]
}
