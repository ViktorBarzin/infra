# Reference terragrunt.hcl (mirrors stacks/claude-agent-service). Move alongside
# main.tf into infra/stacks/pages-publish/. external-secrets is a dependency
# because the ExternalSecret needs the operator + ClusterSecretStore present.
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}

dependency "external-secrets" {
  config_path  = "../external-secrets"
  skip_outputs = true
}
