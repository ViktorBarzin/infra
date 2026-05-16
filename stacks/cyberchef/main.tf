variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "cyberchef" {
  metadata {
    name = "cyberchef"
    labels = {
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
  namespace       = kubernetes_namespace.cyberchef.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "cyberchef" {
  metadata {
    name      = "cyberchef"
    namespace = kubernetes_namespace.cyberchef.metadata[0].name
    labels = {
      app  = "cyberchef"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "cyberchef"
      }
    }
    template {
      metadata {
        labels = {
          app = "cyberchef"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "mpepping/cyberchef:v9.55.0"
          name  = "cyberchef"

          port {
            container_port = 8000
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
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

resource "kubernetes_service" "cyberchef" {
  metadata {
    name      = "cc"
    namespace = kubernetes_namespace.cyberchef.metadata[0].name
    labels = {
      "app" = "cyberchef"
    }
  }

  spec {
    selector = {
      app = "cyberchef"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
    }
  }
}


module "anubis" {
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "cc"
  namespace        = kubernetes_namespace.cyberchef.metadata[0].name
  target_url       = "http://${kubernetes_service.cyberchef.metadata[0].name}.${kubernetes_namespace.cyberchef.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/5"
}

module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  auth              = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.cyberchef.metadata[0].name
  name              = "cc"
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  tls_secret_name   = var.tls_secret_name
  anti_ai_scraping  = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "CyberChef"
    "gethomepage.dev/description"  = "Data transformation toolkit"
    "gethomepage.dev/icon"         = "cyberchef.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
