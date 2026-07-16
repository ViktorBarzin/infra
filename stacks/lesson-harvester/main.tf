variable "image_tag" {
  type    = string
  default = "latest"
}
variable "postgresql_host" { type = string }
variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "lesson-harvester"
  image     = "ghcr.io/viktorbarzin/lesson-harvester:${var.image_tag}"
  labels    = { app = "lesson-harvester" }

  # Static env shared by the Deployment + poll CronJob. All LH_-prefixed
  # (config.py env_prefix="LH_"). Secrets come via env_from (below).
  app_env = {
    LH_LLM_ENDPOINT    = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
    LH_LLM_MODEL       = "qwen3-8b"
    # whisper extra is not in the image yet (v0.3.0) — keep ASR off so a
    # caption-less video parks needs_attention instead of crashing on import.
    LH_WHISPER_ENABLED = "false"
  }
}

resource "kubernetes_namespace" "lesson_harvester" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.aux
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: the goldilocks-vpa ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets from Vault KV secret/lesson-harvester → env (LH_-prefixed keys).
# Seed all three keys in Vault first (empty is fine) or the ES 422s.
resource "kubernetes_manifest" "app_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "lesson-harvester-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target = {
        name     = "lesson-harvester-secrets"
        template = { metadata = { annotations = { "reloader.stakater.com/match" = "true" } } }
      }
      data = [
        { secretKey = "LH_WEBHOOK_BEARER_TOKEN", remoteRef = { key = "lesson-harvester", property = "webhook_bearer_token" } },
        { secretKey = "LH_YOUTUBE_API_KEY", remoteRef = { key = "lesson-harvester", property = "youtube_api_key" } },
        { secretKey = "LH_LEARN_LATER_PLAYLIST_ID", remoteRef = { key = "lesson-harvester", property = "learn_later_playlist_id" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.lesson_harvester]
}

# DB credentials from the Vault database engine (7-day rotation) → asyncpg DSN.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "lesson-harvester-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { name = "vault-database", kind = "ClusterSecretStore" }
      target = {
        name = "lesson-harvester-db-creds"
        template = {
          metadata = { annotations = { "reloader.stakater.com/match" = "true" } }
          data = {
            LH_DB_CONNECTION_STRING = "postgresql+asyncpg://lesson_harvester:{{ .password }}@${var.postgresql_host}:5432/lesson_harvester"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = { key = "static-creds/pg-lesson-harvester", property = "password" }
      }]
    }
  }
  depends_on = [kubernetes_namespace.lesson_harvester]
}

resource "kubernetes_deployment" "lesson_harvester" {
  metadata {
    name      = "lesson-harvester"
    namespace = kubernetes_namespace.lesson_harvester.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.aux })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        # ghcr-credentials is synced into this namespace by the kyverno
        # sync-ghcr-credentials allowlist policy (lesson-harvester added).
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        init_container {
          name    = "alembic-migrate"
          image   = local.image
          command = ["alembic", "upgrade", "head"]
          env_from {
            secret_ref {
              name = "lesson-harvester-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "lesson-harvester-db-creds"
            }
          }
          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        container {
          name  = "lesson-harvester"
          image = local.image # Dockerfile CMD `serve` → python -m lesson_harvester serve
          port {
            container_port = 8080
          }
          env_from {
            secret_ref {
              name = "lesson-harvester-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "lesson-harvester-db-creds"
            }
          }
          dynamic "env" {
            for_each = local.app_env
            content {
              name  = env.key
              value = env.value
            }
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "768Mi" }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                    # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],                 # KEEL_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      spec[0].template[0].spec[0].container[0].image,            # KEEL_IGNORE_IMAGE — CI set image wins
      spec[0].template[0].spec[0].init_container[0].image,
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
  depends_on = [kubernetes_manifest.app_external_secret, kubernetes_manifest.db_external_secret]
}

resource "kubernetes_service" "lesson_harvester" {
  metadata {
    name      = "lesson-harvester"
    namespace = kubernetes_namespace.lesson_harvester.metadata[0].name
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8080"
    }
  }
  spec {
    type     = "ClusterIP"
    selector = local.labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Authentik forward-auth gates the whole host (the backend has no user login of
# its own); /submit is additionally bearer-gated in-app.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.lesson_harvester.metadata[0].name
  name            = "lesson-harvester"
  port            = 8080
  tls_secret_name = var.tls_secret_name
}
