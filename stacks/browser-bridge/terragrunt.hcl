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

# redis is deliberately NOT a dependency. None of its ~15 consumers declares one:
# the connection is made at runtime over a Service DNS name, and a Terragrunt
# dependency here would only order applies. The cross-stack edit that DOES
# matter is the namespace allowlist in stacks/redis (see README).
