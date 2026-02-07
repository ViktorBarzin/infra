variable "tls_secret_name" {}
variable "tier" { type = string }
variable "tiny_tuya_api_key" { type = string }
variable "tiny_tuya_api_secret" { type = string }
variable "tiny_tuya_service_secret" { type = string }
variable "slack_url" { type = string }

resource "kubernetes_namespace" "tuya-bridge" {
  metadata {
    name = "tuya-bridge"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.tuya-bridge.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "tuya-bridge" {
  metadata {
    name      = "tuya-bridge"
    namespace = kubernetes_namespace.tuya-bridge.metadata[0].name
    labels = {
      app  = "tuya-bridge"
      tier = var.tier
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
            value = var.tiny_tuya_api_key
          }
          env {
            name  = "TINYTUYA_API_SECRET"
            value = var.tiny_tuya_api_secret
          }
          env {
            name  = "SERVICE_API_KEY" # used for auth the API endpoint
            value = var.tiny_tuya_service_secret
          }
          env {
            name  = "SLACK_URL"
            value = var.slack_url
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.tuya-bridge.metadata[0].name
  name            = "tuya-bridge"
  tls_secret_name = var.tls_secret_name
}
