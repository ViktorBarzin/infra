include "root" {
  path = find_in_parent_folders()
}

dependency "infra" {
  config_path  = "../infra"
  skip_outputs = true
}

# apply-trigger 2026-06-12 (android-emulator-rate-limit middleware): non-merge
# commit so the changed-stack detector sees this stack (merge-diff blindness).
