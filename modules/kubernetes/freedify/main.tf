variable "tls_secret_name" {}
variable "tier" { type = string }
variable "additional_credentials" { type = map(any) }

# To create a new deployment:
/**
  1. Export a new nfs share with {name} in truenas at /mnt/main/freedify/{name}
  2. Add {name} as proxied cloudflare route (tfvars)
  3. Add module here
*/

resource "kubernetes_namespace" "freedify" {
  metadata {
    name = "freedify"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.freedify.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# https://music-viktor.viktorbarzin.me/
module "viktor" {
  source             = "./factory"
  name               = "viktor"
  tag                = "latest"
  tls_secret_name    = var.tls_secret_name
  depends_on         = [kubernetes_namespace.freedify]
  tier               = var.tier
  protected          = true
  listenbrainz_token = lookup(var.additional_credentials["viktor"], "listenbrainz_token", null)
  genius_token       = lookup(var.additional_credentials["viktor"], "genius_token", null)
  dab_session        = lookup(var.additional_credentials["viktor"], "dab_session", null)
  dab_visitor_id     = lookup(var.additional_credentials["viktor"], "dab_visitor_id", null)
  gemini_api_key     = lookup(var.additional_credentials["viktor"], "gemini_api_key", null)
}

# https://music-emo.viktorbarzin.me/
module "emo" {
  source          = "./factory"
  name            = "emo"
  tag             = "latest"
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.freedify]
  tier            = var.tier
  protected       = true
  genius_token    = lookup(var.additional_credentials["emo"], "genius_token", null)
  gemini_api_key  = lookup(var.additional_credentials["emo"], "gemini_api_key", null)
}
