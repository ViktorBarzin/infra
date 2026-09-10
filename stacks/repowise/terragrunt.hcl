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

# The api-token-middleware plugin must be loaded in Traefik before our
# Middleware CRD can be applied with a non-zero token list. It is also what
# gates /mcp, since repowise's MCP HTTP transport has no auth of its own.
dependency "traefik" {
  config_path  = "../traefik"
  skip_outputs = true
}

# The reconciler clones the Corpus from Forgejo on its first pass.
dependency "forgejo" {
  config_path  = "../forgejo"
  skip_outputs = true
}

# The private ghcr package is pulled via the Kyverno-synced
# ghcr-credentials allowlist, which must include repowise before the pod
# can start.
dependency "kyverno" {
  config_path  = "../kyverno"
  skip_outputs = true
}
