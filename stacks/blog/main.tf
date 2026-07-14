variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "website" {
  metadata {
    name = "website"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      spec[0].template[0].spec[0].container[1].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "blog"
  namespace        = kubernetes_namespace.website.metadata[0].name
  target_url       = "http://${kubernetes_service.blog.metadata[0].name}.${kubernetes_namespace.website.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/10"
}

module "ingress" {
  source       = "../../modules/kubernetes/ingress_factory"
  auth         = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  namespace    = kubernetes_namespace.website.metadata[0].name
  name         = "blog"
  service_name = module.anubis.service_name
  port         = module.anubis.service_port
  # Anubis binds its JWT to X-Real-Ip; the header must not reach it (flaps per
  # request across cloudflared pods for CF-tunneled traffic) — see ingress_factory.
  strip_x_real_ip   = true
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  full_host         = "viktorbarzin.me"
  dns_type          = "proxied"
  tls_secret_name   = var.tls_secret_name
  anti_ai_scraping  = false # Anubis is the gatekeeper now — drop the redundant ai-bot-block forwardAuth.
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Blog"
    "gethomepage.dev/description"  = "Personal blog"
    "gethomepage.dev/icon"         = "hugo.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Carve-out for /net-diag.sh — a curl|bash diagnostic script for macOS.
# Anubis can't gate this path because non-JS clients (curl) can't solve PoW.
# Points at the bare blog nginx service, bypassing the Anubis proxy.
module "ingress_net_diag" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public read-only static file (curl|bash diagnostic script). No login, no PoW.
  auth             = "none"
  namespace        = kubernetes_namespace.website.metadata[0].name
  name             = "blog-net-diag"
  service_name     = kubernetes_service.blog.metadata[0].name
  port             = "80"
  ingress_path     = ["/net-diag.sh"]
  full_host        = "viktorbarzin.me"
  dns_type         = "none" # DNS already owned by the main blog ingress.
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # Single static file; nothing for scrapers to mine.
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z
