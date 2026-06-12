include "root" {
  path = find_in_parent_folders()
}

# Platform (Traefik/ingress middlewares), Vault (ESO reads secrets), and
# external-secrets (the ClusterSecretStore) must exist first.
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
