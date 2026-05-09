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

inputs = {
  # Bump per deploy. Use 8-char git SHA in CI; :latest only for local trials.
  image_tag = "latest"
}
