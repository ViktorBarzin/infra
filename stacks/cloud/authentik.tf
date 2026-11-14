# The Authentik provider for the console's application, groups and tokens
# (modules/kubernetes/tanstack_app, authentik.tf there) and the CLI's sign-in
# client (cli_sign_in.tf). Same setup as stacks/tasks.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = local.cloud_authentik_url
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

# Viktor is the first member and the only Operator; Operators approve
# everyone else in the console (signup_mode "request").
data "authentik_user" "viktor" {
  username = "vbarzin@gmail.com"
}
