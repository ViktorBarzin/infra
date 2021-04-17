terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    # kubectl = {
    #   source  = "gavinbunney/kubectl"
    #   version = ">= 1.7.0"
    # }
  }
  required_version = ">= 0.13"
}
