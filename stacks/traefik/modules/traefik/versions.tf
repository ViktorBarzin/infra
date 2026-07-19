# Provider source addresses are resolved per-module: without this block the
# module's kubectl_manifest.middleware_real_ip resource (middleware.tf) would
# default to the nonexistent hashicorp/kubectl. Declare the gavinbunney source
# explicitly so it is inherited from the root stack's configured provider.
# Matches modules/kubernetes/ingress_factory (kubectl_manifest.sablier).
terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
