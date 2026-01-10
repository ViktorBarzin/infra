variable "tls_secret_name" {}
variable "tier" { type = string }
variable "clickhouse_password" { type = string }
variable "postgres_password" { type = string }

resource "kubernetes_namespace" "rybbit" {
  metadata {
    name = "rybbit"
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


resource "kubernetes_ingress_v1" "rybbit" {
  metadata {
    name      = "rybbit"
    namespace = kubernetes_namespace.rybbit.metadata[0].name

    annotations = {
      "kubernetes.io/ingress.class"           = "nginx"
      "nginx.ingress.kubernetes.io/use-regex" = "true"
      # Optional: enable SSL redirect
      #"nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"

      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-EOF
        limit_req_status 429;
        limit_conn_status 429;

        # Rybbit Analytics
        # Only modify HTML
        sub_filter_types text/html;
        sub_filter_once off;

        # Disable compression so sub_filter works
        proxy_set_header Accept-Encoding "";

        # Inject analytics before </head>
        sub_filter '</head>' '
        <script src="https://rybbit.viktorbarzin.me/api/script.js"
              data-site-id="3c476801a777"
              defer></script> 
        </head>';
      EOF
    }
  }

  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = ["rybbit.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "rybbit.viktorbarzin.me"

      http {
        # API backend
        path {
          path = "/api(/|$)(.*)"
          backend {
            service {
              name = "rybbit"
              port {
                number = 80
              }
            }
          }
        }

        # Frontend
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "rybbit-client"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
