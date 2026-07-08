include "root" {
  path = find_in_parent_folders()
}

dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}
