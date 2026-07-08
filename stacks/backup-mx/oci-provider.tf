provider "oci" {
  tenancy_ocid = data.vault_kv_secret_v2.viktor.data["oci_tenancy_ocid"]
  user_ocid    = data.vault_kv_secret_v2.viktor.data["oci_user_ocid"]
  fingerprint  = data.vault_kv_secret_v2.viktor.data["oci_api_key_fingerprint"]
  private_key  = data.vault_kv_secret_v2.viktor.data["oci_api_private_key"]
  region       = "eu-frankfurt-1"
}
