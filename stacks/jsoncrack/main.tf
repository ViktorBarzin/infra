variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "jsoncrack" {
  metadata {
    name = "jsoncrack"
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
  namespace       = kubernetes_namespace.jsoncrack.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "jsoncrack" {
  metadata {
    name      = "jsoncrack"
    namespace = kubernetes_namespace.jsoncrack.metadata[0].name
    labels = {
      app  = "jsoncrack"
      tier = local.tiers.aux
      # Scale-to-zero enrollment (ADR-0022): parked when idle, woken by the
      # first request through the ingress (design doc 2026-07-12).
      "sablier.enable" = "true"
      "sablier.group"  = "jsoncrack"
      # 5s settling delay after k8s readiness: covers Traefik endpoint-list
      # propagation so the first forwarded request never hits a 503 race.
      "sablier.ready-after" = "5s"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "jsoncrack"
      }
    }
    template {
      metadata {
        labels = {
          app = "jsoncrack"
        }
      }
      spec {
        container {
          image = "viktorbarzin/jsoncrack:latest"
          name  = "jsoncrack"
          port {
            container_port = 8080
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
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].replicas,                                                   # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
    ]
  }
}

resource "kubernetes_service" "jsoncrack" {
  metadata {
    name      = "json"
    namespace = kubernetes_namespace.jsoncrack.metadata[0].name
    labels = {
      "app" = "jsoncrack"
    }
  }

  spec {
    selector = {
      app = "jsoncrack"
    }
    port {
      name        = "http"
      target_port = 8080
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "anubis" {
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "json"
  namespace        = kubernetes_namespace.jsoncrack.metadata[0].name
  target_url       = "http://${kubernetes_service.jsoncrack.metadata[0].name}.${kubernetes_namespace.jsoncrack.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/7"
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): held-request wake, 3h idle park.
  sablier = {
    group = "jsoncrack"
  }
  auth         = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  dns_type     = "proxied"
  namespace    = kubernetes_namespace.jsoncrack.metadata[0].name
  name         = "json"
  service_name = module.anubis.service_name
  port         = module.anubis.service_port
  # Anubis binds its JWT to X-Real-Ip; the header must not reach it (flaps per
  # request across cloudflared pods for CF-tunneled traffic) — see ingress_factory.
  strip_x_real_ip   = true
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  tls_secret_name   = var.tls_secret_name
  anti_ai_scraping  = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "JSON Crack"
    "gethomepage.dev/description"  = "JSON visualizer"
    "gethomepage.dev/icon"         = "json.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z
