variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }
variable "dbaas_postgresql_root_password" {
  type      = string
  sensitive = true
}
variable "claude_memory_db_password" {
  type      = string
  sensitive = true
}
variable "claude_memory_api_key" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "claude-memory" {
  metadata {
    name = "claude-memory"
    labels = {
      tier = local.tiers.aux
    }
  }
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
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_roles WHERE rolname='claude_memory'" | grep -q 1 || \
                PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -c "CREATE ROLE claude_memory WITH LOGIN PASSWORD '${var.claude_memory_db_password}'"
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_database WHERE datname='claude_memory'" | grep -q 1 || \
                PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -c "CREATE DATABASE claude_memory OWNER claude_memory"
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -c "GRANT ALL PRIVILEGES ON DATABASE claude_memory TO claude_memory"
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
      }
      spec {
        container {
          name  = "claude-memory"
          image = "viktorbarzin/claude-memory-mcp:latest"

          port {
            container_port = 8000
          }

          env {
            name  = "DATABASE_URL"
            value = "postgresql://claude_memory:${var.claude_memory_db_password}@${var.postgresql_host}:5432/claude_memory"
          }
          env {
            name  = "API_KEY"
            value = var.claude_memory_api_key
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
              memory = "32Mi"
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
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  }
}

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
  source          = "../../modules/kubernetes/ingress_factory"
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
