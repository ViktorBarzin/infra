# =============================================================================
# portal-stt — Speaches STT (Whisper large-v3-turbo int8) for portal-assistant
# =============================================================================
#
# DRAFT for operator review (portal-assistant issue #2). HITL apply: an agent
# drafts; the operator applies via GitOps (presence-claimed) and verifies the
# rollout. Do NOT `terragrunt apply` this from a worktree.
#
# WHAT: a single WARM-RESIDENT Speaches deployment (OpenAI-compatible
# faster-whisper server) serving `large-v3-turbo` int8, multilingual (Bulgarian
# + English), on the shared Tesla T4 (one time-slice). ClusterIP only — audio
# never leaves the LAN; the portal-assistant Gateway is the only externally
# exposed component (ADR-0001), so no ingress/auth here.
#
# WHY WARM-RESIDENT, NOT THE CHATTERBOX DEMAND-GATE:
#   The TTS (chatterbox) stack scales 0<->1 behind a free-VRAM CronJob gate
#   because it is a best-effort BATCH tenant (tripit narration) that can wait.
#   STT here is INTERACTIVE voice — every Turn would pay a multi-second cold
#   model load (download/mmap + CUDA init) if we scaled to zero. So this stack
#   keeps the model permanently loaded: replicas=1 + Speaches STT_MODEL_TTL=-1
#   (never unload) + PRELOAD_MODELS (load at startup). See portal-assistant
#   CONTEXT.md "Warm window" + ADR-0003.
#
# OOM HISTORY / VRAM MATH — the binding constraint is the shared T4 (16 GiB,
# time-sliced across immich-ml / frigate / llama-swap / android-emulator with
# NO per-tenant VRAM isolation). See
# docs/post-mortems/2026-06-02-immich-ml-ttl-gpu-oom-recruiter.md (immich-ml's
# unbounded onnxruntime arena starved llama-swap's qwen3-8b -> recruiter down).
#
#   Live residents measured 2026-06-17 (gpu_pod_memory_used_bytes):
#     immich-ml        ~2.1 GiB  (capped: MACHINE_LEARNING_MODEL_TTL=600)
#     frigate (8 proc) ~1.9 GiB  (detector + ffmpeg decode)
#     android-emulator ~0.15 GiB
#     llama-swap        0 idle, but loads qwen3-8b on demand = ~4.35 GiB peak
#                       (cudaMalloc 4455 MiB, per the post-mortem)
#   Worst-case concurrent baseline (everything hot): 2.1 + 1.9 + 0.15 + 4.35
#                                                   = ~8.5 GiB.
#   Speaches large-v3-turbo int8 weights ~= 0.8 GiB on disk; resident CTranslate2
#   int8 + CUDA context + decode buffers budget conservatively to ~1.5 GiB
#   (VERIFY at apply against gpu_pod_memory_used_bytes{namespace="portal-stt"}).
#
#   8.5 (residents) + 1.5 (this) = ~10.0 GiB used  =>  ~6 GiB T4 headroom.
#   That headroom is the safety margin against onnxruntime arena drift (the
#   exact failure mode from 2026-06-02). If a future resident grows, this is the
#   FIRST place to re-measure. The conservative int8 (not fp16) choice halves
#   our weight footprint precisely to protect this margin.
#
# GPU PRIORITY: this pod requests nvidia.com/gpu, so the Kyverno
# `inject-gpu-workload-priority` ClusterPolicy auto-stamps the immich-equal
# `gpu-workload` (1,200,000) priority — portal-stt is NOT in that policy's
# exclude list (only `tts` is, to keep chatterbox demotable). That is CORRECT
# here: warm interactive STT is a first-class GPU resident, never the first
# evicted. We also set priority_class_name explicitly so intent is legible at
# the call site and survives a policy fail-open. (Contrast tts/main.tf, which
# pins tier-2-gpu precisely so chatterbox IS evicted first.)
# =============================================================================

variable "nfs_server" {
  type        = string
  description = "NFS server (Proxmox host). From config.tfvars (192.168.1.127)."
}

