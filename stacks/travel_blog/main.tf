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
      "keel.sh/enrolled" = "true"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    ]
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

module "anubis" {
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "travel"
  namespace        = kubernetes_namespace.travel-blog.metadata[0].name
  target_url       = "http://${kubernetes_service.travel-blog.metadata[0].name}.${kubernetes_namespace.travel-blog.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/11"
}

module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  auth              = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  namespace         = kubernetes_namespace.travel-blog.metadata[0].name
  name              = "travel"
  tls_secret_name   = var.tls_secret_name
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  anti_ai_scraping  = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Travel Blog"
    "gethomepage.dev/description"  = "Travel stories"
    "gethomepage.dev/icon"         = "ghost.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z
