variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Vault read: bearer_tokens (JSON array, used directly in the Middleware CRD)
# and paperless_api_token (synced to a K8s Secret by ESO and consumed by the
# pod as an env var).
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "paperless-mcp"
}

resource "kubernetes_namespace" "paperless-mcp" {
  metadata {
    name = "paperless-mcp"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Paperless API token (MCP -> paperless). Synced from Vault to a K8s Secret
# by ESO; the pod reads it via secret_key_ref.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "paperless-mcp-secrets"
      namespace = "paperless-mcp"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "paperless-mcp-secrets"
      }
      data = [{
        secretKey = "paperless_api_token"
        remoteRef = {
          key      = "paperless-mcp"
          property = "paperless_api_token"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.paperless-mcp]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.paperless-mcp.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Gateway-level bearer auth. barryw/PaperlessMCP has no native auth; this
# Middleware enforces Authorization: Bearer <token> at Traefik before any
# request reaches the pod. Token list lives in Vault as a JSON array string;
# rotation = update Vault then re-apply this stack.
resource "kubernetes_manifest" "bearer_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "bearer-auth"
      namespace = kubernetes_namespace.paperless-mcp.metadata[0].name
    }
    spec = {
      plugin = {
        # Inner key must match the static-config key in Traefik
        # experimental.plugins.api-token-middleware.
        api-token-middleware = {
          authenticationHeader   = false
          bearerHeader           = true
          bearerHeaderName       = "Authorization"
          tokens                 = jsondecode(data.vault_kv_secret_v2.secrets.data["bearer_tokens"])
          removeHeadersOnSuccess = true
          authenticationErrorMsg = "Access Denied"
        }
      }
    }
  }
}

resource "kubernetes_deployment" "paperless-mcp" {
  metadata {
    name      = "paperless-mcp"
    namespace = kubernetes_namespace.paperless-mcp.metadata[0].name
    labels = {
      app  = "paperless-mcp"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
      "keel.sh/policy"             = "minor"
      "keel.sh/trigger"            = "poll"
      "keel.sh/pollSchedule"       = "@every 1h"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "paperless-mcp"
      }
    }
    template {
      metadata {
        labels = {
          app = "paperless-mcp"
        }
      }
      spec {
        container {
          name  = "paperless-mcp"
          image = "ghcr.io/barryw/paperlessmcp:v0.1.19"
          port {
            container_port = 5000
          }
          env {
            name  = "PAPERLESS_BASE_URL"
            value = "http://paperless-ngx.paperless-ngx.svc.cluster.local"
          }
          env {
            name = "PAPERLESS_API_TOKEN"
            value_from {
              secret_key_ref {
                name = "paperless-mcp-secrets"
                key  = "paperless_api_token"
              }
            }
          }
          env {
            name  = "MCP_PORT"
            value = "5000"
          }
          # barryw exposes no HTTP /health; the ping/capabilities probes are
          # MCP JSON-RPC over /mcp. TCP-socket probe is what the upstream
          # k8s/deployment.yaml uses.
          startup_probe {
            tcp_socket {
              port = 5000
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            tcp_socket {
              port = 5000
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = 5000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          resources {
            requests = {
              memory = "256Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image, # Keel-managed
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "paperless-mcp" {
  metadata {
    name      = "paperless-mcp"
    namespace = kubernetes_namespace.paperless-mcp.metadata[0].name
    labels = {
      app = "paperless-mcp"
    }
  }
  spec {
    selector = {
      app = "paperless-mcp"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5000
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": barryw/PaperlessMCP has no native auth; the bearer-auth
  # Middleware CRD attached below enforces Authorization: Bearer at Traefik.
  auth              = "none"
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.paperless-mcp.metadata[0].name
  name              = "paperless-mcp"
  tls_secret_name   = var.tls_secret_name
  homepage_enabled  = false
  extra_middlewares = ["paperless-mcp-bearer-auth@kubernetescrd"]
}
