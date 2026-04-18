variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "travel-blog" {
  metadata {
    name = "travel-blog"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.travel-blog.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "blog" {
  metadata {
    name      = "travel-blog"
    namespace = kubernetes_namespace.travel-blog.metadata[0].name
    labels = {
      app  = "travel-blog"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 0 # Scaled down — clears ExternalAccessDivergence alert
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.travel-blog.metadata[0].name
  name            = "travel"
  tls_secret_name = var.tls_secret_name
  service_name    = "travel-blog"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Travel Blog"
    "gethomepage.dev/description"  = "Travel stories"
    "gethomepage.dev/icon"         = "ghost.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
