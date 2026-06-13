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
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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
        }
      }
      spec {
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

          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            failure_threshold = 30
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
            requests = {
              memory = "128Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "128Mi"
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

# PDB removed — single replica with minAvailable=1 blocks all node drains.
# claude-memory is non-critical and recovers quickly after rescheduling.

resource "kubernetes_service" "claude-memory" {
  metadata {
    name      = "claude-memory"
    namespace = kubernetes_namespace.claude-memory.metadata[0].name
    labels = {
      app = "claude-memory"
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
