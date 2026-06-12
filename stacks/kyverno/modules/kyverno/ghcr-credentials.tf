# =============================================================================
# ghcr.io pull credentials — synced ONLY to namespaces running PRIVATE ghcr
# images (ADR-0002 off-infra builds)
# =============================================================================
# The credential is Viktor's admin PAT (Vault secret/viktor/ghcr_pull_token —
# an alias of github_pat: GitHub has no API to mint tokens, so a UI-minted
# read:packages token can replace the alias value later with no TF change).
# Because the PAT is broad, this is a positive allowlist, NOT cluster-wide
# like registry-credentials: any workload in a listed namespace can read the
# secret, so every entry widens the blast radius. Public-image namespaces
# need no credentials — keep this list to private-image consumers only.

locals {
  ghcr_private_namespaces = [
    "tripit",
    "f1-stream",
    "job-hunter",
    "instagram-poster",
    "payslip-ingest",
    "wealthfolio",
    "fire-planner",
    "recruiter-responder",
  ]
}

resource "kubernetes_secret" "ghcr_credentials" {
  metadata {
    name      = "ghcr-credentials"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = "ViktorBarzin"
          password = try(data.vault_kv_secret_v2.viktor.data["ghcr_pull_token"], "")
          auth     = base64encode("ViktorBarzin:${try(data.vault_kv_secret_v2.viktor.data["ghcr_pull_token"], "")}")
        }
      }
    })
  }
}

resource "kubectl_manifest" "sync_ghcr_credentials" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "sync-ghcr-credentials"
    }
    spec = {
      rules = [
        {
          name = "sync-ghcr-secret"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  names = local.ghcr_private_namespaces
                }
              }
            ]
          }
          generate = {
            generateExisting = true
            apiVersion       = "v1"
            kind             = "Secret"
            name             = "ghcr-credentials"
            namespace        = "{{request.object.metadata.name}}"
            synchronize      = true
            clone = {
              namespace = "kyverno"
              name      = "ghcr-credentials"
            }
          }
        }
      ]
    }
  })

  depends_on = [
    helm_release.kyverno,
    kubernetes_secret.ghcr_credentials,
    kubernetes_cluster_role_binding.kyverno_admission_secret_manager,
    kubernetes_cluster_role_binding.kyverno_background_secret_manager,
  ]
}
