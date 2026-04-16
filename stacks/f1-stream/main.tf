variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "discord_f1_guild_id" { type = string }
variable "discord_f1_channel_ids" { type = string }

resource "kubernetes_namespace" "f1-stream" {
  metadata {
    name = "f1-stream"
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
      name      = "f1-stream-secrets"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "f1-stream-secrets"
      }
      dataFrom = [{
        extract = {
          key = "f1-stream"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "f1-stream-data-proxmox"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
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

resource "kubernetes_deployment" "f1-stream" {
  metadata {
    name      = "f1-stream"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
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
        app = "f1-stream"
      }
    }
    template {
      metadata {
        labels = {
          app = "f1-stream"
        }
      }
      spec {
        container {
          image             = "viktorbarzin/f1-stream:latest"
          image_pull_policy = "Always"
          name              = "f1-stream"
          resources {
            limits = {
              memory = "256Mi"
            }
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
          }
          port {
            container_port = 8000
          }
          env {
            name = "DISCORD_TOKEN"
            value_from {
              secret_key_ref {
                name = "f1-stream-secrets"
                key  = "discord_user_token"
              }
            }
          }
          env {
            name  = "DISCORD_CHANNELS"
            value = var.discord_f1_channel_ids
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
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


resource "kubernetes_service" "f1-stream" {
  metadata {
    name      = "f1"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      "app" = "f1-stream"
    }
  }

  spec {
    selector = {
      app = "f1-stream"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace        = kubernetes_namespace.f1-stream.metadata[0].name
  name             = "f1"
  tls_secret_name  = var.tls_secret_name
  rybbit_site_id   = "7e69786f66d5"
  exclude_crowdsec = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "F1 Stream"
    "gethomepage.dev/description"  = "Formula 1 live streams"
    "gethomepage.dev/icon"         = "si-f1"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
