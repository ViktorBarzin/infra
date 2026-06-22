variable "tls_secret_name" {
  type      = string
  sensitive = true
}
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "webhook-handler"
}


resource "kubernetes_namespace" "webhook-handler" {
  metadata {
    name = "webhook-handler"
    labels = {
      tier = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.webhook-handler.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_cluster_role" "deployment_updater" {
  metadata {
    name = "deployment-updater"
  }

  rule {
    verbs      = ["create", "update", "get", "patch", "list"]
    api_groups = ["extensions", "apps", ""]
    resources  = ["deployments", "namespaces", "pods", "services"]
  }
}

resource "kubernetes_cluster_role_binding" "update_deployment_binding" {
  metadata {
    name = "update-deployment-binding"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.webhook-handler.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "deployment-updater"
  }
}


resource "kubernetes_secret" "ssh-key" {
  metadata {
    name      = "ssh-key"
    namespace = kubernetes_namespace.webhook-handler.metadata[0].name

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "id_rsa" = data.vault_kv_secret_v2.secrets.data["ssh_key"]
  }
  type = "generic"
}
resource "kubernetes_deployment" "webhook_handler" {
  metadata {
    name      = "webhook-handler"
    namespace = kubernetes_namespace.webhook-handler.metadata[0].name
    labels = {
      app  = "webhook-handler"
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
        app = "webhook-handler"
      }
    }
    template {
      metadata {
        labels = {
          app = "webhook-handler"
        }
      }
      spec {
        container {
          # security_context {
          #   run_as_user = 1000
          # }
          # lifecycle {
          #   post_start {
          #     exec {
          #       # Must be kept in sycn with webhook_handler dockerfile
          #       command = ["echo", "\"$SSH_KEY\"", ">", "/opt/id_rsa", "&&", "chown", "appuser", "/opt/id_rsa", "&&", "chmod", "600", "/opt/id_rsa"]
          #     }
          #   }
          # }
          image = "viktorbarzin/webhook-handler:latest"
          name  = "webhook-handler"
          resources {
            limits = {
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
          }
          port {
            container_port = 80
          }
          volume_mount {
            name       = "id-rsa"
            mount_path = "/opt/id_rsa"
            sub_path   = "id_rsa"
          }
          env {
            name = "WEBHOOKSECRET"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "secret"
              }
            }
          }
          env {
            name = "FB_APP_SECRET"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "fb_app_secret"
              }
            }
          }
          env {
            name = "FB_VERIFY_TOKEN"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "fb_verify_token"
              }
            }
          }
          env {
            name = "FB_PAGE_TOKEN"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "fb_page_token"
              }
            }
          }
          env {
            name  = "CONFIG"
            value = "./chatbot/config/viktorwebservices.yaml"
          }
          env {
            name = "GIT_USER"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "git_user"
              }
            }
          }
          env {
            name = "GIT_TOKEN"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "git_token"
              }
            }
          }
          env {
            name  = "SSH_KEY"
            value = "/opt/id_rsa"
          }
          env {
            name  = "WOODPECKER_API_URL"
            value = "https://ci.viktorbarzin.me"
          }
          env {
            name = "WOODPECKER_TOKEN"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "woodpecker_token"
              }
            }
          }
          env {
            name = "WOODPECKER_INFRA_REPO_ID"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "woodpecker_infra_repo_id"
              }
            }
          }
          env {
            name = "AUTHENTIK_WEBHOOK_SECRET"
            value_from {
              secret_key_ref {
                name = "webhook-handler-secrets"
                key  = "authentik_webhook_secret"
              }
            }
          }
        }
        volume {
          name = "id-rsa"
          secret {
            secret_name = "ssh-key"
          }

        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "webhook_handler" {
  metadata {
    name      = "webhook-handler"
    namespace = kubernetes_namespace.webhook-handler.metadata[0].name
    labels = {
      "app" = "webhook-handler"
    }
  }

  spec {
    selector = {
      app = "webhook-handler"
    }
    port {
      port        = "80"
      target_port = "3000"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Webhook receiver — third parties (Forgejo, GitHub, etc.) POST events without
  # browser sessions. Forward-auth would block all webhook deliveries.
  # auth = "none": Webhook receiver — third parties (Forgejo, GitHub, etc.) POST events without browser sessions; forward-auth blocks deliveries.
  auth            = "none"
  namespace       = kubernetes_namespace.webhook-handler.metadata[0].name
  name            = "webhook-handler"
  host            = "webhook"
  dns_type        = "non-proxied"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Webhook Handler"
    "gethomepage.dev/description"  = "Webhook relay"
    "gethomepage.dev/icon"         = "webhook.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "webhook-handler-secrets"
      namespace = "webhook-handler"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "webhook-handler-secrets"
      }
      dataFrom = [{
        extract = {
          key = "webhook-handler"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.webhook-handler]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z
