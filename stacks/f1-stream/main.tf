variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "discord_f1_guild_id" { type = string }
variable "discord_f1_channel_ids" { type = string }

resource "kubernetes_namespace" "f1-stream" {
  metadata {
    name = "f1-stream"
    labels = {
      "istio-injection" : "disabled"
      tier                                    = local.tiers.aux
      "chrome-service.viktorbarzin.me/client" = "true"
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
      name      = "f1-stream-secrets"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "f1-stream-secrets"
      }
      dataFrom = [{
        extract = {
          key = "f1-stream"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
}

# Pull the chrome-service bearer token into this namespace as a separate
# Secret so the verifier can reach the in-cluster Playwright pool.
resource "kubernetes_manifest" "chrome_service_client_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-service-client-secrets"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-service-client-secrets"
      }
      dataFrom = [{
        extract = {
          key = "chrome-service"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "f1-stream-data-proxmox"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
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

resource "kubernetes_deployment" "f1-stream" {
  metadata {
    name      = "f1-stream"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
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
        app = "f1-stream"
      }
    }
    template {
      metadata {
        labels = {
          app = "f1-stream"
        }
      }
      spec {
        container {
          image             = "viktorbarzin/f1-stream:latest"
          image_pull_policy = "Always"
          name              = "f1-stream"
          resources {
            limits = {
              memory = "1Gi"
            }
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
          }
          port {
            container_port = 8000
          }
          env {
            name = "DISCORD_TOKEN"
            value_from {
              secret_key_ref {
                name = "f1-stream-secrets"
                key  = "discord_user_token"
              }
            }
          }
          env {
            name  = "DISCORD_CHANNELS"
            value = var.discord_f1_channel_ids
          }
          # Verifier connects to in-cluster headed Chromium pool — see
          # stacks/chrome-service/. Falls back to in-process headless if unset.
          env {
            name  = "CHROME_WS_URL"
            value = "ws://chrome-service.chrome-service.svc.cluster.local:3000"
          }
          env {
            name = "CHROME_WS_TOKEN"
            value_from {
              secret_key_ref {
                name = "chrome-service-client-secrets"
                key  = "api_bearer_token"
              }
            }
          }
          # The embed proxy (this pod's /embed?url=…) must be reachable from
          # the remote chrome-service pod. Default 127.0.0.1 only works for
          # in-process Chromium — for the remote browser we point it at our
          # own ClusterIP service.
          env {
            name  = "PLAYBACK_VERIFY_PROXY_BASE"
            value = "http://f1.f1-stream.svc.cluster.local"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}


resource "kubernetes_service" "f1-stream" {
  metadata {
    name      = "f1"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      "app" = "f1-stream"
    }
  }

  spec {
    selector = {
      app = "f1-stream"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# f1-stream serves its SvelteKit SPA via the FastAPI `/{path}` catch-all
# and exposes 14 JSON/proxy routes at root (/schedule, /streams, /embed,
# /embed-asset, /relay, /proxy, /extract, /extractors, /health). A flat
# Anubis catch-all CHALLENGE breaks the SPA's XHRs with "Unexpected token
# '<', '<!doctype '" because the schedule fetch lands on the challenge HTML.
# Custom policy: ALLOW the known JSON routes + SvelteKit `_app/` assets
# (which load before any user has a chance to solve PoW), CHALLENGE
# everything else — the HTML pages.
module "anubis" {
  source     = "../../modules/kubernetes/anubis_instance"
  name       = "f1"
  namespace  = kubernetes_namespace.f1-stream.metadata[0].name
  target_url = "http://${kubernetes_service.f1-stream.metadata[0].name}.${kubernetes_namespace.f1-stream.metadata[0].name}.svc.cluster.local"
  policy_yaml = <<-EOT
    bots:
      - import: (data)/bots/_deny-pathological.yaml
      - import: (data)/bots/aggressive-brazilian-scrapers.yaml
      - import: (data)/meta/ai-block-aggressive.yaml
      - import: (data)/crawlers/_allow-good.yaml
      - import: (data)/clients/x-firefox-ai.yaml
      - import: (data)/common/keep-internet-working.yaml
      # SvelteKit immutable assets (CSS/JS chunks) and OpenAPI/health routes —
      # served pre-cookie, must pass without challenge.
      - name: f1-svelte-assets-and-meta
        path_regex: ^/(_app/|openapi\.json|docs|api/)
        action: ALLOW
      # Application JSON routes — XHR'd by the SPA after the user has solved
      # the PoW for `/`. We allow them unconditionally because the alternative
      # (carve-out per route via separate Ingress objects) is brittle and
      # because the data they expose (stream URLs, schedule metadata) is not
      # the AI-scraping target — the HTML/SPA is.
      - name: f1-data-routes
        path_regex: ^/(embed|embed-asset|extract|extractors|health|proxy|relay|schedule|streams)(/|\?|$)
        action: ALLOW
      - name: catchall-challenge
        path_regex: .*
        action: CHALLENGE
  EOT
}

module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  dns_type         = "non-proxied"
  namespace        = kubernetes_namespace.f1-stream.metadata[0].name
  name             = "f1"
  service_name     = module.anubis.service_name
  port             = module.anubis.service_port
  tls_secret_name  = var.tls_secret_name
  exclude_crowdsec = true
  anti_ai_scraping = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "F1 Stream"
    "gethomepage.dev/description"  = "Formula 1 live streams"
    "gethomepage.dev/icon"         = "si-f1"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
