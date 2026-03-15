variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }

resource "kubernetes_namespace" "health" {
  metadata {
    name = "health"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.health.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_uploads" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "health-uploads"
  namespace  = kubernetes_namespace.health.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/health"
}

resource "kubernetes_deployment" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app  = "health"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "health"
      }
    }
    template {
      metadata {
        labels = {
          app = "health"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        container {
          name  = "health"
          image = "viktorbarzin/health:latest"

          port {
            container_port = 3000
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "health-secrets"
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "health-secrets"
                key  = "secret_key"
              }
            }
          }
          env {
            name  = "UPLOAD_DIR"
            value = "/data/uploads"
          }
          env {
            name  = "WEBAUTHN_RP_ID"
            value = "health.viktorbarzin.me"
          }
          env {
            name  = "WEBAUTHN_ORIGIN"
            value = "https://health.viktorbarzin.me"
          }
          env {
            name  = "COOKIE_SECURE"
            value = "true"
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/data/uploads"
          }

          resources {
            requests = {
              memory = "128Mi"
              cpu    = "15m"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = module.nfs_uploads.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app = "health"
    }
  }

  spec {
    selector = {
      app = "health"
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
  namespace       = kubernetes_namespace.health.metadata[0].name
  name            = "health"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "100m"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Health"
    "gethomepage.dev/description"  = "Health dashboard"
    "gethomepage.dev/icon"         = "healthchecks.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "health-secrets"
      namespace = "health"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "health-secrets"
        template = {
          data = {
            DATABASE_URL = "postgresql+asyncpg://health:{{ .db_password }}@postgresql.dbaas.svc.cluster.local:5432/health"
            secret_key   = "{{ .secret_key }}"
          }
        }
      }
      data = [
        {
          secretKey = "db_password"
          remoteRef = { key = "health", property = "db_password" }
        },
        {
          secretKey = "secret_key"
          remoteRef = { key = "health", property = "secret_key" }
        }
      ]
    }
  }
  depends_on = [kubernetes_namespace.health]
}
