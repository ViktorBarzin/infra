# wa-bot: Viktor drives Terminal Lobby sessions from WhatsApp through the Meta
# Cloud API. Source: Forgejo viktor/wa-bot (GHA -> private ghcr, Woodpecker
# deploy). Runbook: docs/runbooks/wa-bot.md.
#
# Request path: Meta -> wa.viktorbarzin.me/webhook (Traefik) -> this pod, which
# checks X-Hub-Signature-256 on every POST, then calls terminal-api as the
# `whatsapp` Caller and replies through graph.facebook.com.
#
# The webhook path is fixed: the CrowdSec bouncer lets Meta's address space
# through ONLY on wa.viktorbarzin.me/webhook (exemptRoutes on the crowdsec
# Middleware in stacks/traefik/modules/traefik/middleware.tf).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  name   = "wa-bot"
  labels = { app = "wa-bot" }
}

resource "kubernetes_namespace" "wa_bot" {
  metadata {
    name = local.name
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
  namespace       = kubernetes_namespace.wa_bot.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Everything the pod needs, synced from Vault. Values are never in Terraform
# state: the Deployment reads them from this Secret by key.
#   secret/wa-bot             Meta app secret, system-user token, verify token,
#                             phone-number id, PIN hash (scrypt)
#   secret/terminal-lobby     agent_api_whatsapp_token (the `whatsapp` Caller)
#   secret/viktor/contact     contact_number, the only sender the bot answers
#   secret/platform           the shared #alerts incoming webhook
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.name
      namespace = kubernetes_namespace.wa_bot.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.name
      }
      data = [
        { secretKey = "WA_APP_SECRET", remoteRef = { key = "wa-bot", property = "app_secret" } },
        { secretKey = "WA_SYSTEM_USER_TOKEN", remoteRef = { key = "wa-bot", property = "system_user_token" } },
        { secretKey = "WA_VERIFY_TOKEN", remoteRef = { key = "wa-bot", property = "verify_token" } },
        { secretKey = "WA_PHONE_NUMBER_ID", remoteRef = { key = "wa-bot", property = "phone_number_id" } },
        { secretKey = "WA_PIN_HASH", remoteRef = { key = "wa-bot", property = "pin_hash" } },
        { secretKey = "LOBBY_TOKEN", remoteRef = { key = "terminal-lobby", property = "agent_api_whatsapp_token" } },
        { secretKey = "WA_ALLOWED_FROM", remoteRef = { key = "viktor/contact", property = "contact_number" } },
        { secretKey = "SLACK_WEBHOOK_URL", remoteRef = { key = "platform", property = "alertmanager_slack_api_url" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.wa_bot]
}

# Dedupe ids, the WhatsApp message-id -> session map (30 days), the PIN and
# lockout state and the monthly conversation count. A few hundred KB at most.
resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "wa-bot-data"
    namespace = kubernetes_namespace.wa_bot.metadata[0].name
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

resource "kubernetes_deployment" "wa_bot" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.wa_bot.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    # One replica: the state file and the per-chat session map are local.
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        # Private ghcr image, pulled with the Kyverno-synced ghcr-credentials.
        image_pull_secrets {
          name = "ghcr-credentials"
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          fs_group        = 65532
        }
        container {
          name  = local.name
          image = "ghcr.io/viktorbarzin/wa-bot:latest"
          port {
            container_port = 8080
          }
          env_from {
            secret_ref {
              name = local.name
            }
          }
          env {
            name  = "STATE_PATH"
            value = "/data/state.json"
          }
          # Pods resolve *.viktorbarzin.me to the Traefik LB, so this goes
          # through Traefik's terminal-api routes like any external Caller.
          env {
            name  = "LOBBY_URL"
            value = "https://terminal-api.viktorbarzin.me"
          }
          # Viktor's choice for sessions the bot starts (new / ask / main).
          env {
            name  = "SESSION_MODEL"
            value = "claude-opus-5"
          }
          env {
            name  = "SESSION_EFFORT"
            value = "max"
          }
          # No payment method on the Meta app, deliberately: the bot stops
          # replying at the free tier's 1,000 conversations a month and alerts
          # #alerts at 80%.
          env {
            name  = "WA_QUOTA_CAP"
            value = "1000"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 30
            failure_threshold = 4
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "48Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

resource "kubernetes_service" "wa_bot" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.wa_bot.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": Meta's servers POST webhooks without a browser session;
  # forward-auth would block every delivery. The pod's HMAC check is the gate.
  auth      = "none"
  namespace = kubernetes_namespace.wa_bot.metadata[0].name
  name      = local.name
  # No Turnstile gate: machine-only webhooks.
  turnstile       = false
  host            = "wa"
  dns_type        = "proxied"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "WhatsApp bot"
    "gethomepage.dev/description"  = "WhatsApp access to Terminal Lobby sessions (Meta Cloud API webhook)"
    "gethomepage.dev/icon"         = "whatsapp.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
  }
}
