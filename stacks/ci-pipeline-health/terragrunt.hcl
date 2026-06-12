include "root" {
  path = find_in_parent_folders()
}

# ExternalSecret hits ESO which needs to be alive when the manifest applies.
dependency "external_secrets" {
  config_path  = "../external-secrets"
  skip_outputs = true
}
