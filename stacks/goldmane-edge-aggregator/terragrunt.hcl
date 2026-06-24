include "root" {
  path = find_in_parent_folders()
}

# Tier-1 stack (PG state backend). The root terragrunt.hcl generates backend.tf
# (pg backend, schema_name = "goldmane-edge-aggregator"), providers.tf,
# cloudflare_provider.tf and tiers.tf automatically — do NOT hand-write those.
# This stack adds the hashicorp/tls provider via a local versions.tf (merged
# into the generated required_providers).

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}

# The Vault DB static role pg-goldmane-edges (7-day rotation) and the CNPG
# connection allowlist entry live in the vault stack (stacks/vault/main.tf).
# The vault dependency above orders this stack after it so the ExternalSecret
# can materialize the rotated credential on first apply.
