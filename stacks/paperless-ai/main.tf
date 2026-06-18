variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "paperless-ai"
}

resource "kubernetes_namespace" "paperless_ai" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# paperless-ai secrets pulled from Vault (secret/paperless-ai) by ESO:
#   paperless_api_token — token for the dedicated `paperless-ai` Paperless
#                         superuser (reads + tags ALL documents).
#   api_key             — M2M key between the Node UI and the Python RAG service.
#   custom_api_key      — placeholder bearer for llama-swap (no auth, field required).
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "paperless-ai-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "paperless-ai-secrets"
      }
      dataFrom = [{
        extract = {
          key = "paperless-ai"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.paperless_ai]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.paperless_ai.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# /app/data holds the SQLite DB, the embedded ChromaDB vector store
# (rag_data/), the cached local embedding model, thumbnails and the
# persisted .env. Sensitive (document-derived vectors + the Paperless
# token) -> encrypted block storage. Autoresizes 2Gi -> 10Gi.
resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "paperless-ai-data-encrypted"
    namespace = local.namespace
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # pvc-autoresizer grows requests.storage up to storage_limit; PVCs
    # cannot shrink, so ignore drift to keep applies idempotent.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "paperless_ai" {
  metadata {
    name      = "paperless-ai"
    namespace = local.namespace
    labels = {
      app  = "paperless-ai"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  # The image bundles PyTorch + Surya OCR (multi-GB); the first pull can
  # exceed the provider's rollout-wait. Don't block apply on readiness —
  # rollout is verified out-of-band with kubectl.
  wait_for_rollout = false
  spec {
    replicas = 1
    # RWO encrypted PVC -> never run two pods against it at once.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "paperless-ai"
      }
    }
    template {
      metadata {
        labels = {
          app = "paperless-ai"
        }
      }
      spec {
        # The image runs as PUID/PGID 1000; fsGroup makes the encrypted
        # PVC group-writable so the app can persist to /app/data.
        security_context {
          fs_group = 1000
        }
        container {
          name  = "paperless-ai"
          image = "docker.io/clusterzx/paperless-ai:3.0.9"

          # Node UI (proxied by the Service) + Python RAG service (in-pod only).
          port {
            container_port = 3000
            name           = "http"
          }
          port {
            container_port = 8000
            name           = "rag"
          }

          # NOTE on configuration model: paperless-ai persists its RUNTIME
          # config (Paperless URL/token, AI provider, processing flags) plus
          # the app-admin account to /app/data/.env + SQLite on the PVC,
          # written once via its setup flow (POST /setup). The env vars below
          # are consumed by the Node layer and serve as setup-form pre-fill;
          # the authoritative runtime config is the PVC's .env. App-admin
          # creds + the Paperless token live in Vault secret/paperless-ai.
          env {
            name  = "PUID"
            value = "1000"
          }
          env {
            name  = "PGID"
            value = "1000"
          }
          env {
            name  = "PAPERLESS_AI_PORT"
            value = "3000"
          }
          env {
            name  = "RAG_SERVICE_URL"
            value = "http://localhost:8000"
          }
          env {
            name  = "RAG_SERVICE_ENABLED"
            value = "true"
          }

          # Persist the HuggingFace / sentence-transformers embedding model
          # (paraphrase-multilingual-MiniLM-L12-v2) onto the PVC so it is
          # not re-downloaded on every pod restart.
          env {
            name  = "HF_HOME"
            value = "/app/data/hf-cache"
          }
          env {
            name  = "SENTENCE_TRANSFORMERS_HOME"
            value = "/app/data/st-cache"
          }

          # --- Paperless-ngx connection (internal service, no edge hop) ---
          env {
            name  = "PAPERLESS_API_URL"
            value = "http://paperless-ngx.paperless-ngx.svc.cluster.local/api"
          }
          env {
            name  = "PAPERLESS_USERNAME"
            value = "paperless-ai"
          }
          env {
            name = "PAPERLESS_API_TOKEN"
            value_from {
              secret_key_ref {
                name = "paperless-ai-secrets"
                key  = "paperless_api_token"
              }
            }
          }

          # --- LLM backend: in-cluster llama-swap (OpenAI-compatible) ---
          env {
            name  = "AI_PROVIDER"
            value = "custom"
          }
          env {
            name  = "CUSTOM_BASE_URL"
            value = "http://llama-swap.llama-cpp.svc.cluster.local:8080/v1"
          }
          env {
            name  = "CUSTOM_MODEL"
            value = "qwen3-8b"
          }
          env {
            name = "CUSTOM_API_KEY"
            value_from {
              secret_key_ref {
                name = "paperless-ai-secrets"
                key  = "custom_api_key"
              }
            }
          }

          # M2M key between the Node UI and the Python RAG service.
          env {
            name = "API_KEY"
            value_from {
              secret_key_ref {
                name = "paperless-ai-secrets"
                key  = "api_key"
              }
            }
          }

          # --- Processing: auto-analyze + tag every document ---
          env {
            name  = "SCAN_INTERVAL"
            value = "*/30 * * * *"
          }
          env {
            name  = "PROCESS_PREDEFINED_DOCUMENTS"
            value = "yes"
          }
          env {
            name  = "ADD_AI_PROCESSED_TAG"
            value = "yes"
          }
          env {
            name  = "AI_PROCESSED_TAG_NAME"
            value = "ai-processed"
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "2Gi"
            }
            limits = {
              # torch + the sentence-transformers model load in-process for
              # the RAG service; 4Gi covers Node + Python + ChromaDB.
              memory = "4Gi"
            }
          }

          # The image presents a setup wizard / login that 30x-redirects on
          # `/`, so an HTTP probe is brittle pre-setup. A TCP probe on the
          # Node port is the robust readiness signal (same approach as the
          # paperless-mcp stack).
          startup_probe {
            tcp_socket {
              port = 3000
            }
            failure_threshold = 60
            period_seconds    = 5
          }
          readiness_probe {
            tcp_socket {
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }
          liveness_probe {
            tcp_socket {
              port = 3000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
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

resource "kubernetes_service" "paperless_ai" {
  metadata {
    name      = "paperless-ai"
    namespace = local.namespace
    labels = {
      app = "paperless-ai"
    }
  }
  spec {
    selector = {
      app = "paperless-ai"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "required": private admin UI. paperless-ai has its own login but
  # Authentik forward-auth is the primary gate (defence in depth). It only
  # polls Paperless outbound (no inbound API consumers), so the Authentik
  # 302 dance does not break it.
  auth            = "required"
  namespace       = kubernetes_namespace.paperless_ai.metadata[0].name
  name            = "paperless-ai"
  service_name    = "paperless-ai"
  host            = "paperless-ai"
  dns_type        = "proxied"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "AI document search & tagging"
    "gethomepage.dev/group"       = "Productivity"
    "gethomepage.dev/icon"        = "paperless-ngx.png"
    "gethomepage.dev/name"        = "Paperless-AI"
    "gethomepage.dev/pod-selector" = ""
  }
}
