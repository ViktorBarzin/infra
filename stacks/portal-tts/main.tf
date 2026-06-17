# =============================================================================
# portal-tts — Piper TTS (CPU, always-on) for the portal-assistant Gateway
# =============================================================================
#
# DRAFT for operator review (portal-assistant issue #3). HITL apply: an agent
# drafts; the operator applies via GitOps and verifies the rollout. Do NOT
# `terragrunt apply` this from a worktree.
#
# WHAT: a single ALWAYS-ON Piper deployment serving Bulgarian
# (`bg_BG-dimitar-medium`) AND English (`en_US-lessac-medium`), with the voice
# chosen PER REQUEST, behind a ClusterIP Service `portal-tts.portal-tts.svc:8000`.
# CPU-ONLY — no GPU node selector / toleration / nvidia.com/gpu request (Piper
# is a fast CPU neural TTS; ADR-0003). Audio never leaves the LAN; the
# portal-assistant Gateway is the only externally exposed component (ADR-0001),
# so there is no ingress / Authentik here.
#
# WHY CPU + ALWAYS-ON (contrast the two GPU siblings):
#   * tts/ (chatterbox) scales 0<->1 behind a free-VRAM CronJob gate — it is a
#     best-effort BATCH tenant on the shared T4.
#   * portal-stt/ (Speaches) is warm-resident on ONE T4 slice — interactive STT
#     that must not pay a cold model load.
#   Piper needs neither: it runs in real time on CPU (no GPU contention at all),
#   so the simplest correct design is replicas=1, always up. Keeping it off the
#   T4 also REMOVES one tenant from the OOM-prone shared card
#   (docs/post-mortems/2026-06-02-immich-ml-ttl-gpu-oom-recruiter.md) — Bulgarian
#   isn't on chatterbox anyway (its 23 langs exclude bg; ADR-0003).
#
# API SHAPE (the Gateway team's contract): openedai-speech is OpenAI-compatible.
#   POST /v1/audio/speech
#   Content-Type: application/json
#   { "model": "tts-1", "input": "<text>", "voice": "<bg|en>",
#     "response_format": "wav", "speed": 1.0 }
#   -> 200, body = raw audio bytes (wav/mp3/opus/flac/aac/pcm per response_format)
#   This matches the Gateway's tts.synthesize(text, lang) -> bytes interface
#   (portal-assistant gateway/app/pipeline.py): map lang "bg"->voice "bg",
#   anything else -> "en". Same OpenAI shape chatterbox already uses, so the
#   Gateway can treat Piper and the edge-tts fallback identically.
#
# PLUGGABLE FALLBACK (noted, NOT built here — a Gateway-side concern): ADR-0003
# keeps TTS a swappable backend with Microsoft edge-tts as an online
# Bulgarian-quality fallback. The Gateway selects Piper (this Service, on-LAN
# default) vs edge-tts (cloud) per its own config; nothing in THIS stack needs
# to change to add edge-tts. If a second in-cluster engine is ever wanted,
# add a sibling Deployment+Service and let the Gateway choose.
#
# IMAGE CHOICE (OPEN ITEM — operator please confirm before apply):
#   Primary: ghcr.io/matatonic/openedai-speech-min — the CPU-only, piper-only
#   (~1 GiB) variant of openedai-speech. OpenAI /v1/audio/speech, multi-voice via
#   a voice_to_speaker.yaml map, returns raw audio bytes. Pre-built for
#   linux/amd64+arm64, pullable from ghcr (tags: latest, 0.18.2, 0.18.1, ...).
#   CAVEAT: the upstream repo was ARCHIVED 2026-01-04 (read-only, no further
#   updates / security patches). It is feature-complete and stable for this use,
#   but pinned (not Keel-tracked) precisely because it is frozen upstream.
#   Alternative if a maintained image is preferred: arkdevuk/Webpiper (FastAPI,
#   actively developed) — but it returns JSON {url} requiring a SECOND fetch to
#   retrieve the wav, a worse fit for the Gateway's bytes contract; it would
#   need a small Gateway adapter. The rhasspy/wyoming-piper HTTP server is NOT
#   suitable: it loads ONE voice per process (no per-request voice switch).
# =============================================================================

variable "nfs_server" {
  type        = string
  description = "NFS server (Proxmox host). From config.tfvars (192.168.1.127)."
}

variable "piper_image" {
  type = string
  # CPU-only piper-only openedai-speech. Pinned to 0.18.2 (the newest published
  # tag; repo archived 2026-01-04 so this is effectively the final release) for
  # reproducibility — NOT :latest, which would also drift to the same frozen
  # build but loses the explicit version record. linux/amd64 confirmed.
  default     = "ghcr.io/matatonic/openedai-speech-min:0.18.2"
  description = "openedai-speech CPU/piper-only image. See IMAGE CHOICE note in main.tf."
}

