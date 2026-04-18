variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "mail_host" { type = string }

resource "kubernetes_namespace" "tandoor" {
  metadata {
    name = "tandoor"
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
      name      = "tandoor-secrets"
      namespace = "tandoor"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tandoor-secrets"
      }
      dataFrom = [{
        extract = {
          key = "tandoor"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.tandoor]
}

resource "random_password" "secret_key" {
  length  = 128
  special = false
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.tandoor.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "tandoor-data-proxmox"
    namespace = kubernetes_namespace.tandoor.metadata[0].name
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

resource "kubernetes_deployment" "tandoor" {
  metadata {
    name      = "tandoor"
    namespace = kubernetes_namespace.tandoor.metadata[0].name
    labels = {
      app  = "tandoor"
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
        app = "tandoor"
      }
    }
    template {
      metadata {
        labels = {
          app = "tandoor"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        container {
          name              = "recipes"
          image             = "vabene1111/recipes:1.5.27"
          image_pull_policy = "IfNotPresent"
          env {
            name  = "SECRET_KEY"
            value = base64encode(random_password.secret_key.result)
          }
          env {
            name  = "DB_ENGINE"
            value = "django.db.backends.postgresql"
          }
          env {
            name  = "POSTGRES_HOST"
            value = var.postgresql_host
          }
          env {
            name  = "POSTGRES_PORT"
            value = 5432
          }
          env {
            name  = "POSTGRES_USER"
            value = "tandoor"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "tandoor-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "TANDOOR_PORT"
            value = 8080
          }
          env {
            name  = "ENABLE_SIGNUP"
            value = 1
          }
          env {
            name  = "ALLOWED_HOSTS"
            value = "tandoor.viktorbarzin.me"
          }
          env {
            name  = "POSTGRES_DB"
            value = "tandoor"
          }
          env {
            name  = "EMAIL_HOST"
            value = var.mail_host
          }
          env {
            name  = "EMAIL_HOST_USER"
            value = "info@viktorbarzin.me"
          }
          env {
            name = "EMAIL_HOST_PASSWORD"
            value_from {
              secret_key_ref {
                name     = "tandoor-secrets"
                key      = "email_password"
                optional = true
              }
            }
          }
          env {
            name  = "EMAIL_USE_TLS"
            value = "1"
          }
          env {
            name  = "DEFAULT_FROM_EMAIL"
            value = "info@viktorbarzin.me"
          }
          env {
            name  = "EMAIL_PORT"
            value = 587
          }
          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          volume_mount {
            name       = "data"
            mount_path = "/opt/recipes/mediafiles"
          }
          volume_mount {
            name       = "data"
            mount_path = "/opt/recipes/staticfiles"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "384Mi"
            }
            limits = {
              memory = "512Mi"
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

resource "kubernetes_service" "tandoor" {
  metadata {
    name      = "tandoor"
    namespace = kubernetes_namespace.tandoor.metadata[0].name
    labels = {
      "app" = "tandoor"
    }
  }

  spec {
    selector = {
      app = "tandoor"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.tandoor.metadata[0].name
  name            = "tandoor"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Tandoor"
    "gethomepage.dev/description"  = "Recipe manager"
    "gethomepage.dev/icon"         = "tandoor-recipes.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}
