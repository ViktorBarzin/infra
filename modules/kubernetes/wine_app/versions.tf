# No provider blocks: the calling stack configures every provider.
# cloudflare and kubectl are here for the nested ingress_factory.
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }
}
