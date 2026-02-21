variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "netbox" {
  metadata {
    name = "netbox"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.netbox.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 50
  lower  = true
}
resource "random_string" "api_token_pepper" {
  length = 50
  lower  = true
}

resource "kubernetes_deployment" "netbox" {
  metadata {
    name      = "netbox"
    namespace = kubernetes_namespace.netbox.metadata[0].name
    labels = {
      app  = "netbox"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "netbox"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable" = "true"
        }
        labels = {
          app = "netbox"
        }
      }
      spec {
        container {
          image = "netboxcommunity/netbox:v4.5.0-beta1"
          name  = "netbox"
          env {
            name  = "DB_USER"
            value = "netbox"
          }
          env {
            name  = "DB_PASSWORD"
            value = "ttPSBjF9oPLb49XZst3sGF"
          }
          env {
            name  = "DB_HOST"
            value = "postgresql.dbaas.svc.cluster.local"
          }
          env {
            name  = "DB_NAME"
            value = "netbox"
          }
          env {
            name  = "DB_WAIT_DEBUG"
            value = "1"
          }
          env {
            name  = "SECRET_KEY"
            value = random_string.random.result
          }
          env {
            name  = "API_TOKEN_PEPPERS"
            value = random_string.api_token_pepper.result
          }
          env {
            name  = "REDIS_HOST"
            value = "redis.redis"
          }
          env {
            name  = "ALLOWED_HOST"
            value = "netbox.viktorbarzin.me"
          }
          env {
            name  = "SUPERUSER_EMAIL"
            value = "me@viktorbarzin.me"
          }
          env {
            name  = "SUPERUSER_PASSWORD"
            value = "ttPSBjF9oPLb49XZst3sGFasdf"
          }
          env {
            name  = "REMOTE_AUTH_ENABLED"
            value = "True"
          }
          env {
            name  = "REMOTE_AUTH_AUTO_CREATE_USER"
            value = "True"
          }

          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }

          port {
            container_port = 8080
          }
          #   volume_mount {
          #     name       = "data"
          #     mount_path = "/books"
          #   }
        }
        # volume {
        #   name = "data"
        #   nfs {
        #     path   = "/mnt/main/netbox"
        #     server = "10.0.10.15"
        #   }
        # }
      }
    }
  }
}
resource "kubernetes_service" "netbox" {
  metadata {
    name      = "netbox"
    namespace = kubernetes_namespace.netbox.metadata[0].name
    labels = {
      "app" = "netbox"
    }
  }

  spec {
    selector = {
      app = "netbox"
    }
    port {
      name        = "http"
      target_port = 8080
      port        = 80
      protocol    = "TCP"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.netbox.metadata[0].name
  name            = "netbox"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