variable "speaches_image" {
  type = string
  # ghcr.io/speaches-ai/speaches CUDA build. The live registry currently
  # publishes 0.9.0-rc.3-cuda (+ sha-/cuda-12.x variants) and a moving
  # :latest-cuda; there is no published :0.8.3-cuda for the last stable. Pinned
  # to the rc.3 CUDA tag (immutable-ish, beats :latest for the OOM/Keel-churn
  # history). CUDA 12.4/12.6 image runtime is fine under our 570.195.03 driver
  # (CUDA 12.8, backward-compatible). OPEN ITEM for operator: confirm this tag
  # still resolves at apply, or bump to the newest -cuda tag.
  default     = "ghcr.io/speaches-ai/speaches:0.9.0-rc.3-cuda"
  description = "Speaches CUDA image. Pin a -cuda tag, not :latest-cuda."
}

variable "stt_model_id" {
  type = string
  # HF repo id of the CTranslate2 large-v3-turbo conversion. deepdml's is the
  # canonical community ct2 build of openai large-v3-turbo (multilingual,
  # incl. Bulgarian) and is what ADR-0003's FLEURS-bg bake-off measured at
  # 8.3% WER. Speaches resolves whisper models by HF repo id.
  default     = "deepdml/faster-whisper-large-v3-turbo-ct2"
  description = "HuggingFace repo id of the warm-resident whisper model."
}

locals {
  namespace = "portal-stt"
  labels    = { app = "portal-stt" }

  # Speaches is configured via env vars (pydantic-settings): scalars map from
  # UPPER_SNAKE, nested whisper.* settings from WHISPER__FIELD. The three knobs
  # that make this WARM-RESIDENT and int8:
  #   PRELOAD_MODELS          — JSON list, loaded sequentially at startup so the
  #                             first Turn is never cold (pod won't go Ready until
  #                             the model is in VRAM).
  #   STT_MODEL_TTL=-1        — never unload an idle STT model (0=immediate,
  #                             default 300s). This is the warm-resident lever.
  #   WHISPER__COMPUTE_TYPE   — int8 (conservative VRAM; default "default"=fp16).
  #   WHISPER__INFERENCE_DEVICE — cuda (default "auto").
  # HF cache is redirected onto the NFS-SSD PVC so weights download once and
  # persist across pod restarts (image default cache is /home/ubuntu/.cache/
  # huggingface/hub — ephemeral). Speaches runs as uid 1000 (ubuntu).
}

resource "kubernetes_namespace" "portal_stt" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.gpu
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# portal-stt is ClusterIP-only (no ingress) — the Gateway is the sole
# externally-exposed component (ADR-0001), so there is NO TLS secret / no
# setup_tls_secret module here (it would demand secrets/fullchain.pem that this
# stack does not ship).

# Model + HF cache on NFS-SSD (fast first-load, persists across restarts). Path
# /srv/nfs-ssd/portal-stt on the Proxmox host (192.168.1.127). Mirrors the
# chatterbox nfs_models pattern. RWX so a future seed/inspect pod can touch it.
module "nfs_models" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "portal-stt-models"
  namespace  = kubernetes_namespace.portal_stt.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs-ssd/portal-stt"
  storage    = "10Gi" # large-v3-turbo ct2 (~0.8Gi) + HF cache headroom
}

