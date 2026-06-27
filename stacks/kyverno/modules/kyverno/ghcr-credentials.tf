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
    # tuya-bridge runs a PUBLIC-decision image, but new ghcr packages default
    # PRIVATE until their visibility is flipped (UI) — safety net so pulls
    # work from the first deploy; prune once the package is public.
    "tuya-bridge",
    "f1-stream",
    "job-hunter",
    "instagram-poster",
    "payslip-ingest",
    "wealthfolio",
    "fire-planner",
    "recruiter-responder",
    # openclaw's install-recruiter-plugin init container pulls the PRIVATE
    # ghcr.io/viktorbarzin/recruiter-responder:latest image (infra#27).
    "openclaw",
    # k8s-portal: last in-cluster image build, migrated to GHA→ghcr (ADR-0002,
    # "no local builds"). ghcr.io/viktorbarzin/k8s-portal:latest is PRIVATE
    # (infra repo default); the deployment references the cloned secret.
    "k8s-portal",
    # goldmane-edge-aggregator: PRIVATE ghcr image pulled by the aggregate
    # Deployment + digest CronJob (ADR-0014, infra#58).
    "goldmane-edge-aggregator",
    # plotting-book: image migrated from public DockerHub to PRIVATE
    # ghcr.io/passionprojectsanca/book-plotter (built by GHA in Anca's repo,
    # under her own org's ghcr). The deployment references the cloned secret.
    "plotting-book",
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
  # Kyverno's validate-policy webhook DENIES in-place changes to a generate
  # rule's spec ("changes of immutable fields ... is disallowed"), so any
  # allowlist edit must delete+recreate the policy. Generated secrets survive
  # policy deletion; generateExisting re-adopts them on recreate.
  force_new = true
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
