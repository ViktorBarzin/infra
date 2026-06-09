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

dependency "dbaas" {
  config_path  = "../dbaas"
  skip_outputs = true
}

inputs = {
  # fire-planner repo HEAD — bump on every deploy.
  image_tag = "latest"

  # Bulk ingest toggle — flip to true once, apply, monitor job, then reset to false.
  run_examples_bulk_ingest = false
  # qwen3-8b: GPU has ~10.7 GB free (immich-ml using ~4 GB of 15 GB total).
  examples_llm_model = "qwen3-8b"
}
