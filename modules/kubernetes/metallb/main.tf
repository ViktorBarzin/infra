# Creates namespace and everythin needed
# Do not use until https://github.com/colinwilson/terraform-kubernetes-metallb/issues/5 is solved
# module "metallb" {
#   source  = "colinwilson/metallb/kubernetes"
#   version = "0.1.7"
# }

module "metallb" {
  source  = "ViktorBarzin/metallb/kubernetes"
  version = "0.1.5"
}

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "config"
    namespace = "metallb-system"
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
