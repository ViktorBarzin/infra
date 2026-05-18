# kubectl provider — used by kubectl_manifest resources (swapped from
# hashicorp/kubernetes kubernetes_manifest due to provider crash on Kyverno
# ClusterPolicy CRDs, beads code-e2dp).
terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
