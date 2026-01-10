variable "tls_secret_name" {}
variable "tier" { type = string }
variable "aiostreams_database_connection_string" { type = string }

resource "kubernetes_namespace" "aiostreams" {
  metadata {
    name = "aiostreams"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

resource "random_id" "secret_key" {
  byte_length = 32 # 32 bytes × 2 hex chars = 64 hex characters
}

resource "kubernetes_deployment" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
    labels = {
      app  = "aiostreams"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "aiostreams"
      }
    }
    template {
      metadata {
        labels = {
          app = "aiostreams"
        }
      }
      spec {
        container {
          image = "viren070/aiostreams:nightly"
          name  = "aiostreams"
          port {
            container_port = 3000
          }
          env {
            name  = "BASE_URL"
            value = "https://aiostreams.viktorbarzin.me"
          }
          env {
            name  = "SECRET_KEY"
            value = random_id.secret_key.hex
          }
          env {
            name  = "DATABASE_URI"
            value = var.aiostreams_database_connection_string
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/servarr/aiostreams"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
    labels = {
      "app" = "aiostreams"
    }
  }

  spec {
    selector = {
      app = "aiostreams"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../ingress_factory"
  namespace       = kubernetes_namespace.aiostreams.metadata[0].name
  name            = "aiostreams"
  tls_secret_name = var.tls_secret_name
  #   protected       = true
}
