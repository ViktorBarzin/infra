variable "tls_secret_name" {}

resource "kubernetes_namespace" "discount-bandit" {
  metadata {
    name = "discount-bandit"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.discount-bandit.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "discount-bandit" {
  metadata {
    name      = "discount-bandit"
    namespace = kubernetes_namespace.discount-bandit.metadata[0].name
    labels = {
      app = "discount-bandit"
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
        app = "discount-bandit"
      }
    }
    template {
      metadata {
        labels = {
          app = "discount-bandit"
        }
      }
      spec {
        container {
          image = "cybrarist/discount-bandit:latest-amd64"
          name  = "discount-bandit"
          env {
            name  = "DB_HOST"
            value = "mysql.dbaas"
          }
          env {
            name  = "DB_DATABASE"
            value = "discountbandit"
          }
          env {
            name  = "DB_USERNAME"
            value = "discountbandit"
          }
          env {
            name  = "DB_PASSWORD"
            value = ""
          }
          env {
            name  = "APP_URL"
            value = "http://discount.viktorbarzin.me:80"
          }

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "discount-bandit" {
  metadata {
    name      = "discount-bandit"
    namespace = kubernetes_namespace.discount-bandit.metadata[0].name
    labels = {
      "app" = "discount-bandit"
    }
  }

  spec {
    selector = {
      app = "discount-bandit"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.discount-bandit.metadata[0].name
  name            = "discount-bandit"
  host            = "discount"
  tls_secret_name = var.tls_secret_name
}
