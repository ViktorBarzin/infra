/*
# TRADING-BOT STACK COMMENTED OUT - 2026-04-06
# Deployments scaled to 0, infrastructure disabled to prevent re-creation on apply
# To re-enable: uncomment this entire block

variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "redis_host" { type = string }
locals {
  common_env = {
    TRADING_REDIS_URL                    = "redis://${var.redis_host}:6379/4"
    TRADING_LOG_LEVEL                    = "INFO"
    TRADING_ALPACA_BASE_URL              = "https://paper-api.alpaca.markets"
    TRADING_PAPER_TRADING                = "true"
    TRADING_REDDIT_USER_AGENT            = "trading-bot/0.1"
    TRADING_WATCHLIST                    = "[\"AAPL\",\"TSLA\",\"NVDA\",\"MSFT\",\"GOOGL\"]"
    TRADING_BAR_TIMEFRAME                = "5Min"
    TRADING_POLL_INTERVAL_SECONDS        = "60"
    TRADING_HISTORICAL_BARS              = "100"
    TRADING_SNAPSHOT_INTERVAL_SECONDS    = "60"
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
      tier = local.tiers.edge
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.trading-bot.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "trading-bot-secrets"
      namespace = "trading-bot"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "trading-bot-secrets"
        template = {
          data = {
            TRADING_ALPACA_API_KEY        = "{{ .alpaca_api_key }}"
            TRADING_ALPACA_SECRET_KEY     = "{{ .alpaca_secret_key }}"
            TRADING_JWT_SECRET_KEY        = "{{ .jwt_secret }}"
            TRADING_REDDIT_CLIENT_ID      = "{{ .reddit_client_id }}"
            TRADING_REDDIT_CLIENT_SECRET  = "{{ .reddit_client_secret }}"
            TRADING_ALPHA_VANTAGE_API_KEY = "{{ .alpha_vantage_api_key }}"
            TRADING_FMP_API_KEY           = "{{ .fmp_api_key }}"
            DBAAS_ROOT_PASSWORD           = "{{ .dbaas_root_password }}"
          }
        }
      }
      data = [
        { secretKey = "alpaca_api_key", remoteRef = { key = "trading-bot", property = "alpaca_api_key" } },
        { secretKey = "alpaca_secret_key", remoteRef = { key = "trading-bot", property = "alpaca_secret_key" } },
        { secretKey = "jwt_secret", remoteRef = { key = "trading-bot", property = "jwt_secret" } },
        { secretKey = "reddit_client_id", remoteRef = { key = "trading-bot", property = "reddit_client_id" } },
        { secretKey = "reddit_client_secret", remoteRef = { key = "trading-bot", property = "reddit_client_secret" } },
        { secretKey = "alpha_vantage_api_key", remoteRef = { key = "trading-bot", property = "alpha_vantage_api_key" } },
        { secretKey = "fmp_api_key", remoteRef = { key = "trading-bot", property = "fmp_api_key" } },
        { secretKey = "dbaas_root_password", remoteRef = { key = "trading-bot", property = "dbaas_root_password" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.trading-bot]
}

# DB credentials from Vault database engine (rotated every 24h)
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "trading-bot-db-creds"
      namespace = "trading-bot"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "trading-bot-db-creds"
        template = {
          data = {
            TRADING_DATABASE_URL = "postgresql+asyncpg://trading:{{ .password }}@${var.postgresql_host}:5432/trading"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-trading"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.trading-bot]
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
              PGPASSWORD="$DBAAS_ROOT_PASSWORD" psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_roles WHERE rolname='trading'" | grep -q 1 || \
                PGPASSWORD="$DBAAS_ROOT_PASSWORD" psql -h ${var.postgresql_host} -U root -c "CREATE ROLE trading WITH LOGIN PASSWORD '$DB_PASSWORD'"
              # Create database if not exists
              PGPASSWORD="$DBAAS_ROOT_PASSWORD" psql -h ${var.postgresql_host} -U root -tc "SELECT 1 FROM pg_database WHERE datname='trading'" | grep -q 1 || \
                PGPASSWORD="$DBAAS_ROOT_PASSWORD" psql -h ${var.postgresql_host} -U root -c "CREATE DATABASE trading OWNER trading"
              # Grant privileges
              PGPASSWORD="$DBAAS_ROOT_PASSWORD" psql -h ${var.postgresql_host} -U root -c "GRANT ALL PRIVILEGES ON DATABASE trading TO trading"
              # Try to enable timescaledb (allow failure)
              PGPASSWORD="$DBAAS_ROOT_PASSWORD" psql -h ${var.postgresql_host} -U root -d trading -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE" || true
              echo "Database init complete"
            EOT
          ]
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
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
            name  = "TRADING_REDIS_URL"
            value = "redis://${var.redis_host}:6379/4"
          }
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
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
    annotations = {
      "reloader.stakater.com/auto" = "true"
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
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432,redis-master.redis:6379"
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
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
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
    # DRIFT_WORKAROUND: CI pipeline owns image tags for api + migrations containers. Reviewed 2026-04-18.
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].container[1].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
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
    annotations = {
      "reloader.stakater.com/auto" = "true"
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
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432,redis-master.redis:6379"
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
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
          env_from {
            secret_ref {
              name = "trading-bot-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "trading-bot-db-creds"
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    # DRIFT_WORKAROUND: CI pipeline owns image tags for all 6 worker containers. Reviewed 2026-04-18.
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].container[1].image,
      spec[0].template[0].spec[0].container[2].image,
      spec[0].template[0].spec[0].container[3].image,
      spec[0].template[0].spec[0].container[4].image,
      spec[0].template[0].spec[0].container[5].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
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
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.trading-bot.metadata[0].name
  name            = "trading"
  service_name    = "trading-bot-frontend"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Trading Bot"
    "gethomepage.dev/description"  = "Automated trading"
    "gethomepage.dev/icon"         = "mdi-chart-line"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}
*/
