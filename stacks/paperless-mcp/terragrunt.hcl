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

# Aetherinox bearer middleware must be loaded in Traefik before our
# Middleware CRD can be applied with a non-zero token list.
dependency "traefik" {
  config_path  = "../traefik"
  skip_outputs = true
}

# We point PAPERLESS_BASE_URL at the in-cluster service to avoid the
# Cloudflare->Traefik hop on every MCP call.
dependency "paperless-ngx" {
  config_path  = "../paperless-ngx"
  skip_outputs = true
}
