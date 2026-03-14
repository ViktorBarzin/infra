variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "forgejo"
}

resource "kubernetes_namespace" "forgejo" {
  metadata {
    name = "forgejo"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.forgejo.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "forgejo-data"
  namespace  = kubernetes_namespace.forgejo.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/forgejo"
}

resource "kubernetes_deployment" "forgejo" {
  metadata {
    name      = "forgejo"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
    labels = {
      app  = "forgejo"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate" # DB is external so we can roll
    }
    selector {
      match_labels = {
        app = "forgejo"
      }
    }
    template {
      metadata {
        labels = {
          app = "forgejo"
        }
      }
      spec {
        container {
          name  = "forgejo"
          image = "codeberg.org/forgejo/forgejo:11"
          env {
            name  = "USER_UID"
            value = 1000
          }
          env {
            name  = "USER_GID"
            value = 1000
          }
          # Root URL for OAuth2 redirect callbacks
          env {
            name  = "FORGEJO__server__ROOT_URL"
            value = "https://forgejo.viktorbarzin.me"
          }
          # Disable local registration — only allow OAuth2 (Authentik)
          env {
            name  = "FORGEJO__service__DISABLE_REGISTRATION"
            value = "false"
          }
          env {
            name  = "FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION"
            value = "true"
          }
          env {
            name  = "FORGEJO__openid__ENABLE_OPENID_SIGNIN"
            value = "false"
          }
          # Allow webhook delivery to internal k8s services
          env {
            name  = "FORGEJO__webhook__ALLOWED_HOST_LIST"
            value = "*.svc.cluster.local"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
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

resource "kubernetes_service" "forgejo" {
  metadata {
    name      = "forgejo"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
    labels = {
      "app" = "forgejo"
    }
  }

  spec {
    selector = {
      app = "forgejo"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.forgejo.metadata[0].name
  name            = "forgejo"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Forgejo"
    "gethomepage.dev/description"  = "Git hosting"
    "gethomepage.dev/icon"         = "forgejo.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
