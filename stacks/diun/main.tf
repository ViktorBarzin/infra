variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "diun" {
  metadata {
    name = "diun"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "diun-secrets"
      namespace = "diun"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "diun-secrets"
      }
      dataFrom = [{
        extract = {
          key = "diun"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.diun]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.diun.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service_account" "diun" {
  metadata {
    name      = "diun"
    namespace = kubernetes_namespace.diun.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "diun" {
  metadata {
    name = "diun"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }
}
resource "kubernetes_cluster_role_binding" "diun" {
  metadata {
    name = "diun"

  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "diun"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "diun"
    namespace = kubernetes_namespace.diun.metadata[0].name
  }
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "diun-data-proxmox"
    namespace = kubernetes_namespace.diun.metadata[0].name
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

resource "kubernetes_deployment" "diun" {
  metadata {
    name      = "diun"
    namespace = kubernetes_namespace.diun.metadata[0].name
    labels = {
      app  = "diun"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "diun.enable"                  = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "diun"
      }
    }
    template {
      metadata {
        labels = {
          app = "diun"
        }
      }
      spec {
        service_account_name = "diun"
        container {
          image = "viktorbarzin/diun:latest"
          name  = "diun"
          args  = ["serve"]
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "DIUN_WATCH_WORKERS"
            value = "20"
          }
          env {
            name  = "DIUN_WATCH_SCHEDULE"
            value = "0 */6 * * *"
          }
          env {
            name  = "DIUN_WATCH_JITTER"
            value = "30s"
          }
          env {
            name  = "DIUN_PROVIDERS_KUBERNETES"
            value = "true"
          }
          env {
            name  = "DIUN_DEFAULTS_WATCHREPO"
            value = "true"
          }
          env {
            name  = "DIUN_DEFAULTS_MAXTAGS"
            value = "3"
          }
          env {
            name  = "DIUN_DEFAULTS_SORTTAGS"
            value = "reverse"
          }
          # Webhook notifier for upgrade agent (via n8n)
          env {
            name = "DIUN_NOTIF_WEBHOOK_ENDPOINT"
            value_from {
              secret_key_ref {
                name = "diun-secrets"
                key  = "n8n_webhook_url"
              }
            }
          }
          env {
            name  = "DIUN_NOTIF_WEBHOOK_METHOD"
            value = "POST"
          }
          env {
            name  = "DIUN_NOTIF_WEBHOOK_HEADERS_CONTENT-TYPE"
            value = "application/json"
          }
          # Slack notifier (independent notification channel)
          env {
            name = "DIUN_NOTIF_SLACK_WEBHOOKURL"
            value_from {
              secret_key_ref {
                name = "diun-secrets"
                key  = "slack_url"
              }
            }
          }
          env {
            name  = "LOG_LEVEL"
            value = "debug"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
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
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
