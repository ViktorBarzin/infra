variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "linkwarden"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "linkwarden" {
  metadata {
    name = "linkwarden"
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
      name      = "linkwarden-secrets"
      namespace = "linkwarden"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "linkwarden-secrets"
      }
      dataFrom = [{
        extract = {
          key = "linkwarden"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.linkwarden]
}

# DB credentials from Vault database engine (rotated every 24h)
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "linkwarden-db-creds"
      namespace = "linkwarden"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "linkwarden-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DATABASE_URL = "postgresql://linkwarden:{{ .password }}@${var.postgresql_host}:5432/linkwarden"
            DB_PASSWORD  = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-linkwarden"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.linkwarden]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "secret" {
  length           = 32
  special          = true
  override_special = "/@£$"
}

resource "kubernetes_deployment" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    labels = {
      app  = "linkwarden"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "linkwarden"
      }
    }
    template {
      metadata {
        labels = {
          app = "linkwarden"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^v?\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        container {
          image = "ghcr.io/linkwarden/linkwarden:v2.14.0"
          name  = "linkwarden"

          port {
            container_port = 3000
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "linkwarden-db-creds"
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name  = "NEXT_PUBLIC_AUTHENTIK_ENABLED"
            value = "true"
          }
          env {
            name  = "NEXTAUTH_SECRET"
            value = random_string.secret.result
          }
          env {
            name  = "NEXTAUTH_URL"
            value = "https://linkwarden.viktorbarzin.me/api/v1/auth"
          }
          env {
            name  = "AUTHENTIK_ISSUER"
            value = "https://authentik.viktorbarzin.me/application/o/linkwarden"
          }
          env {
            name = "AUTHENTIK_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "linkwarden-secrets"
                key  = "authentik_client_id"
              }
            }
          }
          env {
            name = "AUTHENTIK_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "linkwarden-secrets"
                key  = "authentik_client_secret"
              }
            }
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
resource "kubernetes_service" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    labels = {
      app = "linkwarden"
    }
  }

  spec {
    selector = {
      app = "linkwarden"
    }
    port {
      name        = "linkwarden"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  name            = "linkwarden"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Linkwarden"
    "gethomepage.dev/description"  = "Bookmark manager"
    "gethomepage.dev/icon"         = "linkwarden.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "linkwarden"
    "gethomepage.dev/widget.url"   = "http://linkwarden.linkwarden.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.homepage_credentials["linkwarden"]["api_key"]
  }
}
