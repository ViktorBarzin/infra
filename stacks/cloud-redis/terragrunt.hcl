include "root" {
  path = find_in_parent_folders()
}

dependency "infra" {
  config_path  = "../infra"
  skip_outputs = true
}
