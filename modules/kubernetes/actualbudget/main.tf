variable "tls_secret_name" {}

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
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "actualbudget"
  tls_secret_name = var.tls_secret_name
}


# https://budget-viktor.viktorbarzin.me/
module "viktor" {
  source          = "./factory"
  name            = "viktor"
  tag             = "edge"
  tls_secret_name = var.tls_secret_name
}

# https://budget-anca.viktorbarzin.me/
module "anca" {
  source          = "./factory"
  name            = "anca"
  tag             = "edge"
  tls_secret_name = var.tls_secret_name
}
