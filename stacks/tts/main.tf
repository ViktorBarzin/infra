variable "image_tag" {
  type        = string
  default     = "latest"
  description = "chatterbox-tts image tag. Use the 8-char git SHA in CI; :latest for local trials."
}

# ─────────────────────────────────────────────────────────────────────────────
# Option-A off-peak control (see docs/plans/2026-06-08-chatterbox-tts-infra.md §3).
# The Deployment sits at replicas=0; a CronJob scales it to 1 at the window start
# ONLY IF a free-VRAM preflight passes, and another scales it back to 0 at window
# end. A guard CronJob yields the card mid-window if free VRAM drops below the
# floor (a resident woke up). tripit's bake is best-effort + idempotent, so a
# skipped/aborted window simply backfills on the next one (ADR-0002/0004).
# ─────────────────────────────────────────────────────────────────────────────

variable "vram_free_floor_bytes" {
  type = number
  # OPEN ITEM — must be measured (§5 smoke test / §3.X). This is the minimum free
  # VRAM the preflight requires before it will scale Chatterbox up, and the floor
  # the guard yields below. Default = 6 GiB ≈ (a conservative guess for
  # chatterbox-multilingual FP16 peak ~4 GiB + ~2 GiB headroom for the
  # read→cudaMalloc race). RAISE/LOWER once the real T4 peak is captured from
  # gpu_pod_memory_used_bytes{namespace="tts"} during a real synth.
  default     = 6442450944
  description = "Minimum free GPU VRAM (bytes) required before scaling Chatterbox up; guard yields below it."
}

variable "gpu_total_bytes" {
  type        = number
  default     = 17179869184 # Tesla T4 = 16 GiB
  description = "Total VRAM on the shared GPU. Free = this minus sum(gpu_pod_memory_used_bytes)."
}

variable "offpeak_window_up_schedule" {
  type        = string
  default     = "0 2 * * *" # 02:00 Europe/London (see timezone on the CronJob)
  description = "Cron schedule that fires the free-VRAM preflight + scale-up at window start."
}

variable "offpeak_window_down_schedule" {
  type        = string
  default     = "0 6 * * *" # 06:00 Europe/London
  description = "Cron schedule that scales Chatterbox back to 0 at window end."
}

variable "offpeak_guard_schedule" {
  type        = string
  default     = "*/5 2-5 * * *" # every 5 min inside the 02:00–06:00 window
  description = "Cron schedule for the mid-window guard that yields the card if free VRAM drops."
}

locals {
  namespace = "tts"
  labels    = { app = "chatterbox-tts" }
  image     = "forgejo.viktorbarzin.me/viktor/chatterbox-tts:${var.image_tag}"

  # config.yaml rendered into a ConfigMap, mounted at /app/config.yaml (the
  # server's WORKDIR is /app). Voices, reference audio and the HF model cache
  # all live on the NFS-SSD PVC (mounted at /data) so weights persist across
  # restarts and load fast. server.port stays at the devnen default 8004; the
  # Service remaps 8000->8004 so tripit's default TTS_BASE_URL works unchanged.
  #
  # model.repo_id = chatterbox-multilingual (ADR-0004; 23 languages for
  # worldwide place-names). If the measured T4 VRAM peak is too high to coexist
  # even off-peak, fall back to "chatterbox" (English, lighter) — a one-line
  # change here (§3.X / §6 decision 3).
  chatterbox_config = yamlencode({
    server = {
      host = "0.0.0.0"
      port = 8004
    }
    model = {
      repo_id = "chatterbox-multilingual"
    }
    tts_engine = {
      device                 = "cuda"
      predefined_voices_path = "/data/voices"
      reference_audio_path   = "/data/reference_audio"
    }
  })

  # Shared script for the off-peak CronJobs. Reads the in-cluster
  # gpu_pod_memory_used_bytes gauge (the per-namespace gauge the 2026-06-02
  # post-mortem built — host-PID attribution, no new exporter needed), sums it,
  # and computes free = GPU_TOTAL - used. Pure POSIX + awk; curl is baked into
  # the curl image. ACTION is "up" | "down" | "guard".
  #   up    — scale to 1 ONLY IF free >= FLOOR (positive admission).
  #   guard — scale to 0 IF free < FLOOR (a resident woke mid-window; yield).
  #   down  — scale to 0 unconditionally (window end).
  # Heredoc escaping: only `$${...}` (literal `${...}`) is escaped — Terraform
  # would otherwise try to interpolate it. Bare `$(...)`, `$((...))` and awk's
  # `$NF` are literal `$` and pass through unescaped.
  vram_gate_script = <<-EOT
    set -eu
    : "$${ACTION:?}" "$${FLOOR:?}" "$${GPU_TOTAL:?}"
    METRICS_URL="http://gpu-pod-exporter.nvidia.svc.cluster.local:80/metrics"

    # Sum gpu_pod_memory_used_bytes across all pods. Missing metric / empty
    # scrape => used=0 (card idle). -f so a non-200 scrape is a hard error we
    # treat conservatively (skip scale-up).
    if ! BODY="$(curl -sf -m 10 "$${METRICS_URL}")"; then
      echo "WARN: could not scrape $${METRICS_URL}"
      if [ "$${ACTION}" = "up" ]; then
        echo "preflight: scrape failed -> NOT scaling up (fail-safe)"; exit 0
      fi
      # For down/guard a failed scrape must NOT block yielding the card.
      BODY=""
    fi
    USED="$(printf '%s\n' "$${BODY}" \
      | awk '/^gpu_pod_memory_used_bytes\{/ { s += $NF } END { printf "%d", s }')"
    USED="$${USED:-0}"
    FREE="$(( GPU_TOTAL - USED ))"
    echo "GPU VRAM: used=$${USED} free=$${FREE} floor=$${FLOOR} (total=$${GPU_TOTAL})"

    case "$${ACTION}" in
      up)
        if [ "$${FREE}" -ge "$${FLOOR}" ]; then
          echo "preflight PASS: free >= floor -> scaling chatterbox-tts to 1"
          kubectl -n tts scale deploy/chatterbox-tts --replicas=1
        else
          echo "preflight SKIP: free < floor -> leaving chatterbox-tts at 0 (retry next window)"
        fi
        ;;
      guard)
        if [ "$${FREE}" -lt "$${FLOOR}" ]; then
          echo "guard TRIP: free < floor -> yielding the card, scaling chatterbox-tts to 0"
          kubectl -n tts scale deploy/chatterbox-tts --replicas=0
        else
          echo "guard OK: free >= floor -> chatterbox-tts may keep running"
        fi
        ;;
      down)
        echo "window end -> scaling chatterbox-tts to 0"
        kubectl -n tts scale deploy/chatterbox-tts --replicas=0
        ;;
    esac
  EOT

  # Common spec for the three off-peak CronJobs. Each runs one bitnami/kubectl
  # pod (in-cluster SA, no kubeconfig) executing the shared gate script with a
  # different ACTION. timezone pins the window to Europe/London regardless of
  # node TZ.
  offpeak_cronjobs = {
    chatterbox-window-up = {
      schedule = var.offpeak_window_up_schedule
      action   = "up"
    }
    chatterbox-window-down = {
      schedule = var.offpeak_window_down_schedule
      action   = "down"
    }
    chatterbox-vram-guard = {
      schedule = var.offpeak_guard_schedule
      action   = "guard"
    }
  }
}

