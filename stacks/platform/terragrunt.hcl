# stacks/platform/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "infra" {
  config_path  = "../infra"
  skip_outputs = true
}

# NOTE: platform cannot depend on vault (vault depends on platform → cycle).
# Vault KV must be populated before platform apply. Use: vault first, then platform.
