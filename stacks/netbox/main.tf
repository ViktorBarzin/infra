variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }

resource "kubernetes_namespace" "netbox" {
  metadata {
    name = "netbox"
    labels = {
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
      name      = "netbox-secrets"
      namespace = "netbox"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "netbox-secrets"
      }
      dataFrom = [{
        extract = {
          key = "netbox"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.netbox]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
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
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    # Disabled: reduce cluster memory pressure (2026-03-14 OOM incident)
    replicas = 0
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
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "netbox-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "DB_HOST"
            value = var.postgresql_host
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
            value = var.redis_host
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
            name = "SUPERUSER_PASSWORD"
            value_from {
              secret_key_ref {
                name = "netbox-secrets"
                key  = "superuser_password"
              }
            }
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

          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
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
        #     server = var.nfs_server
        #   }
        # }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.netbox.metadata[0].name
  name            = "netbox"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Netbox"
    "gethomepage.dev/description"  = "Network documentation"
    "gethomepage.dev/icon"         = "netbox.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
