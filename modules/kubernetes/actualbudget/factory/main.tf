variable "tls_secret_name" {}
variable "name" {}
variable "tag" {
  default = "latest"
}

resource "kubernetes_deployment" "actualbudget" {
  metadata {
    name      = "actualbudget-${var.name}"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget-${var.name}"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "actualbudget-${var.name}"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "false" # daily updates; pretty noisy
          "diun.include_tags" = "^${var.tag}$"
        }
        labels = {
          app = "actualbudget-${var.name}"
        }
      }
      spec {
        container {
          image = "actualbudget/actual-server:${var.tag}"
          name  = "actualbudget"

          port {
            container_port = 5006
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/actualbudget/${var.name}"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "actualbudget" {
  metadata {
    name      = "budget-${var.name}"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget-${var.name}"
    }
  }

  spec {
    selector = {
      app = "actualbudget-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5006
    }
  }
}

module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "actualbudget"
  name            = "budget-${var.name}"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
  }
}
