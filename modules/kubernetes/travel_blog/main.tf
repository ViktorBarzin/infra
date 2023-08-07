variable "tls_secret_name" {}

resource "kubernetes_namespace" "travel-blog" {
  metadata {
    name = "travel-blog"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "travel-blog"
  tls_secret_name = var.tls_secret_name
}

# module "dockerhub_creds" {
#   source    = "../dockerhub_secret"
#   namespace = "website"
#   password  = var.dockerhub_password
# }

resource "kubernetes_deployment" "blog" {
  metadata {
    name      = "travel-blog"
    namespace = "travel-blog"
    labels = {
      run = "travel-blog"
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        run = "travel-blog"
      }
    }
    template {
      metadata {
        labels = {
          run = "travel-blog"
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
    namespace = "travel-blog"
    labels = {
      "run" = "travel-blog"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9113"
    }
  }

  spec {
    selector = {
      run = "travel-blog"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
    port {
      name        = "prometheus"
      port        = "9113"
      target_port = "9113"
    }
  }
}

resource "kubernetes_ingress_v1" "travel-blog" {
  metadata {
    name      = "travel-blog-ingress"
    namespace = "travel-blog"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["travel.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "travel.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "travel-blog"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
