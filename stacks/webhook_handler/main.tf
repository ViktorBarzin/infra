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
    }
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
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  source          = "../../modules/kubernetes/ingress_factory"
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
    apiVersion = "external-secrets.io/v1beta1"
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