resource "kubernetes_namespace" "tts" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.gpu
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Model weights + voices on NFS-SSD (fast load), RWX so a seed Job / kubectl cp
# can write the predefined voices + narrator reference WAV while the Deployment
# mounts it. Path /srv/nfs-ssd/chatterbox on the Proxmox host. Mirrors
# llama-cpp's nfs_models. First start downloads the model into /data/hf_cache
# (HF_HOME below), so weights persist across pod restarts.
module "nfs_models" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "chatterbox-models"
  namespace  = kubernetes_namespace.tts.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs-ssd/chatterbox"
  storage    = "20Gi" # multilingual weights + HF cache + voices headroom
}

resource "kubernetes_config_map" "chatterbox_config" {
  metadata {
    name      = "chatterbox-config"
    namespace = kubernetes_namespace.tts.metadata[0].name
    labels    = local.labels
  }
  data = {
    "config.yaml" = local.chatterbox_config
  }
}

# Single Deployment running the devnen Chatterbox-TTS-Server (OpenAI-compatible
# /v1/audio/speech). Sits at replicas=0 — the off-peak CronJobs below scale it
# to 1 only when the free-VRAM preflight passes (Option A), and back to 0 at
# window end. wait_for_rollout=false so apply never blocks on a pod that is
# intentionally scaled to 0.
resource "kubernetes_deployment" "chatterbox" {
  metadata {
    name      = "chatterbox-tts"
    namespace = kubernetes_namespace.tts.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.gpu })
  }
  wait_for_rollout = false
  spec {
    # Off-peak control owns the replica count at runtime (CronJobs scale 0<->1).
    # Declare 0 here so a plain `tg apply` outside the window doesn't wake the
    # card. ignore_changes on replicas (below) stops apply from fighting the
    # CronJob's scale.
    replicas = 0
    strategy { type = "Recreate" }
    selector {
      match_labels = { app = "chatterbox-tts" }
    }
    template {
      metadata {
        labels = { app = "chatterbox-tts" }
        annotations = {
          "checksum/config" = sha256(local.chatterbox_config)
        }
      }
      spec {
        node_selector = { "nvidia.com/gpu.present" = "true" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        # C-hardening (§3.RECOMMENDATION.3): Chatterbox is a polite, best-effort
        # batch tenant — give it the regular tier-2-gpu priority (600000) so it
        # is ALWAYS the pod evicted under GPU-node pressure, never immich-ml /
        # frigate / llama-swap. This relies on the `tts` namespace being EXCLUDED
        # from the Kyverno `inject-gpu-workload-priority` policy (which would
        # otherwise stamp the immich-equal gpu-workload=1,200,000 priority on any
        # nvidia.com/gpu pod). That exclusion is the two-line edit to the kyverno
        # stack flagged in the PR. Without it, this priority_class_name is
        # overwritten on pod CREATE and Chatterbox would compete as an equal.
        priority_class_name = "tier-2-gpu"

        image_pull_secrets { name = "registry-credentials" }

        container {
          name  = "chatterbox-tts"
          image = local.image
          port {
            container_port = 8004
            name           = "http"
          }

          # T4 is Turing — NO bf16 (ADR-0004). Pin off; run FP16/FP32.
          env {
            name  = "TTS_BF16"
            value = "off"
          }
          # Park the HuggingFace cache on the NFS-SSD PVC so model weights
          # download once and persist across pod restarts (the pod is recreated
          # every window). The devnen compose mounts HF cache at /app/hf_cache;
          # point HF_HOME at the PVC instead.
          env {
            name  = "HF_HOME"
            value = "/data/hf_cache"
          }
          env {
            name  = "HF_HUB_CACHE"
            value = "/data/hf_cache"
          }

          volume_mount {
            name       = "config"
            mount_path = "/app/config.yaml"
            sub_path   = "config.yaml"
          }
          volume_mount {
            name       = "models"
            mount_path = "/data"
          }

          # /v1/audio/voices is cheap and only 200s once the model is loaded —
          # so it gates real readiness. First start downloads the model, which
          # is slow; the generous failure_threshold absorbs that.
          readiness_probe {
            http_get {
              path = "/v1/audio/voices"
              port = 8004
            }
            initial_delay_seconds = 20
            period_seconds        = 15
            failure_threshold     = 12
          }
          liveness_probe {
            http_get {
              path = "/v1/audio/voices"
              port = 8004
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            failure_threshold     = 5
          }
          resources {
            requests = {
              cpu    = "200m"
              memory = "2Gi"
            }
            limits = {
              memory           = "8Gi"
              "nvidia.com/gpu" = "1" # ONE time-slice (operator advertises 100), NOT the whole card
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.chatterbox_config.metadata[0].name
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
      # Off-peak CronJobs own the replica count — don't let apply reset it.
      spec[0].replicas,
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }
}

resource "kubernetes_service" "chatterbox" {
  metadata {
    name      = "chatterbox-tts"
    namespace = kubernetes_namespace.tts.metadata[0].name
    labels    = local.labels
    annotations = {
      # Prometheus annotation-based scrape (mirrors tripit). The devnen server
      # has no /metrics; this monitors liveness via the blackbox path and keeps
      # the Service in the scrape set if a /metrics endpoint is added later.
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/v1/audio/voices"
      "prometheus.io/port"   = "8000"
    }
  }
  spec {
    type     = "ClusterIP" # in-cluster only — never ingressed (no token needed)
    selector = { app = "chatterbox-tts" }
    port {
      name        = "http"
      port        = 8000 # tripit's default TTS_BASE_URL port
      target_port = 8004 # the devnen server's actual listen port
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Option-A off-peak control: SA + Role (scale the Deployment) + RoleBinding +
# three CronJobs (window-up preflight, mid-window guard, window-down). Mirrors
# the nextcloud-watchdog in-cluster-kubectl pattern (SA → Role → bitnami/kubectl
# CronJob, no kubeconfig).
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_service_account" "offpeak" {
  metadata {
    name      = "chatterbox-offpeak"
    namespace = kubernetes_namespace.tts.metadata[0].name
  }
}

resource "kubernetes_role" "offpeak" {
  metadata {
    name      = "chatterbox-offpeak"
    namespace = kubernetes_namespace.tts.metadata[0].name
  }
  # get + patch on the deployment scale subresource is all the gate needs.
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "deployments/scale"]
    verbs      = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "offpeak" {
  metadata {
    name      = "chatterbox-offpeak"
    namespace = kubernetes_namespace.tts.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.offpeak.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.offpeak.metadata[0].name
    namespace = kubernetes_namespace.tts.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "offpeak" {
  for_each = local.offpeak_cronjobs

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.tts.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = each.value.schedule
    timezone                      = "Europe/London"
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 120
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata { labels = local.labels }
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 120
        ttl_seconds_after_finished = 300
        template {
          metadata { labels = local.labels }
          spec {
            service_account_name = kubernetes_service_account.offpeak.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "vram-gate"
              image   = "bitnami/kubectl:latest"
              command = ["/bin/bash", "-c", local.vram_gate_script]
              env {
                name  = "ACTION"
                value = each.value.action
              }
              env {
                name  = "FLOOR"
                value = tostring(var.vram_free_floor_bytes)
              }
              env {
                name  = "GPU_TOTAL"
                value = tostring(var.gpu_total_bytes)
              }
              resources {
                requests = { cpu = "20m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno mutates dns_config with ndots=2 on CronJobs.
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
