variable "tls_secret_name" {
  type      = string
  sensitive = true
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "tuya-bridge"
}

resource "kubernetes_namespace" "tuya-bridge" {
  metadata {
    name = "tuya-bridge"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.cluster
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.tuya-bridge.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "tuya-bridge" {
  metadata {
    name      = "tuya-bridge"
    namespace = kubernetes_namespace.tuya-bridge.metadata[0].name
    labels = {
      app  = "tuya-bridge"
      tier = local.tiers.cluster
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "tuya-bridge"
      }
    }
    template {
      metadata {
        labels = {
          app = "tuya-bridge"
        }
      }
      spec {
        container {
          image = "viktorbarzin/tuya_bridge:latest"
          name  = "tuya-bridge"
          port {
            container_port = 8080
          }
          env {
            name  = "TINYTUYA_API_KEY"
            value = data.vault_kv_secret_v2.secrets.data["api_key"]
          }
          env {
            name  = "TINYTUYA_API_SECRET"
            value = data.vault_kv_secret_v2.secrets.data["api_secret"]
          }
          env {
            name  = "SERVICE_API_KEY" # used for auth the API endpoint
            value = data.vault_kv_secret_v2.secrets.data["service_secret"]
          }
          env {
            name  = "SLACK_URL"
            value = data.vault_kv_secret_v2.secrets.data["slack_url"]
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "tuya-bridge" {
  metadata {
    name      = "tuya-bridge"
    namespace = kubernetes_namespace.tuya-bridge.metadata[0].name
    labels = {
      "app" = "tuya-bridge"
    }
  }

  spec {
    selector = {
      app = "tuya-bridge"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8080"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.tuya-bridge.metadata[0].name
  name            = "tuya-bridge"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Tuya Bridge"
    "gethomepage.dev/description"  = "Smart device bridge"
    "gethomepage.dev/icon"         = "mdi-home-automation"
    "gethomepage.dev/group"        = "Smart Home"
    "gethomepage.dev/pod-selector" = ""
  }
}
