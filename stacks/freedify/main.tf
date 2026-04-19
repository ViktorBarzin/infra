variable "tls_secret_name" {
  type      = string
  sensitive = true
}
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "freedify-secrets"
      namespace = "freedify"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "freedify-secrets"
      }
      dataFrom = [{
        extract = {
          key = "freedify"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.freedify]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "freedify-secrets"
    namespace = kubernetes_namespace.freedify.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["credentials"])
}


# To create a new deployment:
/**
  1. Create a subdirectory {name} under /srv/nfs/freedify on the Proxmox host (192.168.1.127)
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
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
  listenbrainz_token = lookup(local.credentials["viktor"], "listenbrainz_token", null)
  genius_token       = lookup(local.credentials["viktor"], "genius_token", null)
  dab_session        = lookup(local.credentials["viktor"], "dab_session", null)
  dab_visitor_id     = lookup(local.credentials["viktor"], "dab_visitor_id", null)
  gemini_api_key     = lookup(local.credentials["viktor"], "gemini_api_key", null)
  navidrome_scan_url = data.kubernetes_secret.eso_secrets.data["navidrome_scan_url"]
  ha_sofia_url       = lookup(data.kubernetes_secret.eso_secrets.data, "ha_sofia_url", "")
  ha_sofia_token     = lookup(data.kubernetes_secret.eso_secrets.data, "ha_sofia_token", "")
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
  genius_token    = lookup(local.credentials["emo"], "genius_token", null)
  gemini_api_key     = lookup(local.credentials["emo"], "gemini_api_key", null)
  navidrome_scan_url = data.kubernetes_secret.eso_secrets.data["navidrome_scan_url"]
  ha_sofia_url       = lookup(data.kubernetes_secret.eso_secrets.data, "ha_sofia_url", "")
  ha_sofia_token     = lookup(data.kubernetes_secret.eso_secrets.data, "ha_sofia_token", "")
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Freedify (Emo)"
    "gethomepage.dev/description"  = "Music streaming"
    "gethomepage.dev/icon"         = "navidrome.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
