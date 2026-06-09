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
  # :latest — CI drives the rollout. On every master push the pipeline builds
  # latest + :<sha> and runs `kubectl set image deployment/job-hunter ...:<sha>`
  # so the Deployment rolls to the just-built code immediately (no wait for
  # Keel's poll). Keel stays enrolled in parallel as a redundant net. The
  # CronJob uses :latest + Always pull (fresh pod each run). Project version
  # lives in pyproject.toml + git tag vX.Y.Z (semver), independent of the
  # deploy tag. CI OOM that had blocked all builds since 2026-04 is fixed.
  image_tag = "latest"
}
