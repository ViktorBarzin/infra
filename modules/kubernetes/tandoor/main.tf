variable "tls_secret_name" {}
variable "tier" { type = string }
variable "tandoor_database_password" {}
variable "tandoor_email_password" {}

resource "kubernetes_namespace" "tandoor" {
  metadata {
    name = "tandoor"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}
resource "random_password" "secret_key" {
  length  = 128
  special = false
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.tandoor.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "tandoor" {
  metadata {
    name      = "tandoor"
    namespace = kubernetes_namespace.tandoor.metadata[0].name
    labels = {
      app  = "tandoor"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "tandoor"
      }
    }
    template {
      metadata {
        labels = {
          app = "tandoor"
        }
      }
      spec {
        container {
          name              = "recipes"
          image             = "vabene1111/recipes"
          image_pull_policy = "IfNotPresent"
          env {
            name  = "SECRET_KEY"
            value = base64encode(random_password.secret_key.result)
          }
          env {
            name  = "DB_ENGINE"
            value = "django.db.backends.postgresql"
          }
          env {
            name  = "POSTGRES_HOST"
            value = "postgresql.dbaas.svc.cluster.local"
          }
          env {
            name  = "POSTGRES_PORT"
            value = 5432
          }
          env {
            name  = "POSTGRES_USER"
            value = "tandoor"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = var.tandoor_database_password
          }
          env {
            name  = "TANDOOR_PORT"
            value = 8080
          }
          env {
            name  = "ENABLE_SIGNUP"
            value = 1
          }
          env {
            name  = "ALLOWED_HOSTS"
            value = "tandoor.viktorbarzin.me"
          }
          env {
            name  = "POSTGRES_DB"
            value = "tandoor"
          }
          env {
            name  = "EMAIL_HOST"
            value = "mail.viktorbarzin.me"
          }
          env {
            name  = "EMAIL_HOST_USER"
            value = "info@viktorbarzin.me"
          }
          env {
            name  = "EMAIL_HOST_PASSWORD"
            value = var.tandoor_email_password
          }
          env {
            name  = "EMAIL_USE_TLS"
            value = "1"
          }
          env {
            name  = "DEFAULT_FROM_EMAIL"
            value = "info@viktorbarzin.me"
          }
          env {
            name  = "EMAIL_PORT"
            value = 587
          }
          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          volume_mount {
            name       = "data"
            mount_path = "/opt/recipes/mediafiles"
          }
          volume_mount {
            name       = "data"
            mount_path = "/opt/recipes/staticfiles"
          }
        }

        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/tandoor"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "tandoor" {
  metadata {
    name      = "tandoor"
    namespace = kubernetes_namespace.tandoor.metadata[0].name
    labels = {
      "app" = "tandoor"
    }
  }

  spec {
    selector = {
      app = "tandoor"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.tandoor.metadata[0].name
  name            = "tandoor"
  tls_secret_name = var.tls_secret_name
}
