variable "tls_secret_name" {}
variable "database_url" {}
variable "redis_url" {}

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

resource "kubernetes_deployment" "resume" {
  metadata {
    name      = "resume"
    namespace = kubernetes_namespace.resume.metadata[0].name
    labels = {
      app = "resume"
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
            name  = "JWT_SECRET"
            value = "kek"
          }
          env {
            name  = "JWT_EXPIRY_TIME"
            value = 604800
          }
          env {
            name  = "STORAGE_ENDPOINT"
            value = "https://resume.viktorbarzin.me"
          }
          env {
            name  = "STORAGE_PORT"
            value = 443
          }
          // There's a tone of these... I give up...
          // check https://github.com/AmruthPillai/Reactive-Resume/blob/main/.env.example

          port {
            container_port = 3000
          }
          # volume_mount {
          #   name       = "config"
          #   mount_path = "/app/public/"
          # }
        }
        # volume {
        #   name = "config"
        #   config_map {
        #     name = "config"
        #   }
        # }
      }
    }
  }
}
