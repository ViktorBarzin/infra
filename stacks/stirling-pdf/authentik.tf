# Stirling-PDF OIDC (SSO) was REMOVED 2026-07-16.
#
# Stirling PAYWALLS OAuth2/OIDC (Server tier, $99/mo): the free tier blocked
# auto-user-creation ("OAuth login blocked for new user … no paid license"),
# so SSO never worked — it just looped on the login page. Per the zero-cost
# rule, SSO was dropped and Stirling now uses LOCAL username/password login
# (see main.tf). The Authentik application/provider/group/binding created for
# it are removed by deleting their resource blocks.
#
# This file is retained ONLY as the provider config so `terraform apply` can
# DESTROY those now-removed Authentik objects (Terraform requires a configured
# provider to destroy its resources). Once the destroy has applied, this whole
# file is deleted (follow-up commit).

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}
