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
  # 99ab188f = master HEAD with levels.fyi scraper (HTML __NEXT_DATA__) +
  # comp_points/levels tables (alembic 0003). Built + pushed locally
  # 2026-04-19 while the Woodpecker Forgejo webhook remains broken.
  image_tag = "99ab188f"
}
