variable "service_name" {}
variable "port" {}

resource "kubernetes_service" "bind" {
  metadata {
    name      = var.service_name
    namespace = "bind"
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
    labels = {
      "app" = var.service_name
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      "app" = var.service_name
    }
    port {
      name        = "dns"
      protocol    = "UDP"
      port        = var.port
      target_port = "53"
    }
  }
}
