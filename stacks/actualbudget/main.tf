variable "tls_secret_name" { type = string }
variable "actualbudget_credentials" { type = map(any) }
variable "nfs_server" { type = string }


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
  tag                        = "edge"
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  budget_encryption_password = lookup(var.actualbudget_credentials["viktor"], "password", null)
  sync_id                    = lookup(var.actualbudget_credentials["viktor"], "sync_id", null)
}

# https://budget-anca.viktorbarzin.me/
module "anca" {
  source                     = "./factory"
  name                       = "anca"
  tag                        = "edge"
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  budget_encryption_password = lookup(var.actualbudget_credentials["anca"], "password", null)
  sync_id                    = lookup(var.actualbudget_credentials["anca"], "sync_id", null)
}

# https://budget-emo.viktorbarzin.me/
module "emo" {
  source                     = "./factory"
  name                       = "emo"
  tag                        = "edge"
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  budget_encryption_password = lookup(var.actualbudget_credentials["emo"], "password", null)
  sync_id                    = lookup(var.actualbudget_credentials["emo"], "sync_id", null)
}
