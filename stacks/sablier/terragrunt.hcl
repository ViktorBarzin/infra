include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

dependency "kyverno" {
  config_path  = "../kyverno"
  skip_outputs = true
}
