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
  # 92afc38d = master HEAD with levels.fyi scraper + comp_table COALESCE
  # fix + Frankfurter FX backend (exchangerate.host free tier deprecated
  # in 2026). Built + pushed locally 2026-04-19 while the Woodpecker
  # Forgejo webhook remains broken.
  image_tag = "92afc38d"
}
