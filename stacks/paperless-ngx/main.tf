variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "paperless-ngx"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "paperless-ngx" {
  metadata {
    name = "paperless-ngx"
    labels = {
      tier = local.tiers.edge
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "paperless-ngx-secrets"
      namespace = "paperless-ngx"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "paperless-ngx-secrets"
      }
      dataFrom = [{
        extract = {
          key = "paperless-ngx"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.paperless-ngx]
}
module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.paperless-ngx.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "paperless-ngx-data-proxmox"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
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


resource "kubernetes_deployment" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app  = "paperless-ngx"
      tier = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "paperless-ngx"
      }
    }
    template {
      metadata {
        labels = {
          app = "paperless-ngx"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis.redis:6379"
        }
      }
      spec {
        container {
          image = "ghcr.io/paperless-ngx/paperless-ngx:2.20.14"
          name  = "paperless-ngx"
          env {
            name = "PAPERLESS_REDIS"
            // If redis gets stuck, try deleting the locks files in log dir
            value = "redis://${var.redis_host}"
          }
          env {
            name  = "PAPERLESS_REDIS_PREFIX"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBENGINE"
            value = "mariadb"
          }
          env {
            name  = "PAPERLESS_DBHOST"
            value = var.mysql_host
          }
          env {
            name  = "PAPERLESS_DBNAME"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBUSER"
            value = "paperless-ngx"
          }
          env {
            name = "PAPERLESS_DBPASS"
            value_from {
              secret_key_ref {
                name = "paperless-ngx-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "PAPERLESS_CSRF_TRUSTED_ORIGINS"
            value = "https://paperless-ngx.viktorbarzin.me,https://pdf.viktorbarzin.me"
          }
          env {
            name  = "PAPERLESS_DEBUG"
            value = "false"
          }
          env {
            name  = "PAPERLESS_MEDIA_ROOT"
            value = "../data"
          }
          env {
            name  = "PAPERLESS_OCR_USER_ARGS"
            value = "{\"invalidate_digital_signatures\": true}"
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/src/paperless/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "2Gi"
            }
            limits = {
              memory = "2Gi"
            }
          }

          port {
            container_port = 8000
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

resource "kubernetes_service" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      "app" = "paperless-ngx"
    }
  }

  spec {
    selector = {
      app = "paperless-ngx"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.paperless-ngx.metadata[0].name
  name            = "paperless-ngx"
  service_name    = "paperless-ngx"
  host            = "pdf"
  dns_type        = "proxied"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Document library"
    "gethomepage.dev/group"       = "Productivity"
    "gethomepage.dev/icon" : "paperless-ngx.png"
    "gethomepage.dev/name"        = "Paperless-ngx"
    "gethomepage.dev/widget.type" = "paperlessngx"
    "gethomepage.dev/widget.url"  = "http://paperless-ngx.paperless-ngx.svc.cluster.local"
    # "gethomepage.dev/widget.token"    = var.homepage_token
    "gethomepage.dev/widget.username" = local.homepage_credentials["paperless-ngx"]["username"]
    "gethomepage.dev/widget.password" = local.homepage_credentials["paperless-ngx"]["password"]
    "gethomepage.dev/widget.fields"   = "[\"total\"]"
    "gethomepage.dev/pod-selector"    = ""
    # gethomepage.dev/weight: 10 # optional
    # gethomepage.dev/instance: "public" # optional
  }
}
