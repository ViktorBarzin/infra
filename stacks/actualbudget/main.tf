variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "actualbudget-secrets"
      namespace = "actualbudget"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "actualbudget-secrets"
      }
      dataFrom = [{
        extract = {
          key = "actualbudget"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.actualbudget]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "actualbudget-secrets"
    namespace = kubernetes_namespace.actualbudget.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["credentials"])
}


# To create a new deployment:
/**
  1. Export a new nfs share with {name} in truenas
  2. Add {name} as proxied cloudflare route (tfvars)
  3. Add module here
*/

resource "kubernetes_namespace" "actualbudget" {
  metadata {
    name = "actualbudget"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.actualbudget.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# https://budget-viktor.viktorbarzin.me/
module "viktor" {
  source                     = "./factory"
  name                       = "viktor"
  tag                        = "26.3.0"
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  enable_http_api            = true
  enable_bank_sync           = true
  budget_encryption_password = lookup(local.credentials["viktor"], "password", null)
  sync_id                    = lookup(local.credentials["viktor"], "sync_id", null)
  homepage_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Budget Viktor"
    "gethomepage.dev/description"  = "Personal budget"
    "gethomepage.dev/icon"         = "actual-budget.png"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://budget-anca.viktorbarzin.me/
module "anca" {
  source                     = "./factory"
  name                       = "anca"
  tag                        = "26.3.0"
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  enable_http_api            = true
  enable_bank_sync           = true
  budget_encryption_password = lookup(local.credentials["anca"], "password", null)
  sync_id                    = lookup(local.credentials["anca"], "sync_id", null)
  homepage_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Budget Anca"
    "gethomepage.dev/description"  = "Personal budget"
    "gethomepage.dev/icon"         = "actual-budget.png"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://budget-emo.viktorbarzin.me/
module "emo" {
  source                     = "./factory"
  name                       = "emo"
  tag                        = "26.3.0"
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  enable_http_api            = true
  enable_bank_sync           = true
  budget_encryption_password = lookup(local.credentials["emo"], "password", null)
  sync_id                    = lookup(local.credentials["emo"], "sync_id", null)
  homepage_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Budget Emo"
    "gethomepage.dev/description"  = "Personal budget"
    "gethomepage.dev/icon"         = "actual-budget.png"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}
