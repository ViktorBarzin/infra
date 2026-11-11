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
