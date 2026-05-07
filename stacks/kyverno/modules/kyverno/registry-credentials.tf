
# =============================================================================
# Private Docker Registry Credentials — Auto-sync to all namespaces
# =============================================================================
# Source secret in kyverno namespace, cloned by ClusterPolicy into every NS.
# Pods use imagePullSecrets: [{name: registry-credentials}] to pull from
# registry.viktorbarzin.me (or 10.0.20.10:5050 internally).

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

resource "kubernetes_secret" "registry_credentials" {
  metadata {
    name      = "registry-credentials"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        # Phase 4 of forgejo-registry-consolidation 2026-05-07 — registry-
        # private decommissioned. Old auths entries (registry.viktorbarzin.me,
        # registry.viktorbarzin.me:5050, 10.0.20.10:5050) removed to prevent
        # silent fallback. If a pod somehow references the old hostname now,
        # it will visibly fail with auth missing rather than silently pulling
        # potentially-stale blobs.
        "forgejo.viktorbarzin.me" = {
          auth = base64encode("cluster-puller:${try(data.vault_kv_secret_v2.viktor.data["forgejo_pull_token"], "")}")
        }
      }
    })
  }
}

# Grant Kyverno controllers permission to manage Secrets (needed for generate clone rules)
resource "kubernetes_cluster_role" "kyverno_secret_manager" {
  metadata {
    name = "kyverno:secret-manager"
    labels = {
      "app.kubernetes.io/instance" = "kyverno"
    }
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "kyverno_admission_secret_manager" {
  metadata {
    name = "kyverno:admission-controller:secret-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.kyverno_secret_manager.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kyverno-admission-controller"
    namespace = "kyverno"
  }
}

resource "kubernetes_cluster_role_binding" "kyverno_background_secret_manager" {
  metadata {
    name = "kyverno:background-controller:secret-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.kyverno_secret_manager.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kyverno-background-controller"
    namespace = "kyverno"
  }
}

resource "kubernetes_manifest" "sync_registry_credentials" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "sync-registry-credentials"
    }
    spec = {
      rules = [
        {
          name = "sync-registry-secret"
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
            name        = "registry-credentials"
            namespace   = "{{request.object.metadata.name}}"
            synchronize = true
            clone = {
              namespace = "kyverno"
              name      = "registry-credentials"
            }
          }
        }
      ]
    }
  }

  depends_on = [
    helm_release.kyverno,
    kubernetes_secret.registry_credentials,
    kubernetes_cluster_role_binding.kyverno_admission_secret_manager,
    kubernetes_cluster_role_binding.kyverno_background_secret_manager,
  ]
}
