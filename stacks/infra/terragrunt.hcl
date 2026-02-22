# stacks/infra/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

# Skip in CI - infra stack manages Proxmox VMs which require SSH to the hypervisor
skip = get_env("CI", "") != ""

# Override provider generation to include proxmox (instead of k8s providers)
generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
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

provider "proxmox" {
  pm_api_url          = var.proxmox_pm_api_url
  pm_api_token_id     = var.proxmox_pm_api_token_id
  pm_api_token_secret = var.proxmox_pm_api_token_secret
  pm_tls_insecure     = true
}
EOF
}
