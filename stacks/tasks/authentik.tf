# The Authentik application, groups and tokens for tasks are in
# modules/kubernetes/tanstack_app (authentik.tf there). The stack configures
# the provider and looks up the one person seeded into the groups.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "authentik_user" "viktor" {
  username = "vbarzin@gmail.com"
}
