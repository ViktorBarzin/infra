variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "website" {
  metadata {
    name = "website"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.website.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "blog" {
  metadata {
    name      = "blog"
    namespace = kubernetes_namespace.website.metadata[0].name
    labels = {
      run  = "blog"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
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

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.website.metadata[0].name
  name            = "blog"
  service_name    = "blog"
  full_host       = "viktorbarzin.me"
  dns_type        = "proxied"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Blog"
    "gethomepage.dev/description"  = "Personal blog"
    "gethomepage.dev/icon"         = "hugo.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

module "ingress-www" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.website.metadata[0].name
  name            = "blog-www"
  service_name    = "blog"
  full_host       = "www.viktorbarzin.me"
  tls_secret_name = var.tls_secret_name
}
