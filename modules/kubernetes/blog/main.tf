variable "tls_secret_name" {}
variable "tls_crt" {}
variable "tls_key" {}
# variable "dockerhub_password" {}

resource "kubernetes_namespace" "website" {
  metadata {
    name = "website"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "website"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

# module "dockerhub_creds" {
#   source    = "../dockerhub_secret"
#   namespace = "website"
#   password  = var.dockerhub_password
# }

resource "kubernetes_deployment" "blog" {
  metadata {
    name      = "blog"
    namespace = "website"
    labels = {
      run = "blog"
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        run = "blog"
      }
    }
    template {
      metadata {
        labels = {
          run = "blog"
        }
      }
      spec {
        container {
          image = "viktorbarzin/blog:latest"
          name  = "blog"
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

        container {
          image = "nginx/nginx-prometheus-exporter"
          name  = "nginx-exporter"
          args  = ["-nginx.scrape-uri", "http://127.0.0.1:8080/nginx_status"]
          port {
            container_port = 9113
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "blog" {
  metadata {
    name      = "blog"
    namespace = "website"
    labels = {
      "run" = "blog"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9113"
    }
  }

  spec {
    selector = {
      run = "blog"
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

resource "kubernetes_ingress" "blog" {
  metadata {
    name      = "blog-ingress"
    namespace = "website"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "blog"
            service_port = "80"
          }
        }
      }
    }
  }
}
