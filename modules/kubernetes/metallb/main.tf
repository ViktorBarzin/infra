# Creates namespace and everythin needed
module "metallb" {
  source  = "colinwilson/metallb/kubernetes"
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
