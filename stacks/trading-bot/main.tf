variable "tls_secret_name" {
  type = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "redis_host" { type = string }
variable "ollama_host" { type = string }
variable "dbaas_postgresql_root_password" {
  type = string
  sensitive = true
}
variable "trading_bot_db_password" {
  type = string
  sensitive = true
}
variable "trading_bot_alpaca_api_key" {
  type = string
  sensitive = true
}
variable "trading_bot_alpaca_secret_key" {
  type = string
  sensitive = true
}
variable "trading_bot_jwt_secret" {
  type = string
  sensitive = true
}
variable "trading_bot_reddit_client_id" { type = string }
variable "trading_bot_reddit_client_secret" {
  type = string
  sensitive = true
}
variable "trading_bot_alpha_vantage_api_key" {
  type = string
  sensitive = true
}
variable "trading_bot_fmp_api_key" {
  type = string
  sensitive = true
}

locals {
  common_env = {
    TRADING_DATABASE_URL                 = "postgresql+asyncpg://trading:${var.trading_bot_db_password}@${var.postgresql_host}:5432/trading"
    TRADING_REDIS_URL                    = "redis://${var.redis_host}:6379/4"
    TRADING_LOG_LEVEL                    = "INFO"
    TRADING_ALPACA_API_KEY               = var.trading_bot_alpaca_api_key
    TRADING_ALPACA_SECRET_KEY            = var.trading_bot_alpaca_secret_key
    TRADING_ALPACA_BASE_URL              = "https://paper-api.alpaca.markets"
    TRADING_PAPER_TRADING                = "true"
    TRADING_JWT_SECRET_KEY               = var.trading_bot_jwt_secret
    TRADING_REDDIT_CLIENT_ID             = var.trading_bot_reddit_client_id
    TRADING_REDDIT_CLIENT_SECRET         = var.trading_bot_reddit_client_secret
    TRADING_REDDIT_USER_AGENT            = "trading-bot/0.1"
    TRADING_OLLAMA_HOST                  = "http://${var.ollama_host}:11434"
    TRADING_OLLAMA_MODEL                 = "gemma3"
    TRADING_WATCHLIST                    = "[\"AAPL\",\"TSLA\",\"NVDA\",\"MSFT\",\"GOOGL\"]"
    TRADING_BAR_TIMEFRAME                = "5Min"
    TRADING_POLL_INTERVAL_SECONDS        = "60"
    TRADING_HISTORICAL_BARS              = "100"
    TRADING_SNAPSHOT_INTERVAL_SECONDS    = "60"
    TRADING_ALPHA_VANTAGE_API_KEY        = var.trading_bot_alpha_vantage_api_key
    TRADING_FMP_API_KEY                  = var.trading_bot_fmp_api_key
    TRADING_FUNDAMENTALS_CACHE_TTL_HOURS = "24"
    TRADING_RP_ID                        = "trading.viktorbarzin.me"
    TRADING_RP_NAME                      = "Trading Bot"
    TRADING_RP_ORIGIN                    = "https://trading.viktorbarzin.me"
    TRADING_CORS_ORIGINS                 = "[\"https://trading.viktorbarzin.me\"]"
  }
}

resource "kubernetes_namespace" "trading-bot" {
  metadata {
    name = "trading-bot"
    labels = {
      tier                               = local.tiers.edge
      "resource-governance/custom-quota" = "true"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.trading-bot.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Database init job - creates the trading database and user in PostgreSQL
resource "kubernetes_job" "db_init" {
  metadata {
    name      = "trading-bot-db-init"
    namespace = kubernetes_namespace.trading-bot.metadata[0].name
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
              # Create role if not exists
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_roles WHERE rolname='trading'" | grep -q 1 || \
                PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -c "CREATE ROLE trading WITH LOGIN PASSWORD '${var.trading_bot_db_password}'"
              # Create database if not exists
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_database WHERE datname='trading'" | grep -q 1 || \
                PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -c "CREATE DATABASE trading OWNER trading"
              # Grant privileges
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -c "GRANT ALL PRIVILEGES ON DATABASE trading TO trading"
              # Try to enable timescaledb (allow failure)
              PGPASSWORD='${var.dbaas_postgresql_root_password}' psql -h ${var.postgresql_host} -U root -d trading -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE" || true
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

# Migrations job - runs alembic migrations
resource "kubernetes_job" "migrations" {
  metadata {
    name      = "trading-bot-migrations"
    namespace = kubernetes_namespace.trading-bot.metadata[0].name
  }
  spec {
    template {
      metadata {}
      spec {
        container {
          name              = "migrations"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "alembic", "upgrade", "head"]
          env {
            name  = "TRADING_DATABASE_URL"
            value = "postgresql+asyncpg://trading:${var.trading_bot_db_password}@${var.postgresql_host}:5432/trading"
          }
          env {
            name  = "TRADING_REDIS_URL"
            value = "redis://${var.redis_host}:6379/4"
          }
        }
        restart_policy = "Never"
      }
    }
    backoff_limit = 3
  }
  wait_for_completion = true
  timeouts {
    create = "5m"
  }
  depends_on = [kubernetes_job.db_init]
}

# Frontend deployment - dashboard + api-gateway
resource "kubernetes_deployment" "trading-bot-frontend" {
  metadata {
    name      = "trading-bot-frontend"
    namespace = kubernetes_namespace.trading-bot.metadata[0].name
    labels = {
      app  = "trading-bot-frontend"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "trading-bot-frontend"
      }
    }
    template {
      metadata {
        labels = {
          app = "trading-bot-frontend"
        }
      }
      spec {
        container {
          name              = "dashboard"
          image             = "viktorbarzin/trading-bot-dashboard:latest"
          image_pull_policy = "Always"
          port {
            container_port = 80
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }
        container {
          name              = "api-gateway"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.api_gateway.main"]
          port {
            container_port = 8000
            protocol       = "TCP"
          }
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].container[1].image,
    ]
  }
  depends_on = [kubernetes_job.migrations]
}

# Workers deployment - all background microservices
resource "kubernetes_deployment" "trading-bot-workers" {
  metadata {
    name      = "trading-bot-workers"
    namespace = kubernetes_namespace.trading-bot.metadata[0].name
    labels = {
      app  = "trading-bot-workers"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "trading-bot-workers"
      }
    }
    template {
      metadata {
        labels = {
          app = "trading-bot-workers"
        }
      }
      spec {
        container {
          name              = "news-fetcher"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.news_fetcher.main"]
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name  = "TRADING_OTEL_METRICS_PORT"
            value = "9091"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
        container {
          name              = "sentiment-analyzer"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.sentiment_analyzer.main"]
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name  = "TRADING_OTEL_METRICS_PORT"
            value = "9092"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "2Gi"
            }
          }
        }
        container {
          name              = "signal-generator"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.signal_generator.main"]
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name  = "TRADING_OTEL_METRICS_PORT"
            value = "9093"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
        container {
          name              = "trade-executor"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.trade_executor.main"]
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name  = "TRADING_OTEL_METRICS_PORT"
            value = "9094"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
        container {
          name              = "learning-engine"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.learning_engine.main"]
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name  = "TRADING_OTEL_METRICS_PORT"
            value = "9095"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
        container {
          name              = "market-data"
          image             = "viktorbarzin/trading-bot-service:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "services.market_data.main"]
          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.key
              value = env.value
            }
          }
          env {
            name  = "TRADING_OTEL_METRICS_PORT"
            value = "9096"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].container[1].image,
      spec[0].template[0].spec[0].container[2].image,
      spec[0].template[0].spec[0].container[3].image,
      spec[0].template[0].spec[0].container[4].image,
      spec[0].template[0].spec[0].container[5].image,
    ]
  }
  depends_on = [kubernetes_job.migrations]
}

resource "kubernetes_service" "trading-bot-frontend" {
  metadata {
    name      = "trading-bot-frontend"
    namespace = kubernetes_namespace.trading-bot.metadata[0].name
    labels = {
      app = "trading-bot-frontend"
    }
  }
  spec {
    selector = {
      app = "trading-bot-frontend"
    }
    port {
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.trading-bot.metadata[0].name
  name            = "trading"
  service_name    = "trading-bot-frontend"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
