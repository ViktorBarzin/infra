locals {
  namespace = "llama-cpp"
  labels    = { app = "llama-cpp" }

  # llama-swap fronts per-model llama.cpp instances. The :cuda image
  # ships a recent llama-server inside, which is what gets spawned per
  # model. One Service, one /v1 endpoint, model selected by the
  # OpenAI `model` field. mostlygeek/llama-swap is production-grade
  # (3.9k★, v211, May 2026).
  llamaswap_image = "ghcr.io/mostlygeek/llama-swap:cuda"

  # Model set: two vision VLMs (qwen3vl-8b/4b) + one text-only LLM (qwen3-8b).
  # All Apache-2.0, GGUF Q4_K_M (T4 has no FP8/BF16 — INT4 is the right knob).
  # Image long-edge capped at 1024 px to keep prefill <2s on the T4.
  # 2026-07-16 cleanup/eval (docs/research/2026-07-16-local-llm-sota-and-upgrade.md):
  # dropped unused minicpm-v-4.5. Three text-model upgrades were evaluated
  # ON-CARD and ALL REJECTED, so qwen3-8b (33 tok/s, f16 KV) stays as the best
  # text model this hardware supports today:
  #   - q8_0 KV cache: ~40-70x slower generation on Turing (no quantized-KV
  #     fused FA kernel on SM7.5). Reverted.
  #   - qwen3.5-9b: ~0.5 tok/s generation (qwen3_5 arch has no performant CUDA
  #     path on SM7.5 in b9879). Removed.
  #   - gemma-4 12b + e4b: 12b too big for the contended T4; e4b was fast + small
  #     but weaker on enrichment (mislabeled correspondent) + wraps JSON in
  #     ```fences. Removed. No available model beat qwen3-8b here.
  #
  # Filenames are matched by glob in the download Job (huggingface_hub
  # snapshot_download with allow_patterns). Stable symlinks model.gguf /
  # mmproj.gguf are created after download so llama-swap config can be
  # filename-agnostic.
  # `text_only = true` skips mmproj download + --mmproj flag (text-only LLM).
  # Vision models keep `text_only = false` (default).
  models = {
    qwen3vl-8b = {
      hf_repo        = "Qwen/Qwen3-VL-8B-Instruct-GGUF"
      gguf_pattern   = "*Q4_K_M*.gguf"
      mmproj_pattern = "*mmproj*.gguf"
      ctx_size       = 3072
      gpu_layers     = 99
      text_only      = false
    }
    qwen3vl-4b = {
      hf_repo        = "Qwen/Qwen3-VL-4B-Instruct-GGUF"
      gguf_pattern   = "*Q4_K_M*.gguf"
      mmproj_pattern = "*mmproj*.gguf"
      ctx_size       = 3072
      gpu_layers     = 99
      text_only      = false
    }
    # Text-only triage / drafting model for recruiter-responder.
    # Q4_K_M, ~4.7GB, 32k native context (capped at 16k here — plenty
    # for recruiter emails + extraction prompt + JSON output).
    # Unsloth's GGUF: well-maintained, includes Q4_K_M. Qwen3 is a
    # thinking-capable model; thinking is force-disabled server-side for
    # qwen3-8b via `--reasoning off` in the cmd builder below (2026-07-13 — see
    # that comment). recruiter-responder also sends enable_thinking=false
    # per-request; the server flag makes it the default for all consumers.
    qwen3-8b = {
      hf_repo        = "unsloth/Qwen3-8B-GGUF"
      gguf_pattern   = "*Q4_K_M*.gguf"
      mmproj_pattern = ""
      ctx_size       = 16384
      gpu_layers     = 99
      text_only      = true
    }
  }

  # YAML config rendered into the ConfigMap. llama-swap reads /app/config.yaml.
  # ${PORT} is substituted by llama-swap; ${MODEL_ID} is the model key.
  llama_swap_config = yamlencode({
    healthCheckTimeout = 180 # 60-90s is typical model load on NFS-SSD
    logLevel           = "info"
    logToStdout        = "both"
    startPort          = 5800

    macros = {
      llama_server_base = "/app/llama-server --host 0.0.0.0 --port $${PORT} --jinja -fa -np 1"
    }

    models = {
      for mid, cfg in local.models : mid => {
        cmd = join(" ", concat([
          "/app/llama-server",
          "--host 0.0.0.0",
          "--port $${PORT}",
          "-m /models/${mid}/model.gguf",
          ], cfg.text_only ? [] : [
          "--mmproj /models/${mid}/mmproj.gguf",
          ], [
          "-ngl ${cfg.gpu_layers}",
          "-c ${cfg.ctx_size}",
          "-np 1",
          "--jinja",
          "-fa on",
          ],
          # NB: q8_0 KV-cache quant was tried here 2026-07-16 and REVERTED. On
          # the T4 (Turing SM7.5) it collapsed generation to ~0.58 tok/s
          # (~40-70x slower) for BOTH qwen3-8b and qwen3.5-9b — the fused
          # flash-attn kernel has no quantized-KV path on Turing, so even
          # symmetric q8_0/q8_0 falls back to a crawl (prefill stayed fast at
          # ~143 tok/s; generation was the casualty). KV stays f16.
          # See docs/research/2026-07-16-local-llm-sota-and-upgrade.md.
          # Thinking-capable Qwen text models: force reasoning OFF. Qwen3/Qwen3.5
          # default to thinking under --jinja, returning EMPTY message.content
          # (all output -> reasoning_content) + blowing the token budget:
          # paperless-ai gets no JSON, every enrichment fails, ~50x slower.
          # `--reasoning off` is llama.cpp's supported control (deprecates the
          # enable_thinking chat-template kwarg recruiter-responder sends).
          # Scoped to text models via text_only; vision keeps default reasoning.
        cfg.text_only ? ["--reasoning off"] : []))
        ttl           = 600 # unload after 10 min idle
        checkEndpoint = "/health"
      }
    }
  })
}

