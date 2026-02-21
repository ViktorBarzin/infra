variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "travel-blog" {
  metadata {
    name = "travel-blog"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.travel-blog.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# module "dockerhub_creds" {
#   source    = "../dockerhub_secret"
#  namespace = kubernetes_namespace.travel.metadata[0].name
#   password  = var.dockerhub_password
# }

resource "kubernetes_deployment" "blog" {
  metadata {
    name      = "travel-blog"
    namespace = kubernetes_namespace.travel-blog.metadata[0].name
    labels = {
      app  = "travel-blog"
      tier = var.tier
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "travel-blog"
      }
    }
    template {
      metadata {
        labels = {
          app = "travel-blog"
        }
      }
      spec {
        container {
          image = "viktorbarzin/travel_blog:latest"
          name  = "travel-blog"
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

        # container {
        #   image = "nginx/nginx-prometheus-exporter"
        #   name  = "nginx-exporter"
        #   args  = ["-nginx.scrape-uri", "http://127.0.0.1:8080/nginx_status"]
        #   port {
        #     container_port = 9113
        #   }
        # }
      }
    }
  }
}

resource "kubernetes_service" "travel-blog" {
  metadata {
    name      = "travel-blog"
    namespace = kubernetes_namespace.travel-blog.metadata[0].name
    labels = {
      app = "travel-blog"
    }
  }

  spec {
    selector = {
      app = "travel-blog"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.travel-blog.metadata[0].name
  name            = "travel"
  tls_secret_name = var.tls_secret_name
  service_name    = "travel-blog"
}
