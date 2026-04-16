variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "novelapp-secrets"
      namespace = "novelapp"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "novelapp-secrets"
      }
      dataFrom = [{
        extract = {
          key = "novelapp"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.novelapp]
}

resource "kubernetes_namespace" "novelapp" {
  metadata {
    name = "novelapp"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.novelapp.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "novelapp-data" {
  metadata {
    name      = "novelapp-data-proxmox"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
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

resource "kubernetes_deployment" "novelapp" {
  metadata {
    name      = "novelapp"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
    labels = {
      app  = "novelapp"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
    ]
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "novelapp"
      }
    }
    template {
      metadata {
        labels = {
          app = "novelapp"
        }
      }
      spec {
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.novelapp-data.metadata[0].name
          }
        }
        container {
          image             = "mghee/novelapp:latest"
          name              = "novelapp"
          image_pull_policy = "Always"
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "DB_PATH"
            value = "/app/data/novelapp.db"
          }
          env {
            name  = "DISABLE_BROWSER_SCRAPING"
            value = "true"
          }
          env {
            name  = "PORT"
            value = "3000"
          }
          env {
            name  = "AUTH_URL"
            value = "https://novelapp.viktorbarzin.me"
          }
          env {
            name = "AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = "novelapp-secrets"
                key  = "auth_secret"
              }
            }
          }
          env {
            name  = "AUTH_TRUST_HOST"
            value = "true"
          }
          env {
            name = "GOOGLE_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "novelapp-secrets"
                key  = "google_client_id"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "novelapp-secrets"
                key  = "google_client_secret"
              }
            }
          }
          env {
            name  = "ALLOWED_ORIGIN"
            value = "https://novelapp.viktorbarzin.me"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
          port {
            container_port = 3000
          }
          resources {
            requests = {
              memory = "640Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "640Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "novelapp" {
  metadata {
    name      = "novelapp"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
    labels = {
      "app" = "novelapp"
    }
  }

  spec {
    selector = {
      app = "novelapp"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.novelapp.metadata[0].name
  name            = "novelapp"
  tls_secret_name = var.tls_secret_name

  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "NovelApp"
    "gethomepage.dev/description"  = "Web novel tracker"
    "gethomepage.dev/icon"         = "mdi-book-open-page-variant"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# RBAC — grant vabbit81 (Gheorghe) admin access to novelapp namespace
resource "kubernetes_role_binding" "novelapp_owner_vabbit81" {
  metadata {
    name      = "novelapp-owner-vabbit81"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = "vabbit81@gmail.com"
  }
}

# Sealed Secrets — encrypted secrets safe to commit to git
resource "kubernetes_manifest" "sealed_secrets" {
  for_each = fileset(path.module, "sealed-*.yaml")
  manifest = yamldecode(file("${path.module}/${each.value}"))
}
