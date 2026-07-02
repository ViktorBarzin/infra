# =============================================================================
# portal-tts — edge-tts (CPU, always-on) for the portal-assistant Gateway
# =============================================================================
#
# WHAT: a single ALWAYS-ON openai-edge-tts deployment (travisvn/openai-edge-tts),
# an OpenAI-compatible /v1/audio/speech proxy over Microsoft edge-tts neural
# voices, serving Bulgarian (bg-BG-KalinaNeural) AND English (en-US-AvaNeural),
# the voice chosen PER REQUEST by the Gateway, behind a ClusterIP Service
# `portal-tts.portal-tts.svc:8000`. CPU-only — no GPU, no NFS model store.
#
# WHY edge-tts (REPLACED Piper / openedai-speech on 2026-06-17): the local Piper
# Bulgarian voice (bg_BG-dimitar-medium, espeak-ng phonemes) was garbled and
# unintelligible — espeak mangles Bulgarian consonants (a synth->Whisper
# round-trip turned "Добър ден" into "Обърден"; a user heard pure gibberish).
# ADR-0003 always named Microsoft edge-tts as the online Bulgarian-quality
# fallback; the operator chose it for BOTH languages (validated 2026-06-17: edge
# bg round-trips through Whisper verbatim — "Добър ден! Как сте днес? ..."). The
# assistant already depends on the internet for the Claude brain, so an online
# TTS adds no new failure mode. English moved to edge too (one engine, higher
# quality) — the previous local Piper English worked but is no longer needed.
#
# NO GPU, NO NFS, NO SECRETS: edge-tts fetches voices from Microsoft on demand
# (nothing to persist), so the NFS model PVC + download init-container + voice
# ConfigMap of the old Piper design are all gone. The container needs EGRESS to
# speech.platform.bing.com (verified reachable from this namespace). The Service
# is ClusterIP-only and the Gateway is the sole externally-exposed component
# (ADR-0001) holding the edge auth, so REQUIRE_API_KEY=False here (the Gateway's
# TTSClient sends no Authorization to TTS).
#
# API SHAPE (unchanged Gateway contract): OpenAI /v1/audio/speech
#   POST /v1/audio/speech
#   { "model":"tts-1", "input":"<text>", "voice":"<edge voice name>",
#     "response_format":"wav" }  -> 200, body = raw PCM16 wav bytes
# The Gateway maps detected lang bg/en -> TTS_VOICE_BG / TTS_VOICE_EN (the edge
# voice names, set on the gateway Deployment), and openai-edge-tts accepts edge
# voice names directly. The `-ffmpeg` image variant is REQUIRED for wav output
# (the base image only emits mp3; ffmpeg transcodes to PCM16 wav).
# =============================================================================

variable "edge_tts_image" {
  type = string
  # openai-edge-tts, the OpenAI-compatible edge-tts proxy. The `-ffmpeg` variant
  # bundles ffmpeg so response_format=wav (PCM16) works. Floating tag (no semver
  # discipline upstream) — the namespace is Keel-enrolled so digest bumps roll in
  # automatically; TF owns only the tag string.
  # docker.io/ prefix is REQUIRED: Kyverno require-trusted-registries blanket-
  # trusts docker.io/* but a bare `travisvn/...` is unenumerated → blocked.
  default     = "docker.io/travisvn/openai-edge-tts:latest-ffmpeg"
  description = "openai-edge-tts image (ffmpeg variant — needed for wav output)."
}

variable "bg_voice" {
  type        = string
  default     = "bg-BG-KalinaNeural"
  description = "Microsoft edge-tts neural Bulgarian voice (the Gateway's TTS_VOICE_BG must match)."
}

variable "en_voice" {
  type        = string
  default     = "en-US-AvaNeural"
  description = "Microsoft edge-tts neural English voice (the Gateway's TTS_VOICE_EN must match)."
}

locals {
  namespace = "portal-tts"
  labels    = { app = "portal-tts" }
}

resource "kubernetes_namespace" "portal_tts" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.aux # CPU-only best-effort helper, not a GPU tenant
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Always-on openai-edge-tts. replicas=1, never scaled to zero (no GPU to free,
# negligible idle cost — it's a thin proxy to Microsoft edge-tts). CPU-only: NO
# node_selector / toleration / nvidia.com/gpu. No init container and no volumes:
# voices are fetched from Microsoft per request, so the pod is stateless.
resource "kubernetes_deployment" "portal_tts" {
  metadata {
    name      = "portal-tts"
    namespace = kubernetes_namespace.portal_tts.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.aux })
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector {
      match_labels = { app = "portal-tts" }
    }
    template {
      metadata {
        labels = { app = "portal-tts" }
      }
      spec {
        container {
          name  = "portal-tts"
          image = var.edge_tts_image

          # openai-edge-tts listens on :5050 by default; the Service maps 8000 ->
          # 5050 so the Gateway's TTS_URL (:8000) is unchanged.
          port {
            container_port = 5050
            name           = "http"
          }
          # No API key: ClusterIP-only, the Gateway holds edge auth and sends no
          # Authorization header to TTS. DEFAULT_VOICE is a fallback only — every
          # request carries an explicit voice + response_format.
          env {
            name  = "REQUIRE_API_KEY"
            value = "False"
          }
          env {
            name  = "DEFAULT_VOICE"
            value = var.en_voice
          }

          # TCP probes — uvicorn binds :5050 only once the app is ready. No model
          # download, so startup is fast; egress to Microsoft happens per request.
          startup_probe {
            tcp_socket { port = 5050 }
            period_seconds    = 5
            failure_threshold = 24 # ~2 min
          }
          readiness_probe {
            tcp_socket { port = 5050 }
            period_seconds    = 15
            failure_threshold = 4
          }
          liveness_probe {
            tcp_socket { port = 5050 }
            initial_delay_seconds = 20
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            # Thin HTTP proxy to Microsoft edge-tts + ffmpeg transcode. Light on
            # CPU (no CPU limit — cluster CFS-throttling policy). VERIFY with krr
            # after real traffic and tighten.
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
      # Keel is enrolled (floating tag) — ignore its annotation churn but let the
      # tag string keep applying from TF.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

# ClusterIP — in-cluster only (the Gateway calls this; audio stays on the LAN
# until the Gateway speaks it to the Portal). No ingress, no Authentik: the
# Gateway is the only externally exposed component (ADR-0001). OpenAI speech path:
# http://portal-tts.portal-tts.svc.cluster.local:8000/v1/audio/speech
resource "kubernetes_service" "portal_tts" {
  metadata {
    name      = "portal-tts"
    namespace = kubernetes_namespace.portal_tts.metadata[0].name
    labels    = local.labels
    # No scrape annotations: openai-edge-tts exposes no Prometheus metrics, and
    # scraping a JSON endpoint (/v1/models) fails exposition parsing anyway ->
    # up=0 -> a permanently firing ScrapeTargetDown.
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "portal-tts" }
    port {
      name        = "http"
      port        = 8000
      target_port = 5050
    }
  }
}
