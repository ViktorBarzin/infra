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
  # :latest — CI drives the rollout: on every master push the pipeline builds
  # :latest + :<sha> and runs `kubectl set image deployment/lesson-harvester
  # ...:<sha>`, so the Deployment rolls to the just-built code (the container
  # image is ignore_changes/KEEL_IGNORE so applies don't fight it). The poll
  # CronJob uses :latest + Always. Project semver lives in pyproject + git tag.
  image_tag = "latest"
}
