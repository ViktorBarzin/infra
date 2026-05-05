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
  # priority-pass repo HEAD — auto-bumped by GHA `build-and-deploy.yml`
  # on every successful build. Manual edits welcome for local trials,
  # but CI will overwrite on the next push to main.
  image_tag = "7c01448d"
}
