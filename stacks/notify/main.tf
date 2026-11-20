# The notify pipe: infra events reach people on Channels they already have
# (Home Assistant Companion push, email). Design and decisions:
# docs/plans/2026-11-17-notify-pipe-design.md, docs/adr/0043-*.md.
#
#   Alertmanager --every alert--> notify-adapter --tags--> apprise-api --> HA push / email
#                                       \--chat.postMessage--> Slack (a DM or #alerts)
#   person --> notify.viktorbarzin.me (adapter's page) --API--> Authentik user attributes
#   Authentik (User model_updated) --webhook--> apprise-api /add/notify
#
# apprise-api holds each person's Channels, tagged u-<username>-push and
# u-<username>-email. Authentik renders that config from people's attributes
# on every User change (stacks/authentik/notify.tf), so nothing here lists a
# person. The stored config holds no secrets: ${ha_sofia_token} and friends
# are Apprise template values filled from this pod's APPRISE_TEMPLATE_*
# environment. The adapter decides per alert which tags to notify, from the
# same attributes and Prometheus's rule groups (files/subs.py).

# The ingress names the TLS Secret; Kyverno's sync-tls-secret policy copies
# it into every namespace, so this stack does not create it.
variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  adapter_files = ["adapter.py", "subs.py", "page.py", "preview.py", "slack.py"]
  # "true" once Alertmanager routes every alert here (plan step 4); before
  # that the adapter only logs what it would post, so nothing posts twice.
  slack_live = "true"
}

resource "kubernetes_namespace" "notify" {
  metadata {
    name = "notify"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# apprise-api administrator. The adapter sends with it and Authentik's
# webhook writes the config with it (stacks/authentik/notify.tf reads this
# Secret). It guards sending and config writes only: the config holds no
# secrets.
resource "random_password" "apprise_admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "apprise_admin" {
  metadata {
    name      = "apprise-admin"
    namespace = kubernetes_namespace.notify.metadata[0].name
  }
  data = {
    APPRISE_USER     = "admin"
    APPRISE_PASSWORD = random_password.apprise_admin.result
  }
}

# The values Apprise fills into ${...} markers in the stored config:
# both HA long-lived tokens (canonical home secret/openclaw -> skill_secrets)
# and the SMTP password of alertmanager@viktorbarzin.me, which sends the
# email Channel's mail.
resource "kubernetes_manifest" "apprise_templates" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "apprise-templates"
      namespace = kubernetes_namespace.notify.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "apprise-templates"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            APPRISE_TEMPLATE_HA_SOFIA_TOKEN  = "{{ .skill_secrets | fromJson | dig \"home_assistant_sofia_token\" \"\" }}"
            APPRISE_TEMPLATE_HA_LONDON_TOKEN = "{{ .skill_secrets | fromJson | dig \"home_assistant_token\" \"\" }}"
            APPRISE_TEMPLATE_SMTP_PASSWORD   = "{{ .mailserver_accounts | fromJson | dig \"alertmanager@viktorbarzin.me\" \"\" | urlquery }}"
          }
        }
      }
      data = [
        {
          secretKey = "skill_secrets"
          remoteRef = { key = "openclaw", property = "skill_secrets" }
        },
        {
          secretKey = "mailserver_accounts"
          remoteRef = { key = "platform", property = "mailserver_accounts" }
        },
      ]
    }
  }
}

