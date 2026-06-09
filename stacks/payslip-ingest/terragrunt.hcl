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
  # payslip-ingest repo HEAD — includes migrations 0004 + 0005, bonus-dedup,
  # and the Woodpecker path-filter fix. Bump on every deploy.
  image_tag = "4f70681d"
}
