include "root" {
  path = find_in_parent_folders()
}

# Tier-1 stack (PG state backend). The root terragrunt.hcl generates backend.tf
# (pg backend, schema_name = "chesscom-streak"), providers.tf,
# cloudflare_provider.tf and tiers.tf automatically — do NOT hand-write those.

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# The CronJob pulls a PRIVATE ghcr image, so the Kyverno-synced
# `ghcr-credentials` secret must already be cloned into this namespace.
dependency "kyverno" {
  config_path  = "../kyverno"
  skip_outputs = true
}
