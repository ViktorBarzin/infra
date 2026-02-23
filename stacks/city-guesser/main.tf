variable "tls_secret_name" { type = string }


resource "kubernetes_namespace" "city-guesser" {
  metadata {
    name = "city-guesser"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "city-guesser"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      run  = "city-guesser"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "city-guesser"
      }
    }
    template {
      metadata {
        labels = {
          run = "city-guesser"
        }
      }
      spec {
        container {
          image = "viktorbarzin/city-guesser:latest"
          name  = "city-guesser"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      "run" = "city-guesser"
    }
  }

  spec {
    selector = {
      run = "city-guesser"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = "city-guesser"
  name            = "city-guesser"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
