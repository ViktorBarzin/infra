variable "tls_secret_name" {}
variable "tier" { type = string }
variable "credentials" { type = map(any) }

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
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.actualbudget.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# https://budget-viktor.viktorbarzin.me/
module "viktor" {
  source                     = "./factory"
  name                       = "viktor"
  tag                        = "edge"
  tls_secret_name            = var.tls_secret_name
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = var.tier
  budget_encryption_password = lookup(var.credentials["viktor"], "password", null)
  sync_id                    = lookup(var.credentials["viktor"], "sync_id", null)
}

# https://budget-anca.viktorbarzin.me/
module "anca" {
  source                     = "./factory"
  name                       = "anca"
  tag                        = "edge"
  tls_secret_name            = var.tls_secret_name
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = var.tier
  budget_encryption_password = lookup(var.credentials["anca"], "password", null)
  sync_id                    = lookup(var.credentials["anca"], "sync_id", null)
}

# https://budget-emo.viktorbarzin.me/
module "emo" {
  source                     = "./factory"
  name                       = "emo"
  tag                        = "edge"
  tls_secret_name            = var.tls_secret_name
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = var.tier
  budget_encryption_password = lookup(var.credentials["emo"], "password", null)
  sync_id                    = lookup(var.credentials["emo"], "sync_id", null)
}
