variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "tuya-bridge" {
  metadata {
    name = "tuya-bridge"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tuya-bridge-secrets"
      namespace = "tuya-bridge"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tuya-bridge-secrets"
      }
      dataFrom = [{
        extract = {
          key = "tuya-bridge"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.tuya-bridge]
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
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
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
            name = "TINYTUYA_API_KEY"
            value_from {
              secret_key_ref {
                name = "tuya-bridge-secrets"
                key  = "api_key"
              }
            }
          }
          env {
            name = "TINYTUYA_API_SECRET"
            value_from {
              secret_key_ref {
                name = "tuya-bridge-secrets"
                key  = "api_secret"
              }
            }
          }
          env {
            name = "SERVICE_API_KEY" # used for auth the API endpoint
            value_from {
              secret_key_ref {
                name = "tuya-bridge-secrets"
                key  = "service_secret"
              }
            }
          }
          env {
            name = "SLACK_URL"
            value_from {
              secret_key_ref {
                name = "tuya-bridge-secrets"
                key  = "slack_url"
              }
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
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
  dns_type        = "proxied"
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
