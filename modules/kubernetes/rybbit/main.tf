variable "tls_secret_name" {}
variable "tier" { type = string }
variable "clickhouse_password" { type = string }
variable "postgres_password" { type = string }

resource "kubernetes_namespace" "rybbit" {
  metadata {
    name = "rybbit"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
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


resource "kubernetes_deployment" "clickhouse" {
  metadata {
    name      = "clickhouse"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "clickhouse"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
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
          # env {
          #   name  = "CLICKHOUSE_USER"
          #   value = "clickhouse"
          # }
          env {
            name  = "CLICKHOUSE_PASSWORD"
            value = var.clickhouse_password
          }
          port {
            name           = "clickhouse"
            protocol       = "TCP"
            container_port = 8123
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/clickhouse"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/clickhouse"
            server = "10.0.10.15"
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

resource "kubernetes_deployment" "rybbit" {
  metadata {
    name      = "rybbit"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "rybbit"
      tier = var.tier
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
            value = "postgresql.dbaas.svc.cluster.local"
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
            value = var.postgres_password
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
      tier = var.tier
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  name            = "rybbit"
  service_name    = "rybbit-client"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "3c476801a777"
}

module "ingress-api" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.rybbit.metadata[0].name
  name            = "rybbit-api"
  host            = "rybbit"
  service_name    = "rybbit"
  ingress_path    = ["/api"]
  tls_secret_name = var.tls_secret_name
}
