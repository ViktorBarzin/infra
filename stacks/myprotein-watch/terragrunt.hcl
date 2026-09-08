include "root" {
  path = find_in_parent_folders()
}

# Tier-1 stack (PG state backend). The root terragrunt.hcl generates backend.tf
# (pg backend, schema_name = "myprotein-watch"), providers.tf,
# cloudflare_provider.tf and tiers.tf automatically — do NOT hand-write those.

# ExternalSecret hits ESO which needs to be alive when the manifest applies.
dependency "external_secrets" {
  config_path  = "../external-secrets"
  skip_outputs = true
}
