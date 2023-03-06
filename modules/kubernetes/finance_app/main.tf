variable "tls_secret_name" {}
variable "monzo_client_id" {}
variable "monzo_client_secret" {}


resource "kubernetes_namespace" "finance_app" {
  metadata {
    name = "finance-app"
  }
}


module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "finance-app"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "finance_app" {
  metadata {
    name      = "finance-app"
    namespace = "finance-app"
    labels = {
      app = "finance-app"
    }
  }
  spec {
    replicas = 2
    selector {
      match_labels = {
        app = "finance-app"
      }
    }
    template {
      metadata {
        labels = {
          app = "finance-app"
        }
      }
      spec {
        container {
          image = "viktorbarzin/finance-app"
          name  = "finance-app"

          env {
            name  = "MONZO_CLIENT_ID"
            value = var.monzo_client_id
          }
          env {
            name  = "MONZO_CLIENT_SECRET"
            value = var.monzo_client_secret
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "finance_app" {
  metadata {
    name      = "finance-app"
    namespace = "finance-app"
    labels = {
      app = "finance-app"
    }
  }

  spec {
    selector = {
      app = "finance-app"
    }
    port {
      name = "http"
      port = "8000"
    }
  }
}
