# OCI is not part of the root-generated providers.tf — required_providers
# blocks merge additively across files, so this stack-local file adds it
# without touching the generated ones (same pattern as goldmane's tls note).
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = data.vault_kv_secret_v2.viktor.data["oci_tenancy_ocid"]
  user_ocid    = data.vault_kv_secret_v2.viktor.data["oci_user_ocid"]
  fingerprint  = data.vault_kv_secret_v2.viktor.data["oci_api_key_fingerprint"]
  private_key  = data.vault_kv_secret_v2.viktor.data["oci_api_private_key"]
  region       = "eu-frankfurt-1"
}