# One-shot bootstrap: /srv/nfs-ssd is exported whole-tree but the portal-stt
# SUBDIR must exist before kubelet can bind-mount it (chatterbox hit exit 32 on
# a missing subdir the first window — see stacks/tts/main.tf). Mount the export
# ROOT (which exists) and mkdir the subtree; kubelet's mount retry then heals
# the main pod. Idempotent; immutable-once-created.
resource "kubernetes_job" "models_dir_init" {
  metadata {
    name      = "portal-stt-models-dir-init"
    namespace = kubernetes_namespace.portal_stt.metadata[0].name
    labels    = local.labels
  }
  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 86400
    template {
      metadata { labels = local.labels }
      spec {
        restart_policy = "Never"
        container {
          name    = "mkdir"
          image   = "busybox:1.37"
          command = ["sh", "-c", "mkdir -p /mnt/portal-stt/hub && ls -la /mnt/portal-stt"]
          volume_mount {
            name       = "nfs-ssd-root"
            mount_path = "/mnt"
          }
        }
        volume {
          name = "nfs-ssd-root"
          nfs {
            server = var.nfs_server
            path   = "/srv/nfs-ssd"
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "3m" }
}

# Warm-resident Speaches. replicas=1, NEVER scaled to zero (no off-peak gate,
# unlike tts) — the model stays in VRAM so interactive Turns never pay a cold
# load. wait_for_rollout left default (true): a plain apply SHOULD block until
# the model is loaded and the pod is Ready, surfacing a bad image/model early.
resource "kubernetes_deployment" "portal_stt" {
  metadata {
    name      = "portal-stt"
    namespace = kubernetes_namespace.portal_stt.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.gpu })
  }
  spec {
    replicas = 1
    # RWO is not in play (model PVC is RWX NFS), but Recreate avoids two pods
    # briefly double-loading the model into the shared T4 during a rollout.
    strategy { type = "Recreate" }
    selector {
      match_labels = { app = "portal-stt" }
    }
    template {
      metadata {
        labels = { app = "portal-stt" }
      }
      spec {
        node_selector = { "nvidia.com/gpu.present" = "true" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        # First-class GPU resident (warm interactive STT) — same priority as
        # immich-ml. Kyverno would stamp this anyway (portal-stt is not in the
        # gpu-priority exclude list); set explicitly for legibility + fail-open
        # safety. NOT tier-2-gpu (that is chatterbox's evict-first demotion).
        priority_class_name = "gpu-workload"

        container {
          name  = "portal-stt"
          image = var.speaches_image

          # --- warm-resident + int8 + cuda config (see locals) ---
          env {
            name  = "PRELOAD_MODELS"
            value = jsonencode([var.stt_model_id])
          }
          env {
            name  = "STT_MODEL_TTL"
            value = "-1" # never unload — the warm-resident lever
          }
          env {
            name  = "WHISPER__INFERENCE_DEVICE"
            value = "cuda"
          }
          env {
            name  = "WHISPER__COMPUTE_TYPE"
            value = "int8" # conservative VRAM (vs fp16 default)
          }
          env {
            name  = "LOG_LEVEL"
            value = "info" # image default is debug
          }
          # Persist the HF model cache on the NFS-SSD PVC (image default cache
          # dir is ephemeral). Speaches/HF honour HF_HUB_CACHE + HF_HOME.
          env {
            name  = "HF_HUB_CACHE"
            value = "/data/hub"
          }
          env {
            name  = "HF_HOME"
            value = "/data"
          }

          port {
            container_port = 8000
            name           = "http"
          }

          volume_mount {
            name       = "models"
            mount_path = "/data"
          }

          # /health is Speaches' liveness/readiness path. Generous startup
          # allowance: the first boot downloads large-v3-turbo to the PVC before
          # the server reports healthy (PRELOAD blocks startup). After the model
          # is cached on NFS-SSD, subsequent boots load in seconds.
          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds    = 10
            failure_threshold = 60 # up to ~10 min for the first model download
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds    = 15
            failure_threshold = 4
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "2Gi"
            }
            limits = {
              memory           = "4Gi"
              "nvidia.com/gpu" = "1" # ONE time-slice (operator advertises 100), NOT the whole card
            }
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = module.nfs_models.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # image is TF-OWNED (pinned -cuda tag) — Keel can manage the digest on
      # this tag if desired, so ignore keel's annotation churn but NOT the image
      # itself (we want tag pins to apply). Mirrors tts: keel annotations only.
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

# ClusterIP — in-cluster only (the Gateway calls this; audio stays on the LAN).
# No ingress, no Authentik: the Gateway is the only externally exposed component
# (ADR-0001) and holds the edge auth. OpenAI transcription path is
# http://portal-stt.portal-stt.svc.cluster.local:8000/v1/audio/transcriptions
resource "kubernetes_service" "portal_stt" {
  metadata {
    name      = "portal-stt"
    namespace = kubernetes_namespace.portal_stt.metadata[0].name
    labels    = local.labels
    # No scrape annotations: the deployed Speaches build 404s /metrics, so the
    # annotation-based scrape only produced a permanently firing
    # ScrapeTargetDown. Re-add when the app actually serves Prometheus metrics.
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "portal-stt" }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
