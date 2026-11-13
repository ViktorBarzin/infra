include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# The live host guard (main.tf) is a Kyverno ValidatingPolicy, and Kyverno
# copies ghcr-credentials into the namespace for the private images.
dependency "kyverno" {
  config_path  = "../kyverno"
  skip_outputs = true
}

# The pg-cloud, pg-cloud-state and pg-cloud-provisioner static roles the
# ExternalSecrets read (stacks/vault cloud.tf, app_db_roles.tf).
dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}

dependency "external-secrets" {
  config_path  = "../external-secrets"
  skip_outputs = true
}
