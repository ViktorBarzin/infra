variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "wealthfolio"
}

# To refresh transactions use finance db positions exporters:
#
# workon finace-app && cd ~/code/finance && python main.py fetch position --imap-user=$IMAP_USER --imap-password=$IMAP_PASSWORD --trading212-api-keys=$TRADING212_API_KEYS --output-file positions.csv && mv positions.csv /home/wizard/code/infra/modules/kubernetes/wealthfolio/updated_trades.csv
#
# Then upload updated_trades.csv
# Note that currently wealthfolio doesn't dedup (https://github.com/afadil/wealthfolio/issues/476)

resource "kubernetes_namespace" "wealthfolio" {
  metadata {
    name = "wealthfolio"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.wealthfolio.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "random" {
  length = 32
  lower  = true
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "wealthfolio-data"
  namespace  = kubernetes_namespace.wealthfolio.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/wealthfolio"
}

resource "kubernetes_deployment" "wealthfolio" {
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    labels = {
      app  = "wealthfolio"
      tier = local.tiers.aux
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
            value = data.vault_kv_secret_v2.secrets.data["password_hash"]
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
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wealthfolio" {
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.wealthfolio.metadata[0].name
  name            = "wealthfolio"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Wealthfolio"
    "gethomepage.dev/description"  = "Investment portfolio tracker"
    "gethomepage.dev/icon"         = "mdi-finance"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}
