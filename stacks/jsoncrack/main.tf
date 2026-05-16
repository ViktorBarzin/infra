variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "jsoncrack" {
  metadata {
    name = "jsoncrack"
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
  source            = "../../modules/kubernetes/ingress_factory"
  auth              = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.jsoncrack.metadata[0].name
  name              = "json"
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
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