variable "bg_voice" {
  type = string
  # The single Bulgarian Piper voice (rhasspy/piper-voices). ADR-0003 names this
  # exact model; it was reviewed against edge-tts in the M0.2 bake-off.
  default     = "bg_BG-dimitar-medium"
  description = "Bulgarian Piper voice model stem (rhasspy/piper-voices)."
}

variable "en_voice" {
  type = string
  # English Piper voice. lessac-medium is the canonical balanced en_US voice
  # (the upstream openedai-speech default-quality pick). Swappable to any
  # rhasspy/piper-voices en stem (e.g. en_US-amy-medium, en_GB-alba-medium).
  default     = "en_US-lessac-medium"
  description = "English Piper voice model stem (rhasspy/piper-voices)."
}

locals {
  namespace = "portal-tts"
  labels    = { app = "portal-tts" }

  # rhasspy/piper-voices HuggingFace layout:
  #   resolve/main/<lang>/<locale>/<name>/<quality>/<locale>-<name>-<quality>.onnx
  # Each voice needs BOTH the .onnx and the matching .onnx.json (Piper reads the
  # sample rate / phoneme map from the .json next to the model). All 4 URLs were
  # HEAD-verified 200 on 2026-06-17. Derived from the voice stems so changing a
  # voice variable updates both the download URL and the config map together.
  hf_base = "https://huggingface.co/rhasspy/piper-voices/resolve/main"
  voice_models = {
    # voice stem => HF directory path "<lang>/<locale>/<name>/<quality>"
    (var.bg_voice) = "bg/bg_BG/dimitar/medium"
    (var.en_voice) = "en/en_US/lessac/medium"
  }

  # voice_to_speaker.yaml: the openedai-speech config that maps a REQUEST voice
  # name ("bg" / "en") to a Piper .onnx on the PVC. The Gateway sends
  # voice="bg" or "en"; the server resolves it here. (We expose short logical
  # names, not the long model stems, so the Gateway's lang->voice map is trivial
  # and stable even if the underlying model stem changes.) The default model
  # name is "tts-1" (openedai-speech's piper model id).
  voice_to_speaker = yamlencode({
    "tts-1" = {
      bg = {
        model   = "voices/${var.bg_voice}.onnx"
        speaker = null # single-speaker model -> default
      }
      en = {
        model   = "voices/${var.en_voice}.onnx"
        speaker = null
      }
    }
  })

  # Init-container provisioning script. Downloads each voice's .onnx + .onnx.json
  # into the PVC's voices/ dir IF MISSING (idempotent — re-runs skip
  # already-present files), then copies the config map's voice_to_speaker.yaml
  # into the PVC's config/ dir. Pure POSIX + wget (busybox has wget).
  download_script = <<-EOT
    set -eu
    mkdir -p /data/voices /data/config
    fetch() { # $1 = url, $2 = dest
      if [ -s "$2" ]; then echo "have $2"; return 0; fi
      echo "get $1 -> $2"
      wget -q -O "$2.tmp" "$1"
      mv "$2.tmp" "$2"
    }
    %{for stem, dir in local.voice_models~}
    fetch "${local.hf_base}/${dir}/${stem}.onnx"      "/data/voices/${stem}.onnx"
    fetch "${local.hf_base}/${dir}/${stem}.onnx.json" "/data/voices/${stem}.onnx.json"
    %{endfor~}
    cp /config-src/voice_to_speaker.yaml /data/config/voice_to_speaker.yaml
    echo "voices:"; ls -la /data/voices
    echo "config:"; cat /data/config/voice_to_speaker.yaml
  EOT
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

# Voice models + config on NFS-SSD: fast first-load, persists across restarts,
# and RWX so a future seed/inspect pod can touch it. Path /srv/nfs-ssd/portal-tts
# on the Proxmox host. Small — two medium Piper voices are ~60-120 MiB each.
# Mirrors portal-stt's nfs_models pattern.
module "nfs_models" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "portal-tts-models"
  namespace  = kubernetes_namespace.portal_tts.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs-ssd/portal-tts"
  storage    = "2Gi" # 2 medium Piper voices + headroom for more
}

