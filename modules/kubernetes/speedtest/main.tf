variable "tls_secret_name" {}
variable "tier" { type = string }
variable "db_password" { type = string }


resource "kubernetes_namespace" "speedtest" {
  metadata {
    name = "speedtest"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.speedtest.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_id" "secret_key" {
  byte_length = 32 # 32 bytes × 2 hex chars = 64 hex characters
}

resource "kubernetes_deployment" "speedtest" {
  metadata {
    name      = "speedtest"
    namespace = kubernetes_namespace.speedtest.metadata[0].name
    labels = {
      app  = "speedtest"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "speedtest"
      }
    }
    template {
      metadata {
        labels = {
          app = "speedtest"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/speedtest-tracker:latest"
          name  = "speedtest"
          port {
            container_port = 80
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
            name  = "APP_KEY"
            value = "base64:${random_id.secret_key.b64_std}"
          }
          env {
            name  = "SPEEDTEST_SCHEDULE"
            value = "0 * * * *"
          }
          #   env {
          #     name = "SPEEDTEST_SERVERS"
          #     # Sofia speedtest servers - https://c.speedtest.net/speedtest-servers-static.php
          #     value = "7617,17787,11348,37980,54640,27843,57118,10754,20191,29617"
          #   }
          env {
            name  = "APP_URL"
            value = "https://speedtest.viktorbarzin.me"
          }
          env {
            name  = "DB_CONNECTION"
            value = "mysql"
          }
          env {
            name  = "DB_HOST"
            value = "mysql.dbaas.svc.cluster.local"
          }
          env {
            name  = "DB_DATABASE"
            value = "speedtest"
          }
          env {
            name  = "DB_USERNAME"
            value = "speedtest"
          }
          env {
            name  = "DB_PASSWORD"
            value = var.db_password
          }
          env {
            name  = "APP_TIMEZONE"
            value = "Europe/Sofia"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }
        volume {
          name = "config"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/speedtest"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "speedtest" {
  metadata {
    name      = "speedtest"
    namespace = kubernetes_namespace.speedtest.metadata[0].name
    labels = {
      "app" = "speedtest"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/prometheus"
      "prometheus.io/port"   = "80"
    }
  }

  spec {
    selector = {
      app = "speedtest"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.speedtest.metadata[0].name
  name            = "speedtest"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
