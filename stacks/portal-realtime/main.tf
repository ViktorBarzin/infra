# =============================================================================
# portal-realtime — full-duplex voice agent (Pipecat) over a WebSocket
# =============================================================================
# v2 of the portal-assistant brain path. Instead of the v1 tap-to-talk
# request/response gateway, this is a persistent conversation: the Portal opens
# ONE WebSocket (/ws) and streams raw PCM16 mic audio continuously; the Pipecat
# pipeline does Silero VAD turn-taking -> Whisper STT (portal-stt) -> streaming
# Claude brain (claude-agent-service /v1/chat/completions) -> edge-tts
# (portal-tts) -> audio out, with barge-in. All three upstreams are REUSED
# cluster services (nothing new spun up); the brain streams token-by-token over
# the free CLI/subscription (no API key). Bilingual bg/en: the TTS voice follows
# the reply's script.
#
# EXPOSURE: a single public Cloudflare ingress (proxied, WebSocket) at
# wss://portal-realtime.viktorbarzin.me/ws. The agent enforces its own edge auth
# (the DEVICE_TOKEN the Portal carries as ?token=), so auth="app" — Authentik
# would break the native Portal client (no browser login). NO buffering
# middleware (max_body_size unset): Traefik's Buffering middleware would break
# the streaming WebSocket.
#
# IMAGE: ghcr.io/viktorbarzin/portal-assistant-realtime (PRIVATE ghcr package,
# pulled with the read-only ghcr_pull_token). Built from the portal-assistant
# repo's realtime/ dir. :latest + Keel auto-roll (namespace is keel-enrolled).
# =============================================================================

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

data "vault_kv_secret_v2" "cas" {
  mount = "secret"
  name  = "claude-agent-service"
}

# Reuse the portal-assistant device token — same physical Portal device, same
# edge secret; no need for a separate credential.
data "vault_kv_secret_v2" "pa" {
  mount = "secret"
  name  = "portal-assistant"
}

locals {
  namespace = "portal-realtime"
  labels    = { app = "portal-realtime" }
  image     = "ghcr.io/viktorbarzin/portal-assistant-realtime:latest"
}

resource "kubernetes_namespace" "portal_realtime" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.edge
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Pull secret — the realtime image is a PRIVATE ghcr package. Uses the read-only
# ghcr_pull_token (secret/viktor), same cred the cluster-wide allowlist uses.
resource "kubernetes_secret" "ghcr" {
  metadata {
    name      = "ghcr-pull"
    namespace = kubernetes_namespace.portal_realtime.metadata[0].name
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

# Tokens: BRAIN_TOKEN = claude-agent-service's bearer (to call the streaming
# conversational endpoint); DEVICE_TOKEN = the per-Portal secret the app carries
# as ?token= on the WebSocket, which the agent verifies before accepting.
resource "kubernetes_secret" "realtime" {
  metadata {
    name      = "portal-realtime-secrets"
    namespace = kubernetes_namespace.portal_realtime.metadata[0].name
  }
  data = {
    BRAIN_TOKEN  = data.vault_kv_secret_v2.cas.data["api_bearer_token"]
    DEVICE_TOKEN = data.vault_kv_secret_v2.pa.data["device_token"]
  }
}

resource "kubernetes_deployment" "realtime" {
  metadata {
    name      = "portal-realtime"
    namespace = kubernetes_namespace.portal_realtime.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.edge })
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "portal-realtime" }
    }
    template {
      metadata {
        labels = { app = "portal-realtime" }
      }
      spec {
        image_pull_secrets {
          name = kubernetes_secret.ghcr.metadata[0].name
        }
        container {
          name              = "realtime"
          image             = local.image
          image_pull_policy = "Always"
          port {
            container_port = 8000
            name           = "http"
          }

          # STT/Brain/TTS base URLs carry the /v1 suffix: the agent's OpenAI-SDK
          # clients append /audio/transcriptions, /chat/completions, /audio/speech.
          env {
            name  = "STT_URL"
            value = "http://portal-stt.portal-stt.svc.cluster.local:8000/v1"
          }
          env {
            name  = "STT_MODEL"
            value = "deepdml/faster-whisper-large-v3-turbo-ct2"
          }
          env {
            name  = "BRAIN_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080/v1"
          }
          env {
            name  = "BRAIN_MODEL"
            value = "sonnet" # latency over smartness for live conversation
          }
          env {
            name  = "TTS_URL"
            value = "http://portal-tts.portal-tts.svc.cluster.local:8000/v1"
          }
          # edge-tts neural voices; the agent switches per reply script (bg/en).
          env {
            name  = "TTS_VOICE_BG"
            value = "bg-BG-KalinaNeural"
          }
          env {
            name  = "TTS_VOICE_EN"
            value = "en-US-AvaNeural"
          }
          env {
            name = "BRAIN_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.realtime.metadata[0].name
                key  = "BRAIN_TOKEN"
              }
            }
          }
          env {
            name = "DEVICE_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.realtime.metadata[0].name
                key  = "DEVICE_TOKEN"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 20
            period_seconds        = 30
          }

          resources {
            # Pipecat + onnxruntime (Silero VAD) per live connection. No CPU
            # limit (cluster CFS-throttling policy) — request only. Burstable
            # memory (tier-edge). VERIFY with krr after real traffic.
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel rolls :latest; don't let TF revert the digest
    ]
  }
}

# ClusterIP — fronted by the ingress below. No /metrics endpoint on the agent;
# kept out of the annotation scrape set (Pipecat metrics are internal only).
resource "kubernetes_service" "realtime" {
  metadata {
    name      = "portal-realtime"
    namespace = kubernetes_namespace.portal_realtime.metadata[0].name
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "portal-realtime" }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# Public Cloudflare ingress — wss://portal-realtime.viktorbarzin.me/ws. Traefik
# upgrades WebSocket on the standard HTTP router (no special annotation needed);
# the entrypoint writeTimeout=0 keeps long-lived streams open. tls-secret is
# Kyverno-synced into the namespace. NO max_body_size: a Buffering middleware
# would break the streaming WebSocket.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  name   = "portal-realtime"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  namespace        = kubernetes_namespace.portal_realtime.metadata[0].name
  service_name     = kubernetes_service.realtime.metadata[0].name
  port             = 8000
  tls_secret_name  = "tls-secret"
  # auth = "app": the agent enforces its own DEVICE_TOKEN edge gate on /ws;
  # Authentik would break the native Portal client (it has no browser login).
  auth     = "app"
  dns_type = "proxied"
}
