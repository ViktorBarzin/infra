# Creates namespace and everythin needed
# Do not use until https://github.com/colinwilson/terraform-kubernetes-metallb/issues/5 is solved
# module "metallb" {
#   source  = "colinwilson/metallb/kubernetes"
#   version = "0.1.7"
# }
variable "tier" { type = string }

resource "kubernetes_namespace" "metallb" {
  metadata {
    name = "metallb-system"
    labels = {
      app = "metallb"
      # "istio-injection" : "disabled"
      # tier = var.tier
    }
  }
}

module "metallb" {
  source     = "ViktorBarzin/metallb/kubernetes"
  version    = "0.1.5"
  depends_on = [kubernetes_namespace.metallb]
}

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "config"
    namespace = kubernetes_namespace.metallb.metadata[0].name
  }
  data = {
    config = <<EOT
address-pools:
- name: default
  protocol: layer2
  addresses:
  - 10.0.20.200-10.0.20.220
EOT
  }
}