resource "kubernetes_namespace" "llama_cpp" {
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

# Shared model store. NFS-RWX so the download Job can write while
# the llama-swap Deployment mounts it. Path /srv/nfs-ssd/llamacpp on
# the Proxmox host (SSD-backed for fast model load — Q4_K_M 8B mmaps in
# ~2s vs ~10s on HDD NFS). Page-cache is warmed by the download Job so
# first inference reads from warm cache.
module "nfs_models" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "llama-cpp-models"
  namespace  = kubernetes_namespace.llama_cpp.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs-ssd/llamacpp"
  storage    = "30Gi"
}

# One-shot download Job. Pulls Q4_K_M GGUF + mmproj for every model in
# locals.models into /models/<id>/, creates stable model.gguf /
# mmproj.gguf symlinks, then warms the page cache. Idempotent —
# huggingface_hub's snapshot_download skips files that already exist
# with matching size; symlinks are recreated each run.
resource "kubernetes_job_v1" "download_models" {
  metadata {
    name      = "download-models"
    namespace = kubernetes_namespace.llama_cpp.metadata[0].name
    labels    = local.labels
  }
  spec {
    backoff_limit              = 2
    ttl_seconds_after_finished = 86400
    template {
      metadata { labels = local.labels }
      spec {
        restart_policy = "OnFailure"

        container {
          name  = "download"
          image = "python:3.12-slim"
          command = ["/bin/bash", "-c", <<-EOT
            set -euo pipefail
            pip install --quiet --no-cache-dir 'huggingface_hub>=0.24'
            python - <<'PY'
            import json, os, glob
            from huggingface_hub import snapshot_download
            models = json.loads(os.environ["MODELS_JSON"])
            for mid, cfg in models.items():
                local_dir = f"/models/{mid}"
                os.makedirs(local_dir, exist_ok=True)
                text_only = cfg.get("text_only", False)
                patterns = [cfg["gguf_pattern"]]
                if not text_only and cfg.get("mmproj_pattern"):
                    patterns.append(cfg["mmproj_pattern"])
                print(f"==> downloading {mid} from {cfg['hf_repo']} -> {local_dir} (text_only={text_only})", flush=True)
                snapshot_download(
                    repo_id=cfg["hf_repo"],
                    local_dir=local_dir,
                    allow_patterns=patterns,
                    token=os.environ.get("HF_TOKEN") or None,
                    # Single-threaded download — multi-worker buffers
                    # multi-GB chunks per worker and OOMs the Job at 2Gi.
                    max_workers=1,
                )
                # Resolve actual filenames and create stable symlinks so
                # llama-swap config is filename-agnostic.
                ggufs = [p for p in glob.glob(f"{local_dir}/*Q4_K_M*.gguf") if "mmproj" not in p.lower()]
                if not ggufs:
                    raise SystemExit(f"no GGUF found in {local_dir}")
                gguf_link = f"{local_dir}/model.gguf"
                if os.path.islink(gguf_link) or os.path.exists(gguf_link):
                    os.unlink(gguf_link)
                os.symlink(os.path.basename(ggufs[0]), gguf_link)
                if not text_only:
                    mmprojs = glob.glob(f"{local_dir}/*mmproj*.gguf")
                    if not mmprojs:
                        raise SystemExit(f"no mmproj found in {local_dir}")
                    mmproj_link = f"{local_dir}/mmproj.gguf"
                    if os.path.islink(mmproj_link) or os.path.exists(mmproj_link):
                        os.unlink(mmproj_link)
                    os.symlink(os.path.basename(mmprojs[0]), mmproj_link)
                print(f"==> done {mid}", flush=True)
                for f in sorted(os.listdir(local_dir)):
                    full = os.path.join(local_dir, f)
                    if os.path.isfile(full) and not os.path.islink(full):
                        print(f"   {f} ({os.path.getsize(full):,} bytes)", flush=True)
            print("==> warming page cache", flush=True)
            PY
            # Warm the kernel page cache so first inference reads warm.
            # Wrapped in bash (not the Python heredoc) to keep the cat
            # output out of stdout buffering.
            find /models -type f -name '*.gguf' ! -name 'model.gguf' ! -name 'mmproj.gguf' \
              -exec sh -c 'cat "$1" > /dev/null' _ {} \;
            echo "ALL DONE"
          EOT
          ]
          env {
            name  = "MODELS_JSON"
            value = jsonencode(local.models)
          }
          env {
            name  = "HF_HUB_ENABLE_HF_TRANSFER"
            value = "0"
          }
          # Optional: HF token from Vault (rate-limit avoidance). Sourced
          # from the existing `viktor` Vault path which holds personal
          # creds. Empty string is acceptable (anonymous downloads).
          env {
            name = "HF_TOKEN"
            value_from {
              secret_key_ref {
                name     = "hf-token"
                key      = "token"
                optional = true
              }
            }
          }
          volume_mount {
            name       = "models"
            mount_path = "/models"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            # 4Gi covers the worst-case huggingface_hub buffer (single
            # 5GB GGUF chunked over HTTP) plus interpreter overhead.
            # 2Gi was hit by the previous run.
            limits = { memory = "4Gi" }
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
  wait_for_completion = false
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_config_map" "llama_swap_config" {
  metadata {
    name      = "llama-swap-config"
    namespace = kubernetes_namespace.llama_cpp.metadata[0].name
    labels    = local.labels
  }
  data = {
    "config.yaml" = local.llama_swap_config
  }
}

# Single Deployment running llama-swap. Spawns per-model llama-server
# subprocesses on demand and unloads them after `ttl` seconds idle.
# nvidia.com/gpu=1 buys ONE time-slice (a scheduling turn, NOT the card's
# memory) — the T4 is shared with immich-ml/frigate/immich-server/portal-stt.
# VRAM is bounded per-tenant by the gpumem budget + watchdog (ADR-0016), not by
# scaling co-tenants to 0. llama-swap loads ONE model at a time (no `groups` =
# swap mode, ttl=600 unloads idle), so its footprint is the largest single model.
resource "kubernetes_deployment" "llama_swap" {
  metadata {
    name      = "llama-swap"
    namespace = kubernetes_namespace.llama_cpp.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.gpu })
  }
  # Don't block apply on rollout — the GPU is shared with immich-ml and
  # the pod stays Pending until the operator scales immich-ml=0 for a
  # benchmark window. Apply is "create the desired state, don't wait
  # for it to be reachable".
  wait_for_rollout = false
  spec {
    # Restored to 1 on 2026-05-29 (was 0 during 2026-05-25 IO-storm recovery —
    # see docs/post-mortems/2026-05-25-immich-anca-elements-io-storm.md). The
    # immediate trigger was fire-planner's examples ingest needing qwen3-8b for
    # bulk Reddit-post extraction; only frigate is currently on the GPU on
    # k8s-node1 so contention is minimal.
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = { app = "llama-cpp", component = "llama-swap" }
    }

    template {
      metadata {
        labels = { app = "llama-cpp", component = "llama-swap" }
        annotations = {
          # Bounce the pod whenever the configmap content changes.
          "checksum/config" = sha256(local.llama_swap_config)
        }
      }
      spec {
        node_selector = { gpu = "true" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "llama-swap"
          image = local.llamaswap_image
          # ulimit -c 0: a crashing llama-server (CUDA OOM under VRAM squeeze)
          # dumps a ~536MiB core into the writable layer every few seconds —
          # 2026-07-07 that filled node1 (~148GiB in 50min) and the DiskPressure
          # eviction storm took out the DNS primary. Crash logs go to stdout.
          command = ["/bin/sh", "-c", "ulimit -c 0 && exec /app/llama-swap -config /app/config.yaml -listen :8080"]
          port {
            container_port = 8080
            name           = "http"
          }
          volume_mount {
            name       = "models"
            mount_path = "/models"
          }
          volume_mount {
            name       = "config"
            mount_path = "/app/config.yaml"
            sub_path   = "config.yaml"
          }
          # llama-swap returns 200 on / once running; per-model readiness
          # is gated by the model's own /health endpoint (configured in
          # the YAML as checkEndpoint).
          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 6
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }
          resources {
            requests = {
              cpu                 = "200m"
              memory              = "2Gi"
              "ephemeral-storage" = "1Gi"
            }
            limits = {
              memory = "12Gi"
              # Blast-radius bound (2026-07-07): runaway writable-layer growth
              # evicts THIS pod at 10Gi instead of tipping the whole node into
              # DiskPressure (models live on the PVC; normal usage is <100Mi).
              "ephemeral-storage" = "10Gi"
              "nvidia.com/gpu"    = "1"
              # GPU VRAM budget (ADR-0016): one model at a time. Real resident
              # is ~7 GiB (qwen3-8b @16k measured ~6996 MiB; the old 4.35 GiB was
              # weights-only cudaMalloc). Value left at 5000: the watchdog is
              # DRY_RUN and the scheduler enforces sum(gpumem) <= 14000 (currently
              # 13300), so raising this needs the ADR-0016 budget retune
              # (rebalance immich-ml + llama-swap together) — a separate decision.
              "viktorbarzin.me/gpumem" = "5000"
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
          name = "config"
          config_map {
            name = kubernetes_config_map.llama_swap_config.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].spec[0].container[0].image,  # KEEL_IGNORE_IMAGE
      # KEEL_LIFECYCLE_V1 — stop the apply→keel fight: every keel digest
      # update patches `keel.sh/update-time` on the pod template and
      # `kubernetes.io/change-cause` + bumps the K8s rollout revision on
      # the Deployment. Without these ignore_changes, every `tg apply`
      # reverts those, forcing a rollout, which keel then re-patches on
      # the next 1h poll → llama-swap was rolling several times a day
      # (~10s model-load downtime each). Upstream :cuda nightly cadence
      # still triggers a legitimate daily rollout.
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
  }

  depends_on = [kubernetes_job_v1.download_models]
}

resource "kubernetes_service" "llama_swap" {
  metadata {
    name      = "llama-swap"
    namespace = kubernetes_namespace.llama_cpp.metadata[0].name
    labels    = local.labels
  }
  spec {
    type = "ClusterIP"
    selector = {
      app       = "llama-cpp"
      component = "llama-swap"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
