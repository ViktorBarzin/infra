# No provider blocks: the calling stack configures every provider, including
# `provider "authentik"` with the token from secret/authentik tf_api_token.
# cloudflare and kubectl are here for the nested ingress_factory.
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    authentik = {
      source = "goauthentik/authentik"
    }
    vault = {
      source = "hashicorp/vault"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }
}
