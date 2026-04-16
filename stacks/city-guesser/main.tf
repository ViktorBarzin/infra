variable "tls_secret_name" {
  type      = string
  sensitive = true
}


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
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "64Mi"
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
  dns_type        = "proxied"
  namespace       = "city-guesser"
  name            = "city-guesser"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "City Guesser"
    "gethomepage.dev/description"  = "Geography game"
    "gethomepage.dev/icon"         = "mdi-earth"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
