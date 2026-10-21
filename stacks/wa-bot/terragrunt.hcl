include "root" {
  path = find_in_parent_folders()
}

# Tier-1 stack (PG state backend). The root terragrunt.hcl generates backend.tf,
# providers.tf, cloudflare_provider.tf and tiers.tf — do NOT hand-write those.

# The ExternalSecret needs ESO alive when the manifest applies.
dependency "external_secrets" {
  config_path  = "../external-secrets"
  skip_outputs = true
}