# The stored config. It is rebuilt from Authentik on the next User change, so
# it needs no backup; the volume only carries it across pod restarts.
resource "kubernetes_persistent_volume_claim" "apprise_config" {
  metadata {
    name      = "apprise-config"
    namespace = kubernetes_namespace.notify.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "nfs-pve"
    resources {
      requests = {
        storage = "64Mi"
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "apprise" {
  metadata {
    name      = "apprise"
    namespace = kubernetes_namespace.notify.metadata[0].name
    labels = {
      app  = "apprise"
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
        app = "apprise"
      }
    }
    template {
      metadata {
        labels = {
          app = "apprise"
        }
      }
      spec {
        container {
          name  = "apprise"
          image = "docker.io/caronc/apprise:2.1.0"
          port {
            container_port = 8000
          }
          env {
            name  = "APPRISE_STATEFUL_MODE"
            value = "simple"
          }
          env {
            name  = "APPRISE_AUTH_REQUIRED"
            value = "yes"
          }
          # Hide stored config from anything but the administrator.
          env {
            name  = "APPRISE_CONFIG_LOCK"
            value = "yes"
          }
          env {
            name  = "APPRISE_ADMIN"
            value = "no"
          }
          env {
            name  = "APPRISE_WORKER_COUNT"
            value = "1"
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.apprise_admin.metadata[0].name
            }
          }
          env_from {
            secret_ref {
              name = "apprise-templates"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          liveness_probe {
            tcp_socket {
              port = 8000
            }
            initial_delay_seconds = 20
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = 8000
            }
            period_seconds = 10
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "192Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.apprise_config.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.apprise_templates]
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "apprise" {
  metadata {
    name      = "apprise"
    namespace = kubernetes_namespace.notify.metadata[0].name
    labels = {
      app = "apprise"
    }
  }
  spec {
    selector = {
      app = "apprise"
    }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# The Slack bot (workspace viktorbarzin, user "claude"; scopes chat:write,
# chat:write.public, im:write). The adapter posts each person's Slack
# Channel with it: a DM, or #alerts for a Home Server Admin.
resource "kubernetes_manifest" "slack_token" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "notify-slack"
      namespace = kubernetes_namespace.notify.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "notify-slack"
      }
      data = [
        {
          secretKey = "token"
          remoteRef = { key = "viktor", property = "slack_bot_token" }
        },
      ]
    }
  }
}

# The adapter's own state: the last copy of everyone's settings (used when
# Authentik does not answer) and the alerts already reported as reaching
# nobody. Local and encrypted, not NFS: it holds people's addresses, and an
# NFS outage must not take the snapshot with it.
resource "kubernetes_persistent_volume_claim" "adapter_state" {
  wait_until_bound = false
  metadata {
    name      = "notify-adapter-state"
    namespace = kubernetes_namespace.notify.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_config_map" "adapter" {
  metadata {
    name      = "notify-adapter"
    namespace = kubernetes_namespace.notify.metadata[0].name
  }
  data = { for f in local.adapter_files : f => file("${path.module}/files/${f}") }
}

resource "kubernetes_deployment" "adapter" {
  metadata {
    name      = "notify-adapter"
    namespace = kubernetes_namespace.notify.metadata[0].name
    labels = {
      app  = "notify-adapter"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    # The state volume is ReadWriteOnce, and one pod at a time also keeps
    # two adapters from sending the same alert during a rollout.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "notify-adapter"
      }
    }
    template {
      metadata {
        labels = {
          app = "notify-adapter"
        }
        annotations = {
          # Roll the pod when the code changes.
          "notify/adapter-sha" = sha1(join("", [for f in local.adapter_files : file("${path.module}/files/${f}")]))
        }
      }
      spec {
        container {
          name    = "adapter"
          image   = "python:3.15-alpine"
          command = ["python3", "-u", "/app/adapter.py"]
          port {
            name           = "http"
            container_port = 8080
          }
          port {
            name           = "page"
            container_port = 8081
          }
          env {
            name  = "APPRISE_URL"
            value = "http://apprise.${kubernetes_namespace.notify.metadata[0].name}.svc.cluster.local:8000"
          }
          env {
            name  = "APPRISE_KEY"
            value = "notify"
          }
          env {
            name  = "AUTHENTIK_URL"
            value = "http://goauthentik-server.authentik.svc.cluster.local"
          }
          env {
            name  = "AUTHENTIK_TOKEN_FILE"
            value = "/secrets/authentik/token"
          }
          env {
            name  = "PROMETHEUS_URL"
            value = "http://prometheus-server.monitoring.svc.cluster.local"
          }
          env {
            name  = "PAGE_URL"
            value = "https://${local.page_host}"
          }
          env {
            name  = "INGRESS_PROOF_FILE"
            value = "/secrets/proof/proof"
          }
          env {
            name  = "LOKI_URL"
            value = "http://loki.monitoring.svc.cluster.local:3100"
          }
          env {
            name  = "SLACK_TOKEN_FILE"
            value = "/secrets/slack/token"
          }
          env {
            name  = "SLACK_LIVE"
            value = local.slack_live
          }
          env {
            name  = "STATE_DIR"
            value = "/state"
          }
          env {
            name  = "UNROUTED_CHANNEL"
            value = "#alerts"
          }
          env {
            name  = "ADMIN_GROUP"
            value = "Home Server Admins"
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.apprise_admin.metadata[0].name
            }
          }
          volume_mount {
            name       = "script"
            mount_path = "/app"
            read_only  = true
          }
          # Files, not env: the kubelet refreshes a mounted Secret in place, so
          # a rotated token or proof applies without a restart.
          volume_mount {
            name       = "authentik-token"
            mount_path = "/secrets/authentik"
            read_only  = true
          }
          volume_mount {
            name       = "ingress-proof"
            mount_path = "/secrets/proof"
            read_only  = true
          }
          volume_mount {
            name       = "slack-token"
            mount_path = "/secrets/slack"
            read_only  = true
          }
          volume_mount {
            name       = "state"
            mount_path = "/state"
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          resources {
            requests = {
              cpu    = "5m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "script"
          config_map {
            name = kubernetes_config_map.adapter.metadata[0].name
          }
        }
        volume {
          name = "authentik-token"
          secret {
            # Written by stacks/authentik/notify.tf, which applies after this
            # stack: until then the page and routing answer "unavailable".
            secret_name = "notify-authentik-token"
            optional    = true
          }
        }
        volume {
          name = "ingress-proof"
          secret {
            secret_name = kubernetes_secret.ingress_proof.metadata[0].name
          }
        }
        volume {
          name = "slack-token"
          secret {
            secret_name = "notify-slack"
          }
        }
        volume {
          name = "state"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.adapter_state.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "adapter" {
  metadata {
    name      = "notify-adapter"
    namespace = kubernetes_namespace.notify.metadata[0].name
    labels = {
      app = "notify-adapter"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8080"
    }
  }
  spec {
    selector = {
      app = "notify-adapter"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
    # The settings page; only the ingress (ingress.tf) should reach it.
    port {
      name        = "page"
      port        = 8081
      target_port = 8081
    }
  }
}
