# To refresh transactions use finance db positions exporters:
#
# workon finace-app && cd ~/code/finance && python main.py fetch position --imap-user=$IMAP_USER --imap-password=$IMAP_PASSWORD --trading212-api-keys=$TRADING212_API_KEYS --output-file positions.csv && mv positions.csv /home/wizard/code/infra/modules/kubernetes/wealthfolio/updated_trades.csv
#
# Then upload updated_trades.csv
# Note that currently wealthfolio doesn't dedup (https://github.com/afadil/wealthfolio/issues/476)

variable "tls_secret_name" {}
variable "wealthfolio_password_hash" {}

resource "kubernetes_namespace" "wealthfolio" {
  metadata {
    name = "wealthfolio"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "wealthfolio"
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

resource "kubernetes_deployment" "wealthfolio" {
  metadata {
    name      = "wealthfolio"
    namespace = "wealthfolio"
    labels = {
      app = "wealthfolio"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "wealthfolio"
      }
    }
    template {
      metadata {
        labels = {
          app = "wealthfolio"
        }
      }
      spec {
        container {
          image = "afadil/wealthfolio:latest"
          name  = "wealthfolio"
          port {
            container_port = 8080
          }
          env {
            name  = "WF_LISTEN_ADDR"
            value = "0.0.0.0:8080"
          }
          env {
            name  = "WF_AUTH_PASSWORD_HASH"
            value = var.wealthfolio_password_hash
          }
          env {
            name  = "WF_DB_PATH"
            value = "/data/wealthfolio.db"
          }
          env {
            name  = "WF_CORS_ALLOW_ORIGINS"
            value = "https://authentik.viktorbarzin.me"
          }
          env {
            name  = "WF_AUTH_TOKEN_TTL_MINUTES"
            value = "10080"
          }
          env {
            name  = "WF_SECRET_KEY"
            value = random_string.random.result
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/wealthfolio"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wealthfolio" {
  metadata {
    name      = "wealthfolio"
    namespace = "wealthfolio"
    labels = {
      "app" = "wealthfolio"
    }
  }

  spec {
    selector = {
      app = "wealthfolio"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "wealthfolio"
  name            = "wealthfolio"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
