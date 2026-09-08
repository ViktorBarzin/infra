include "root" {
  path = find_in_parent_folders()
}

dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}

# The root generates providers.tf with the only allowed required_providers
# block (Terraform permits one per module), so OCI — a non-hashicorp provider
# absent from that list — is added via an _override.tf. It is generated (not
# committed) exactly like providers.tf/backend.tf: the *_override.tf gitignore
# rule keeps generated files out of git; this terragrunt.hcl is the source of
# truth that recreates it every run.
generate "oci_provider" {
  path      = "oci_provider_override.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}
EOF
}
