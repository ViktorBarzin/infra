variable "tls_secret_name" { type = string }
variable "clickhouse_password" { type = string }
variable "clickhouse_postgres_password" { type = string }
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }


resource "kubernetes_namespace" "rybbit" {
  metadata {
    name = "rybbit"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

locals {
  clickhouse_db = "clickhouse"
}


module "nfs_clickhouse_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "rybbit-clickhouse-data"
  namespace  = kubernetes_namespace.rybbit.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/clickhouse"
}

resource "kubernetes_deployment" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "clickhouse"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "clickhouse"
      }
    }
    template {
      metadata {
        labels = {
          app = "clickhouse"
        }
      }
      spec {
        container {
          name  = "clickhouse"
          image = "clickhouse/clickhouse-server:25.4.2"
          env {
            name  = "CLICKHOUSE_DB"
            value = local.clickhouse_db
          }
          env {
            name  = "CLICKHOUSE_PASSWORD"
            value = var.clickhouse_password
          }
          port {
            name           = "clickhouse"
            protocol       = "TCP"
            container_port = 8123
          }
          liveness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/ping"
              port = 8123
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/clickhouse"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_clickhouse_data.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      "app" = "clickhouse"
    }
  }

  spec {
    selector = {
      app = "clickhouse"
    }
    port {
      name        = "http"
      target_port = 8123
      port        = 8123
      protocol    = "TCP"
    }
  }
}

# CronJob to truncate ClickHouse system log tables every 6 hours.
# These tables grow unboundedly on NFS and trigger CPU-heavy background merges.
resource "kubernetes_cron_job_v1" "clickhouse_truncate_logs" {
  metadata {
    name      = "clickhouse-truncate-logs"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "truncate"
              image = "curlimages/curl:8.12.1"
              command = [
                "sh", "-c",
                join(" && ", [
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${var.clickhouse_password}' -d 'TRUNCATE TABLE IF EXISTS system.metric_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${var.clickhouse_password}' -d 'TRUNCATE TABLE IF EXISTS system.trace_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${var.clickhouse_password}' -d 'TRUNCATE TABLE IF EXISTS system.text_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${var.clickhouse_password}' -d 'TRUNCATE TABLE IF EXISTS system.asynchronous_metric_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${var.clickhouse_password}' -d 'TRUNCATE TABLE IF EXISTS system.query_log'",
                  "curl -s 'http://clickhouse.rybbit.svc.cluster.local:8123/?user=default&password=${var.clickhouse_password}' -d 'TRUNCATE TABLE IF EXISTS system.part_log'",
                  "echo 'System logs truncated'"
                ])
              ]
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "rybbit" {
  metadata {
    name      = "rybbit"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "rybbit"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "rybbit"
      }
    }
    template {
      metadata {
        labels = {
          app = "rybbit"
        }
      }
      spec {
        container {
          image = "ghcr.io/rybbit-io/rybbit-backend:latest"
          name  = "rybbit"

          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "CLICKHOUSE_HOST"
            value = "http://clickhouse.rybbit.svc.cluster.local:8123"
          }
          env {
            name  = "CLICKHOUSE_DB"
            value = local.clickhouse_db
          }
          env {
            name  = "CLICKHOUSE_USER"
            value = "default"
          }
          env {
            name  = "CLICKHOUSE_PASSWORD"
            value = var.clickhouse_password
          }
          env {
            name  = "POSTGRES_HOST"
            value = var.postgresql_host
          }
          env {
            name  = "POSTGRES_PORT"
            value = "5432"
          }
          env {
            name  = "POSTGRES_DB"
            value = "rybbit"
          }
          env {
            name  = "POSTGRES_USER"
            value = "rybbit"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = var.clickhouse_postgres_password
          }
          env {
            name  = "BASE_URL"
            value = "https://rybbit.viktorbarzin.me"
          }
          env {
            name  = "DISABLE_SIGNUP"
            value = true
          }
          env {
            name  = "BETTER_AUTH_SECRET"
            value = random_string.random.result
          }
          env {
            name  = "AUTH_ENABLED"
            value = true
          }
          port {
            container_port = 3001
          }
          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3001
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3001
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "rybbit" {
  metadata {
    name      = "rybbit"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      "app" = "rybbit"
    }
  }

  spec {
    selector = {
      "app" = "rybbit"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3001
    }
  }
}

resource "kubernetes_deployment" "rybbit-client" {
  metadata {
    name      = "rybbit-client"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "rybbit-client"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "rybbit-client"
      }
    }
    template {
      metadata {
        labels = {
          app = "rybbit-client"
        }
      }
      spec {
        container {
          name  = "rybbit-client"
          image = "ghcr.io/rybbit-io/rybbit-client:latest"
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "DISABLE_SIGNUP"
            value = true
          }
          port {
            name           = "rybbit-client"
            protocol       = "TCP"
            container_port = 3002
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3002
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3002
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "150m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "rybbit-client" {
  metadata {
    name      = "rybbit-client"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      "app" = "rybbit-client"
    }
  }

  spec {
    selector = {
      "app" = "rybbit-client"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3002
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  name            = "rybbit"
  service_name    = "rybbit-client"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "3c476801a777"
}

module "ingress-api" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  name            = "rybbit-api"
  host            = "rybbit"
  service_name    = "rybbit"
  ingress_path    = ["/api"]
  tls_secret_name = var.tls_secret_name
}
