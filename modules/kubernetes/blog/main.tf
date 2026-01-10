variable "tls_secret_name" {}
variable "tier" { type = string }
# variable "dockerhub_password" {}

resource "kubernetes_namespace" "website" {
  metadata {
    name = "website"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.website.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# module "dockerhub_creds" {
#   source    = "../dockerhub_secret"
#  namespace = kubernetes_namespace.website.metadata[0].name
#   password  = var.dockerhub_password
# }

resource "kubernetes_deployment" "blog" {
  metadata {
    name      = "blog"
    namespace = kubernetes_namespace.website.metadata[0].name
    labels = {
      run  = "blog"
      tier = var.tier
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
    namespace = kubernetes_namespace.website.metadata[0].name
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

resource "kubernetes_ingress_v1" "blog" {
  metadata {
    name      = "blog-ingress"
    namespace = kubernetes_namespace.website.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                       = "nginx"
      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-EOT
        # Only modify HTML
        sub_filter_types text/html;
        sub_filter_once off;

        # Disable compression so sub_filter works
        proxy_set_header Accept-Encoding "";

        # Inject analytics before </head>
        sub_filter '</head>' '
         <script src="https://rybbit.viktorbarzin.me/api/script.js"
              data-site-id="da853a2438d0"
              defer></script> 
        </head>';
      EOT
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
            service {
              name = "blog"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
    rule {
      host = "www.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "blog"
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