# One-shot bootstrap: /srv/nfs-ssd is exported whole-tree but the portal-tts
# SUBDIR must exist before kubelet can bind-mount it (chatterbox/portal-stt both
# hit exit 32 on a missing subdir). Mount the export ROOT (which exists) and
# mkdir the subtree; kubelet's mount retry then heals the main pod. Idempotent;
# immutable-once-created.
resource "kubernetes_job" "models_dir_init" {
  metadata {
    name      = "portal-tts-models-dir-init"
    namespace = kubernetes_namespace.portal_tts.metadata[0].name
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
          command = ["sh", "-c", "mkdir -p /mnt/portal-tts/voices /mnt/portal-tts/config && ls -la /mnt/portal-tts"]
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

# The voice_to_speaker.yaml map, mounted into the init container which copies it
# onto the PVC (openedai-speech reads config from a writable dir). Checksum drives
# a rollout when the voice map changes.
resource "kubernetes_config_map" "voices" {
  metadata {
    name      = "portal-tts-voices"
    namespace = kubernetes_namespace.portal_tts.metadata[0].name
    labels    = local.labels
  }
  data = {
    "voice_to_speaker.yaml" = local.voice_to_speaker
  }
}

# Always-on Piper. replicas=1, never scaled to zero (no off-peak gate). CPU-only:
# NO node_selector / toleration / nvidia.com/gpu — it runs on any worker. The
# init container downloads the voices to the PVC and seeds the config before the
# server starts; openedai-speech then serves both voices, selectable per request.
resource "kubernetes_deployment" "portal_tts" {
  metadata {
    name      = "portal-tts"
    namespace = kubernetes_namespace.portal_tts.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.aux })
  }
  # wait_for_rollout left default (true): a plain apply SHOULD block until the
  # voices download + the server reports healthy, surfacing a bad image/voice
  # early. First boot pulls ~2 voices from HuggingFace onto the PVC.
  spec {
    replicas = 1
    # NFS PVC is RWX so RollingUpdate would be safe, but Recreate keeps it simple
    # and avoids two pods racing the same voices/ dir on first download.
    strategy { type = "Recreate" }
    selector {
      match_labels = { app = "portal-tts" }
    }
    template {
      metadata {
        labels = { app = "portal-tts" }
        annotations = {
          "checksum/voices" = sha256(local.voice_to_speaker)
        }
      }
      spec {
        # Download voices + seed config onto the PVC before the server starts.
        init_container {
          name    = "fetch-voices"
          image   = "busybox:1.37"
          command = ["sh", "-c", local.download_script]
          volume_mount {
            name       = "models"
            mount_path = "/data"
          }
          volume_mount {
            name       = "config-src"
            mount_path = "/config-src"
          }
          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        container {
          name  = "portal-tts"
          image = var.piper_image

          # openedai-speech serves /v1/audio/speech on :8000. It reads
          # config/voice_to_speaker.yaml and voices/*.onnx relative to its
          # workdir (/app); we mount the PVC at /app/voices and /app/config so
          # the init-seeded files are found.
          port {
            container_port = 8000
            name           = "http"
          }
          env {
            name  = "OPENEDAI_LOG_LEVEL"
            value = "INFO" # image default is INFO; explicit for legibility
          }

          volume_mount {
            name       = "models"
            mount_path = "/app/voices"
            sub_path   = "voices"
          }
          volume_mount {
            name       = "models"
            mount_path = "/app/config"
            sub_path   = "config"
          }

          # openedai-speech has no /health on its OpenAI surface. Use a TCP probe
          # — the uvicorn socket binds only after the app (and the piper voices
          # index) is ready. The init container already downloaded the voices, so
          # process start is fast.
          startup_probe {
            tcp_socket { port = 8000 }
            period_seconds    = 5
            failure_threshold = 24 # ~2 min
          }
          readiness_probe {
            tcp_socket { port = 8000 }
            period_seconds    = 15
            failure_threshold = 4
          }
          liveness_probe {
            tcp_socket { port = 8000 }
            initial_delay_seconds = 20
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            # Piper is light on CPU. No CPU limit (cluster policy: CFS throttling
            # avoided). Memory sized for the python runtime + 2 loaded onnx voices
            # (each medium model ~60-120 MiB + onnxruntime arena). VERIFY with krr
            # after a few days of real traffic and tighten.
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = module.nfs_models.claim_name
          }
        }
        volume {
          name = "config-src"
          config_map {
            name = kubernetes_config_map.voices.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # image is TF-OWNED (pinned tag on a FROZEN upstream) — do NOT let Keel
      # churn it. Ignore keel's annotation noise but keep the image pin applying.
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
# (ADR-0001) and holds the edge auth. OpenAI speech path:
# http://portal-tts.portal-tts.svc.cluster.local:8000/v1/audio/speech
resource "kubernetes_service" "portal_tts" {
  metadata {
    name      = "portal-tts"
    namespace = kubernetes_namespace.portal_tts.metadata[0].name
    labels    = local.labels
    annotations = {
      # openedai-speech has no /metrics endpoint; annotation-based scrape kept on
      # a liveness path so the Service stays in the scrape set (Ready-endpoint
      # relabeling filters non-Ready pods). Probes the OpenAI models list.
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/v1/models"
      "prometheus.io/port"   = "8000"
    }
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "portal-tts" }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
