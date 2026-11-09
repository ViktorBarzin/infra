variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }


resource "kubernetes_namespace" "ntfy" {
  metadata {
    name = "ntfy"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.ntfy.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Database credentials from the Vault static role pg-ntfy (stacks/vault
# app_db_roles.tf), rotated weekly in its Tuesday slot. The
# db-rotation-watcher force-syncs this ExternalSecret and Reloader restarts
# the pod. ntfy keeps users, access rules and tokens in this database.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "ntfy-db-creds"
      namespace = kubernetes_namespace.ntfy.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "ntfy-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            NTFY_DATABASE_URL = "postgres://ntfy:{{ .password }}@${var.postgresql_host}:5432/ntfy"
            password          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-ntfy"
          property = "password"
        }
      }]
    }
  }
}

resource "kubernetes_deployment" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    labels = {
      app  = "ntfy"
      tier = local.tiers.aux
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
        app = "ntfy"
      }
    }
    template {
      metadata {
        labels = {
          app = "ntfy"
        }
      }
      spec {
        container {
          image = "binwiederhier/ntfy:v2.37.2"
          name  = "ntfy"
          args  = ["serve"]

          port {
            container_port = 80
          }
          liveness_probe {
            http_get {
              path = "/v1/health"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/v1/health"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          env {
            name  = "NTFY_BASE_URL"
            value = "https://ntfy.viktorbarzin.me"
          }
          env {
            name = "NTFY_UPSTREAM_BASE_URL"
            # value = "https://ntfy.viktorbarzin.me"
            value = "https://ntfy.sh"
          }
          env {
            name  = "NTFY_BEHIND_PROXY"
            value = "true"
          }
          env {
            name  = "NTFY_ENABLE_LOGIN"
            value = "true"
          }
          # Users, access rules and tokens live in the shared Postgres since
          # 2026-11-09 (database-url; auth-file must then be unset). Nothing
          # else is configured to write to disk: no message cache, no
          # attachments, no web push, so the pod needs no volume.
          env {
            name = "NTFY_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "ntfy-db-creds"
                key  = "NTFY_DATABASE_URL"
              }
            }
          }
          env {
            name  = "NTFY_AUTH_DEFAULT_ACCESS"
            value = "deny-all"
          }
          env {
            name  = "NTFY_ENABLE_METRICS"
            value = "true"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    labels = {
      "app" = "ntfy"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "80"
    }
  }

  spec {
    selector = {
      app = "ntfy"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # ntfy mobile/desktop apps + publisher scripts use HTTP basic-auth / bearer
  # tokens against ntfy's own user.db (NTFY_AUTH_DEFAULT_ACCESS=deny-all).
  # Forward-auth would block subscribers and publishers alike.
  # auth = "app": ntfy mobile/desktop apps + scripts use HTTP Basic auth / bearer tokens against ntfy's own user.db (NTFY_AUTH_DEFAULT_ACCESS=deny-all); backend auth is the gate.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ntfy.metadata[0].name
  name            = "ntfy"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "ntfy"
    "gethomepage.dev/description"  = "Push notifications"
    "gethomepage.dev/icon"         = "ntfy.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
