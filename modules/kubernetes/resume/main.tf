variable "tls_secret_name" { type = string }
variable "tier" { type = string }
variable "database_url" { type = string }
variable "redis_url" { type = string }
variable "db_password" { type = string }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.resume.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "resume" {
  metadata {
    name = "resume"
  }
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

resource "kubernetes_deployment" "resume" {
  metadata {
    name      = "resume"
    namespace = kubernetes_namespace.resume.metadata[0].name
    labels = {
      app  = "resume"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "resume"
      }
    }
    template {
      metadata {
        labels = {
          app = "resume"
        }
      }
      spec {
        container {
          image = "amruthpillai/reactive-resume:server-latest"
          name  = "resume"
          env {
            name  = "DATABASE_URL"
            value = var.database_url
          }
          env {
            name  = "REDIS_URL"
            value = var.redis_url
          }
          env {
            name  = "PUBLIC_URL"
            value = "https://resume.viktorbarzin.me"
          }
          env {
            name  = "PUBLIC_SERVER_URL"
            value = "https://resume.viktorbarzin.me"
          }

          env {
            name  = "POSTGRES_HOST"
            value = "postgresql.dbaas.svc.cluster.local"
          }
          env {
            name  = "POSTGRES_DB"
            value = "resume"
          }
          env {
            name  = "POSTGRES_USER"
            value = "resume"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = var.db_password
          }
          env {
            name  = "JWT_SECRET"
            value = random_string.random.result
          }
          env {
            name  = "AUTH_SECRET"
            value = random_string.random.result
          }
          env {
            name  = "SECRET_KEY"
            value = random_string.random.result
          }
          env {
            name  = "JWT_EXPIRY_TIME"
            value = 604800
          }
          env {
            name  = "STORAGE_ENDPOINT"
            value = "https://resume.viktorbarzin.me"
          }
          // There's a tone of these... I give up...
          // check https://github.com/AmruthPillai/Reactive-Resume/blob/main/.env.example

          port {
            container_port = 3000
          }
          port {
            container_port = 3100
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "resume" {
  metadata {
    name      = "resume"
    namespace = kubernetes_namespace.resume.metadata[0].name
    labels = {
      "app" = "resume"
    }
  }

  spec {
    selector = {
      app = "resume"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.resume.metadata[0].name
  name            = "resume"
  tls_secret_name = var.tls_secret_name
}
