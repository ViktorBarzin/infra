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
  # 8-char SHA from the Forgejo commit viktor/job-hunter@9c42eac9
  # (first image built locally + pushed 2026-04-19 due to a Woodpecker
  # v3.13 Forgejo webhook bug; bump on every deploy once CI recovers).
  image_tag = "48f8615d"
}
