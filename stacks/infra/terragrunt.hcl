# stacks/infra/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

# Override provider generation to include proxmox + vault (k8s providers not needed)
generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
}

variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

variable "proxmox_pm_api_url" { type = string }
variable "proxmox_pm_api_token_id" { type = string }
variable "proxmox_pm_api_token_secret" { type = string }

provider "vault" {
  address          = "https://vault.viktorbarzin.me"
  skip_child_token = true
}

provider "proxmox" {
  pm_api_url          = var.proxmox_pm_api_url
  pm_api_token_id     = var.proxmox_pm_api_token_id
  pm_api_token_secret = var.proxmox_pm_api_token_secret
  pm_tls_insecure     = true
}
EOF
}
