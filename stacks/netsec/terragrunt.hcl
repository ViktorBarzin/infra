include "root" {
  path = find_in_parent_folders()
}

# Tier-1 stack (PG state backend). The root terragrunt.hcl generates backend.tf,
# providers.tf, cloudflare_provider.tf and tiers.tf; do not hand-write them.

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# The writer password is read from Vault secret/claude-sessions by an
# ExternalSecret; the ClickHouse users it logs in as live in stacks/claude-sessions.
dependency "claude_sessions" {
  config_path  = "../claude-sessions"
  skip_outputs = true
}
