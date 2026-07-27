include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

# The kyverno allowlist ("learning" in sync-ghcr-credentials) must be applied
# before this namespace is created so the private-image pull secret is present.
dependency "kyverno" {
  config_path  = "../kyverno"
  skip_outputs = true
}

inputs = {
  # v0.1.0 — the first hand-pushed image. (App CI to auto-roll :latest + :<sha>
  # on push is a follow-up; until then, bump this tag to deploy a new build.)
  image_tag = "v0.1.0"
}
