variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "plotting-book" {
  metadata {
    name = "plotting-book"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.plotting-book.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    labels = {
      app  = "plotting-book"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "plotting-book"
      }
    }
    template {
      metadata {
        labels = {
          app = "plotting-book"
        }
      }
      spec {
        container {
          # image = "ancamilea/book-plotter:7"
          image = "viktorbarzin/book-plotter:7"
          name  = "plotting-book"
          port {
            container_port = 3001
          }
          resources {
            requests = {
              memory = "128Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
              cpu    = "500m"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    labels = {
      "app" = "plotting-book"
    }
  }

  spec {
    selector = {
      app = "plotting-book"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3001
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.plotting-book.metadata[0].name
  name            = "plotting-book"
  tls_secret_name = var.tls_secret_name

  additional_configuration_snippet = <<-EOF
    # Override CSP to allow data: URIs and blob: for database/workers
    proxy_hide_header Content-Security-Policy;
    add_header Content-Security-Policy "default-src 'self' blob: data:; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; worker-src 'self' blob:; connect-src 'self' blob:; frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me" always;
  EOF
}
