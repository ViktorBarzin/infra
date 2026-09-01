variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }
variable "claude_memory_db_password" {
  type      = string
  sensitive = true
  default   = "" # falls back to Vault `secret/claude-memory.db_password` below
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "claude-memory"
}

resource "kubernetes_namespace" "claude-memory" {
  metadata {
    name = "claude-memory"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-memory-secrets"
      namespace = "claude-memory"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-memory-secrets"
      }
      dataFrom = [{
        extract = {
          key = "claude-memory"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.claude-memory]
}

# DB credentials from Vault database engine (rotated every 24h)
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-memory-db-creds"
      namespace = "claude-memory"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-memory-db-creds"
        template = {
          data = {
            DATABASE_URL = "postgresql://claude_memory:{{ .password }}@${var.postgresql_host}:5432/claude_memory"
            DB_PASSWORD  = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-claude-memory"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.claude-memory]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.claude-memory.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Database init job
resource "kubernetes_job" "db_init" {
  metadata {
    name      = "claude-memory-db-init"
    namespace = kubernetes_namespace.claude-memory.metadata[0].name
  }
  spec {
    template {
      metadata {}
      spec {
        container {
          name  = "db-init"
          image = "postgres:16-alpine"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              # -d postgres: psql defaults database name to username; root user
              # doesn't have a root-named database, so be explicit.
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='claude_memory'" | grep -q 1 || \
                PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -c "CREATE ROLE claude_memory WITH LOGIN PASSWORD '${coalesce(var.claude_memory_db_password, data.vault_kv_secret_v2.secrets.data["db_password"])}'"
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='claude_memory'" | grep -q 1 || \
                PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -c "CREATE DATABASE claude_memory OWNER claude_memory"
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE claude_memory TO claude_memory"
              echo "Database init complete"
            EOT
          ]
        }
        restart_policy = "Never"
      }
    }
    backoff_limit = 3
  }
  wait_for_completion = true
  timeouts {
    create = "2m"
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno mutates the pod dns_config (ndots) on
    # admission. A Job's pod template is immutable, so Terraform can't update
    # that in place — it would REPLACE the Job and re-run it on every apply.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
    ]
  }
}

resource "kubernetes_deployment" "claude-memory" {
  depends_on = [kubernetes_job.db_init]
  metadata {
    name      = "claude-memory"
    namespace = kubernetes_namespace.claude-memory.metadata[0].name
    labels = {
      app  = "claude-memory"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    # 1 replica (trimmed from 2 on 2026-07-12, Viktor — ~680Mi back). The 2nd
    # replica existed to make drains/rotations/deploys zero-downtime; at 1,
    # those events cost a brief recall/store blip for active sessions
    # (accepted). PDB below flipped to max_unavailable=1 accordingly —
    # min_available=1 with a single replica would BLOCK kured node drains.
    replicas = 1
    selector {
      match_labels = {
        app = "claude-memory"
      }
    }
    template {
      metadata {
        labels = {
          app = "claude-memory"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
          # Skip descheduler eviction — it bounced this pod every ~5min
          # (LowNodeUtilization). The PDB below keeps drains/Keel/CI safe at
          # 2 replicas; this just stops the needless churn of the MCP backend.
          "descheduler.alpha.kubernetes.io/evict" = "false"
        }
      }
      spec {
        # GPU-served query embeddings (2026-09-01, docs/plans in claude-memory-mcp:
        # 2026-08-31-gpu-query-embeddings.md). Every recall embeds its query, and on a
        # CPU that cost 0.25-0.9s per call, which put recall p50 at 0.95s, p90 at 4.98s,
        # and pushed 6.5% of recalls past the session hook's 6s deadline — those returned
        # no memories at all. onnxruntime serves the same work on the T4.
        #
        # Requesting nvidia.com/gpu is a hard scheduling constraint, so this pins the pod
        # to k8s-node1, the only GPU node. Accepted deliberately: the Kyverno
        # inject-gpu-workload-priority policy stamps gpu-workload (1,200,000) on any
        # nvidia.com/gpu pod outside its exclude list, and claude-memory is not excluded,
        # so under node1 pressure it preempts the non-GPU workloads that left GPU pods
        # Pending after the 2026-07-18 reboot (code-j3tx) rather than queueing behind them.
        node_selector = { "nvidia.com/gpu.present" = "true" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_labels = {
                  app = "claude-memory"
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        container {
          name = "claude-memory"
          # Phase 3 cutover 2026-05-07 — moved off DockerHub to Forgejo as
          # part of the registry consolidation. Old: viktorbarzin/claude-memory-mcp:17
          image = "ghcr.io/viktorbarzin/claude-memory-mcp:latest"

          port {
            container_port = 8000
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "claude-memory-db-creds"
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name = "API_KEYS"
            value_from {
              secret_key_ref {
                name = "claude-memory-secrets"
                key  = "api_keys"
              }
            }
          }
          env {
            # Dense (semantic) recall leg — flipped 2026-07-11 after the pgvector
            # operand swap + full embedding backfill (hybrid-recall promotion
            # runbook Phase 5). Read live by embeddings_enabled(); rollback =
            # set to "0" and re-apply (instant lexical-only, schema untouched).
            name  = "MEMORY_EMBEDDINGS_ENABLED"
            value = "0"
          }
          env {
            # Model swap, 2026-09-01: BAAI/bge-large-en-v1.5 -> Qwen/Qwen3-Embedding-0.6B,
            # served by onnxruntime from a graph baked into the image. Native 1024-d, so
            # the halfvec(1024) column and the HNSW index are untouched and the migration
            # is a re-embed rather than a schema change. It is also multilingual, which
            # bge-large is not: 9.2% of a 400-memory sample carries Bulgarian that the
            # English-only model has no representation for.
            #
            # MEMORY_EMBEDDINGS_ENABLED is 0 above ONLY for the cutover. The re-embed
            # (scripts/reembed.py) rewrites the embedding column in place, so until it
            # finishes the index holds a mix of bge and Qwen vectors; recall serves
            # lexical-only for the duration rather than ranking against both. Flip back
            # to "1" once the backfill completes and the eval gate passes.
            #
            # Rolling back the model is this flag, not a vector restore: an in-place
            # re-embed leaves no bge vectors behind, and api/recall.py documents
            # MEMORY_EMBEDDINGS_ENABLED=0 as a true no-op to the lexical path that is
            # correct whatever the column holds.
            name  = "MEMORY_EMBEDDING_BACKEND"
            value = "onnx"
          }
          env {
            # CUDA first, CPU as the fallback within the same process and the same graph.
            # A GPU outage (VRAM pressure, a watchdog recycle, a node1 drain) then keeps
            # dense recall alive on CPU instead of dropping it, and
            # memory_embed_fallbacks_total is the signal that it is happening.
            name  = "MEMORY_ONNX_PROVIDERS"
            value = "CUDAExecutionProvider,CPUExecutionProvider"
          }
          env {
            # Cap torch/OpenMP threads (2026-08-15). The container sees all 8 of
            # its node's cores, so torch defaulted to 8 compute + 8 interop
            # threads — for a batch-of-1 bge-large forward pass that is heavy
            # oversubscription, and the sync overhead dominates. Measured: one
            # long recall burned 12.7 CPU-SECONDS for 2.7s of wall time (~4.7
            # cores in parallel) to embed a single ~260-token query, work that
            # should cost a fraction of a core-second. It also meant one memory
            # lookup could take ~60% of the node's CPU for two seconds, and the
            # per-turn recall hook fires on every prompt in every session.
            name  = "OMP_NUM_THREADS"
            value = "4"
          }
          env {
            # Same reason as OMP_NUM_THREADS — MKL keeps its own pool, and
            # leaving it unset lets it re-expand to the node's core count.
            name  = "MKL_NUM_THREADS"
            value = "4"
          }

          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            # 5-minute budget (150 x 2s). Kept at 5 minutes for a different reason
            # than it was set: since 2026-09-01 the model ships inside the image as an
            # ONNX graph, so a fresh pod no longer downloads ~1.3GB from HuggingFace
            # before binding :8000 (the cause of the 2026-08-14 crash loop — 9 restarts,
            # exit 137, kubelet killing the container mid-download at the old 60s
            # budget). What still needs the headroom is the startup warm-up: lifespan
            # runs one embed before serving, and initialising the CUDA context on a
            # contended T4 is not instant. Generous on purpose, since the cost of the
            # budget being too small is a pod that can never start.
            failure_threshold = 150
            period_seconds    = 2
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          resources {
            # Dense-leg sizing (2026-07-11): the local bge-large embedder holds
            # ~1.8Gi resident once the first embed loads it (lazy import; the
            # old 128Mi limit OOM-killed the import). Burstable on purpose —
            # baseline API is ~150Mi; only embed-serving pods grow to the model
            # ceiling. Tier-3/4 burstable precedent.
            #
            # CPU request 10m -> 1000m (2026-08-15). Every recall runs a
            # bge-large forward pass on the CPU, and that pass was measured at
            # 1259-2890m while the pod asked for 10m. Since CFS shares are
            # proportional to the request, on a busy node it got ~1/100th of a
            # core for the one thing it does, which is where the tail came from:
            # of 58 recalls, only 41% finished under 1s, the mean was 2.19s and
            # two took over 10s. Latency tracked context length exactly (5 chars
            # 0.245s, 44 chars 0.373s, 1047 chars 1.874s) — the per-turn recall
            # hook sends the whole user prompt, so the slow case is the normal
            # case. 1000m is the low end of a measured burst, not a ceiling:
            # there are no CPU limits cluster-wide, so it still bursts to ~2.9
            # cores when the node is free, and an unused CPU request costs
            # nothing but scheduling headroom (k8s-node5 sits at 49% of CPU
            # requests; memory, at 87%, is that node's real constraint).
            #
            # NOT changed here, but noted: the memory request (512Mi) is below
            # actual residency (751Mi idle, ~1.8Gi with the model warm), so the
            # scheduler under-counts this pod. Raising it eats into the N-1
            # memory headroom that ClusterCannotTolerateNonGpuNodeLoss watches,
            # so it wants doing deliberately rather than as a side effect.
            requests = {
              memory = "512Mi"
              cpu    = "1000m"
            }
            limits = {
              # 2560Mi -> 3Gi with the ONNX backend (2026-09-01). torch is gone, but
              # onnxruntime's CUDA provider adds a host-side allocation for the CUDA
              # context on top of the ~600MiB int8 graph. The limit does not affect
              # scheduling (only the request does, and that is unchanged), so raising it
              # costs nothing and avoids an OOM-kill on a path that is hard to attribute.
              memory = "3Gi"

              # ONE time-slice of the T4 (the operator advertises 100), plus the VRAM
              # contract the scheduler counts and the gpu-vram-watchdog enforces.
              # 1200 MiB = ~600 int8 weights + ~300 CUDA context + arena and margin. It
              # is a first estimate to be tightened from gpu_pod_memory_used_bytes once
              # this has run, exactly as ADR-0016 asks. It fits the current seating
              # chart without a capacity change: after the 2026-08-31 re-basing of every
              # tenant to measured footprints, declared totals are 7,684 of the 14,000
              # advertised, so this takes headroom from 6,316 to 5,116.
              "nvidia.com/gpu"         = "1"
              "viktorbarzin.me/gpumem" = "1200"
            }
          }
        }
      }
    }
  }
  lifecycle {
    # DRIFT_WORKAROUND: CI pipeline owns image tag (kubectl set image from Woodpecker/GHA). Reviewed 2026-04-18.
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
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

# PDB restored alongside replicas=2 (2026-06-18). The old reason for removing it
# — a 1-replica minAvailable=1 PDB deadlocks node drains — no longer applies at
# 2 replicas: minAvailable=1 lets one pod be drained/evicted while the other
# serves, so voluntary disruptions never take the MCP backend to zero.
resource "kubernetes_pod_disruption_budget_v1" "claude-memory" {
  metadata {
    name      = "claude-memory"
    namespace = kubernetes_namespace.claude-memory.metadata[0].name
  }
  spec {
    # max_unavailable (not min_available): with 1 replica, min_available=1
    # blocks every voluntary eviction — kured drains would hang on this pod.
    max_unavailable = "1"
    selector {
      match_labels = {
        app = "claude-memory"
      }
    }
  }
}

resource "kubernetes_service" "claude-memory" {
  metadata {
    name      = "claude-memory"
    namespace = kubernetes_namespace.claude-memory.metadata[0].name
    labels = {
      app = "claude-memory"
    }
    annotations = {
      # ADR-0007 observability: recall rate/latency/errors, dense-leg
      # contribution, link redirects/attaches, embed-on-write, store gauges.
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8000"
    }
  }
  spec {
    selector = {
      app = "claude-memory"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # MCP server — called by Claude Code (and other tools/agents) via app-layer
  # bearer-token auth; forward-auth would break programmatic clients.
  # auth = "none": MCP server called by Claude Code via bearer-token auth; forward-auth would break programmatic clients.
  auth            = "none"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.claude-memory.metadata[0].name
  name            = "claude-memory"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Claude Memory"
    "gethomepage.dev/description"  = "Shared persistent memory for Claude sessions"
    "gethomepage.dev/icon"         = "claude-ai.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}
