# =============================================================================
# portal-assistant gateway — voice orchestrator (STT -> Brain -> TTS)
# =============================================================================
# The single service the Client app talks to: POST /v1/talk takes a WAV + a
# client id, runs Speaches STT -> the claude-agent-service conversational Brain
# -> Piper TTS, and returns the spoken reply. v1: ClusterIP only (E2E tested
# in-cluster). In-memory sessions (no SESSION_DB_DSN). See portal-assistant
# ADR-0001/0002/0003. Public Cloudflare ingress + device-token edge is the next
# increment.
# =============================================================================

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

data "vault_kv_secret_v2" "cas" {
  mount = "secret"
  name  = "claude-agent-service"
}

data "vault_kv_secret_v2" "pa" {
  mount = "secret"
  name  = "portal-assistant"
}

locals {
  namespace = "portal-assistant"
  labels    = { app = "portal-assistant-gateway" }
  image     = "ghcr.io/viktorbarzin/portal-assistant-gateway:latest"
}

resource "kubernetes_namespace" "portal_assistant" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.edge
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Pull secret — the gateway image is a PRIVATE ghcr package. Uses the read-only
# ghcr_pull_token (secret/viktor), the same cred the cluster-wide allowlist uses.
resource "kubernetes_secret" "ghcr" {
  metadata {
    name      = "ghcr-pull"
    namespace = kubernetes_namespace.portal_assistant.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = "viktorbarzin"
          password = data.vault_kv_secret_v2.viktor.data["ghcr_pull_token"]
          auth     = base64encode("viktorbarzin:${data.vault_kv_secret_v2.viktor.data["ghcr_pull_token"]}")
        }
      }
    })
  }
}

# Tokens the gateway needs: BRAIN_TOKEN = claude-agent-service's bearer (to call
# the conversational endpoint); DEVICE_TOKEN = the per-Client secret the Portal
# app carries to authenticate to /v1/talk.
resource "kubernetes_secret" "gateway" {
  metadata {
    name      = "portal-assistant-gateway-secrets"
    namespace = kubernetes_namespace.portal_assistant.metadata[0].name
  }
  data = {
    BRAIN_TOKEN  = data.vault_kv_secret_v2.cas.data["api_bearer_token"]
    DEVICE_TOKEN = data.vault_kv_secret_v2.pa.data["device_token"]
  }
}

resource "kubernetes_deployment" "gateway" {
  metadata {
    name      = "portal-assistant-gateway"
    namespace = kubernetes_namespace.portal_assistant.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.edge })
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "portal-assistant-gateway" }
    }
    template {
      metadata {
        labels = { app = "portal-assistant-gateway" }
      }
      spec {
        image_pull_secrets {
          name = kubernetes_secret.ghcr.metadata[0].name
        }
        container {
          name              = "gateway"
          image             = local.image
          image_pull_policy = "Always"
          port {
            container_port = 8000
            name           = "http"
          }
          # STT -> Speaches; TTS -> Piper; Brain -> claude-agent-service.
          env {
            name  = "STT_URL"
            value = "http://portal-stt.portal-stt.svc.cluster.local:8000"
          }
          env {
            name  = "STT_MODEL"
            value = "deepdml/faster-whisper-large-v3-turbo-ct2"
          }
          env {
            name  = "TTS_URL"
            value = "http://portal-tts.portal-tts.svc.cluster.local:8000"
          }
          env {
            name  = "BRAIN_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
          }
          env {
            name = "BRAIN_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gateway.metadata[0].name
                key  = "BRAIN_TOKEN"
              }
            }
          }
          env {
            name = "DEVICE_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gateway.metadata[0].name
                key  = "DEVICE_TOKEN"
              }
            }
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

# ClusterIP — the only externally-exposed component (ADR-0001) gets its public
# Cloudflare ingress in the next increment; here it's reachable in-cluster for
# the E2E smoke. /metrics scraped by Prometheus.
resource "kubernetes_service" "gateway" {
  metadata {
    name      = "portal-assistant-gateway"
    namespace = kubernetes_namespace.portal_assistant.metadata[0].name
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8000"
    }
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "portal-assistant-gateway" }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# Public Cloudflare ingress — the Portal app reaches the gateway at
# https://portal-assistant.viktorbarzin.me/v1/talk. tls-secret is Kyverno-synced
# into the namespace. The gateway holds its own edge auth (the DEVICE_TOKEN
# bearer), so no Authentik in front.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "portal-assistant"
  namespace       = kubernetes_namespace.portal_assistant.metadata[0].name
  service_name    = kubernetes_service.gateway.metadata[0].name
  port            = 8000
  tls_secret_name = "tls-secret"
  # auth = "app": the gateway enforces its own DEVICE_TOKEN bearer on /v1/talk; Authentik would break the native Portal client (it has no browser login).
  auth          = "app"
  dns_type      = "proxied"
  max_body_size = "25m" # audio (WAV) uploads
}
