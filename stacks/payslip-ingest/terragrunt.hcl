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
  # :latest — CI drives the rollout (ADR-0002, issue #24): every master push
  # builds :<sha8> + :latest on ghcr, then the Woodpecker deploy pipeline sets
  # the Deployment to the concrete SHA (image is KEEL_IGNORE_IMAGE'd in the
  # stack). The actualbudget-payroll-sync CronJob tracks :latest with
  # imagePullPolicy Always — the old SHA pin (4f70681d, a Forgejo-only tag)
  # is retired so the cron can never reference the dead registry path.
  image_tag = "latest"
}
