# variable "tls_secret_name" {}

resource "kubernetes_namespace" "dnscat2" {
  metadata {
    name = "dnscat2"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

# module "tls_secret" {
#   source          = "../setup_tls_secret"
#  namespace = kubernetes_namespace.dnscat2.metadata[0].name
#   tls_secret_name = var.tls_secret_name
# }

resource "kubernetes_deployment" "dnscat2" {
  metadata {
    name      = "dnscat2"
    namespace = kubernetes_namespace.dnscat2.metadata[0].name
    labels = {
      app = "dnscat2"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "dnscat2"
      }
    }
    template {
      metadata {
        labels = {
          app = "dnscat2"
        }
      }
      spec {
        container {
          image = "arno0x0x/dnscat2"
          name  = "dnscat2"
          stdin = true
          tty   = true
          port {
            name           = "dns"
            container_port = 53
            protocol       = "UDP"
          }
          env {
            name  = "DOMAIN_NAME"
            value = "rp.viktorbarzin.me"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "dnscat2" {
  metadata {
    name      = "dnscat2"
    namespace = kubernetes_namespace.dnscat2.metadata[0].name
    labels = {
      "app" = "dnscat2"
    }
  }

  spec {
    selector = {
      app = "dnscat2"
    }
    port {
      name     = "dns"
      protocol = "UDP"
      port     = 53
      #   target_port = 53
    }
  }
}
