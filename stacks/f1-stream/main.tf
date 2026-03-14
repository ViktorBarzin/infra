variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "discord_user_token" {
  type      = string
  sensitive = true
}
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

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "f1-stream-data"
  namespace  = kubernetes_namespace.f1-stream.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/f1-stream"
}

resource "kubernetes_deployment" "f1-stream" {
  metadata {
    name      = "f1-stream"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 0 # Scaled down for cluster stability — periodic scans cause memory pressure
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
              memory = "64Mi"
            }
          }
          port {
            container_port = 8000
          }
          env {
            name  = "DISCORD_TOKEN"
            value = var.discord_user_token
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
            claim_name = module.nfs_data.claim_name
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
