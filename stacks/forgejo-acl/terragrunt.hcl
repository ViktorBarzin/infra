include "root" {
  path = find_in_parent_folders()
}

# Forgejo must be up before its API can be configured.
dependency "forgejo" {
  config_path  = "../forgejo"
  skip_outputs = true
}
