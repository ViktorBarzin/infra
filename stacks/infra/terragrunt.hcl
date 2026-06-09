# stacks/infra/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

# The root's `k8s_providers` generate block now declares `telmate/proxmox`
# in required_providers for every stack (harmless for non-infra stacks —
# they just don't instantiate a `provider "proxmox" {}` block).
#
# Here we add the per-stack provider config + the tfvar variable for the
# API URL. Credentials come from Vault `secret/viktor` (same pattern as
# cloudflare_provider.tf at the root). The output file name is distinct
# from `providers.tf` to avoid the same-path conflict that the old
# `generate "providers"` block silently triggered under Terragrunt v0.77.
generate "proxmox_provider" {
  path      = "proxmox_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "proxmox_pm_api_url" { type = string }

data "vault_kv_secret_v2" "proxmox_pm" {
  mount = "secret"
  name  = "viktor"
}

provider "proxmox" {
  pm_api_url          = var.proxmox_pm_api_url
  pm_api_token_id     = data.vault_kv_secret_v2.proxmox_pm.data["proxmox_pm_api_token_id"]
  pm_api_token_secret = data.vault_kv_secret_v2.proxmox_pm.data["proxmox_pm_api_token_secret"]
  pm_tls_insecure     = true
}
EOF
}
