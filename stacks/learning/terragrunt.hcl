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
  # The build running on 2026-10-12. The image is CI_SETS_IMAGE: learning's
  # GHA build ends by triggering .woodpecker/first-party-deploy.yml, which
  # sets the :<sha> tag, so this value is used only on a recreate.
  image_tag = "v0.1.1"
}
