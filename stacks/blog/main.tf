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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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

# Anubis reverse proxy in front of the blog. First-time visitors solve a
# tiny PoW (~250ms desktop), get a 30-day cookie, and pass through. Replaces
# the global ai-bot-block forwardAuth for this site.
module "anubis" {
  source     = "../../modules/kubernetes/anubis_instance"
  name       = "blog"
  namespace  = kubernetes_namespace.website.metadata[0].name
  target_url = "http://${kubernetes_service.blog.metadata[0].name}.${kubernetes_namespace.website.metadata[0].name}.svc.cluster.local"
}

module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  namespace         = kubernetes_namespace.website.metadata[0].name
  name              = "blog"
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  full_host        = "viktorbarzin.me"
  dns_type         = "proxied"
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # Anubis is the gatekeeper now — drop the redundant ai-bot-block forwardAuth.
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
  source            = "../../modules/kubernetes/ingress_factory"
  namespace         = kubernetes_namespace.website.metadata[0].name
  name              = "blog-www"
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  full_host        = "www.viktorbarzin.me"
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
}
