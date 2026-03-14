variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "freedify_credentials" {
  type      = map(any)
  sensitive = true
}


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
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
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
  tier               = local.tiers.aux
  protected          = true
  listenbrainz_token = lookup(var.freedify_credentials["viktor"], "listenbrainz_token", null)
  genius_token       = lookup(var.freedify_credentials["viktor"], "genius_token", null)
  dab_session        = lookup(var.freedify_credentials["viktor"], "dab_session", null)
  dab_visitor_id     = lookup(var.freedify_credentials["viktor"], "dab_visitor_id", null)
  gemini_api_key     = lookup(var.freedify_credentials["viktor"], "gemini_api_key", null)
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Freedify (Viktor)"
    "gethomepage.dev/description"  = "Music streaming"
    "gethomepage.dev/icon"         = "navidrome.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://music-emo.viktorbarzin.me/
module "emo" {
  source          = "./factory"
  name            = "emo"
  tag             = "latest"
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.freedify]
  tier            = local.tiers.aux
  protected       = true
  genius_token    = lookup(var.freedify_credentials["emo"], "genius_token", null)
  gemini_api_key  = lookup(var.freedify_credentials["emo"], "gemini_api_key", null)
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Freedify (Emo)"
    "gethomepage.dev/description"  = "Music streaming"
    "gethomepage.dev/icon"         = "navidrome.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
