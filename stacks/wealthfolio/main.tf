variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "wealthfolio" {
  metadata {
    name = "wealthfolio"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "wealthfolio-secrets"
      namespace = "wealthfolio"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "wealthfolio-secrets"
      }
      dataFrom = [{
        extract = {
          key = "wealthfolio"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.wealthfolio]
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

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "wealthfolio-data-proxmox"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "wealthfolio" {
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
  metadata {
    name      = "wealthfolio"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
    labels = {
      app  = "wealthfolio"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v?\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "afadil/wealthfolio:3.2"
          name  = "wealthfolio"
          port {
            container_port = 8080
          }
          env {
            name  = "WF_LISTEN_ADDR"
            value = "0.0.0.0:8080"
          }
          env {
            name = "WF_AUTH_PASSWORD_HASH"
            value_from {
              secret_key_ref {
                name = "wealthfolio-secrets"
                key  = "password_hash"
              }
            }
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
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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
  dns_type        = "proxied"
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

resource "kubernetes_cron_job_v1" "wealthfolio_sync" {
  metadata {
    name      = "wealthfolio-sync"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }
  spec {
    schedule                      = "0 8 1 * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "sync"
              image = "registry.viktorbarzin.me/wealthfolio-sync:latest"
              env {
                name = "IMAP_HOST"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_host"
                  }
                }
              }
              env {
                name = "IMAP_USER"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_user"
                  }
                }
              }
              env {
                name = "IMAP_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_password"
                  }
                }
              }
              env {
                name = "IMAP_DIRECTORY"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "imap_directory"
                  }
                }
              }
              env {
                name = "TRADING212_API_KEYS"
                value_from {
                  secret_key_ref {
                    name = "wealthfolio-secrets"
                    key  = "trading212_api_keys"
                  }
                }
              }
              env {
                name  = "DB_PATH"
                value = "/data/wealthfolio.db"
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}
