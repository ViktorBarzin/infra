terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

# Per-site x402 payment gateway. Sits in FRONT of Anubis:
#
#   ingress -> x402-<name> Service:8080 -> x402 pod:8923 ->
#              anubis-<name> Service:8080 -> anubis pod -> backend
#
# Behaviour:
#   - X-PAYMENT header present  → validate via Coinbase facilitator,
#                                  forward to Anubis on success, 402 on fail.
#   - User-Agent matches AI bot → return 402 with payment requirements.
#   - Everything else            → forward transparently to Anubis (browsers
#                                  still solve the JS PoW gate as today).
#
# When `wallet_address` is empty, the gateway runs in DRY_RUN mode — every
# request is forwarded transparently. This lets us drop the pod into the
# request path without changing live behaviour while we wait for the
# wallet to be configured. Flip live by setting `wallet_address`.

variable "name" {
  type        = string
  description = "Short logical name (e.g. \"blog\"). Used to derive Service/Deployment/Secret names as x402-<name>."
}

variable "namespace" {
  type        = string
  description = "Namespace to deploy into — typically the same as the Anubis instance for the same backend."
}

variable "target_url" {
  type        = string
  description = "Upstream URL the gateway forwards to. Usually the anubis-<name> Service's cluster DNS."
}

variable "wallet_address" {
  type        = string
  default     = ""
  description = "EVM wallet address (0x…) that receives USDC. Empty = DRY_RUN, no 402s issued."
}

variable "price_label" {
  type        = string
  default     = "$0.01"
  description = "Human-readable price displayed in payment requirements."
}

variable "price_usdc_micros" {
  type        = number
  default     = 10000
  description = "Price in USDC base units (6 decimals). Default 10_000 = $0.01."
}

variable "network" {
  type        = string
  default     = "base"
  description = "x402 network identifier. \"base\", \"base-sepolia\", or any custom paired with USDC_ASSET."
}

variable "facilitator_url" {
  type        = string
  default     = "https://x402.org/facilitator"
  description = "Coinbase / community facilitator endpoint that verifies and settles X-PAYMENT headers."
}

variable "image_tag" {
  type        = string
  default     = "ce333419"
  description = "forgejo.viktorbarzin.me/viktor/x402-gateway tag. Pin to a release SHA, never :latest."
}

variable "replicas" {
  type        = number
  default     = 1
  description = "Replica count. The gateway is stateless so >1 is fine, but 1 is enough for low-traffic sites."
}

variable "memory" {
  type        = string
  default     = "64Mi"
  description = "requests==limits memory. The Go binary idles at ~10MiB."
}

variable "cpu_request" {
  type        = string
  default     = "10m"
  description = "CPU request. Per-request work is just an HTTP call to the facilitator."
}

variable "bot_ua_regex" {
  type        = string
  default     = ""
  description = "Override for the AI-bot User-Agent regex. Empty = use the gateway's default (ClaudeBot|GPTBot|…)."
}

locals {
  full_name = "x402-${var.name}"
  labels = {
    "app"                          = local.full_name
    "app.kubernetes.io/name"       = "x402-gateway"
    "app.kubernetes.io/instance"   = local.full_name
    "app.kubernetes.io/component"  = "payment-gateway"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

resource "kubernetes_deployment" "x402" {
  metadata {
    name      = local.full_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = local.full_name }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        container {
          name  = "x402-gateway"
          image = "forgejo.viktorbarzin.me/viktor/x402-gateway:${var.image_tag}"

          port {
            name           = "http"
            container_port = 8923
          }
          port {
            name           = "metrics"
            container_port = 9090
          }

          env {
            name  = "BIND"
            value = ":8923"
          }
          env {
            name  = "METRICS_BIND"
            value = ":9090"
          }
          env {
            name  = "TARGET"
            value = var.target_url
          }
          env {
            name  = "WALLET_ADDRESS"
            value = var.wallet_address
          }
          env {
            name  = "PRICE_LABEL"
            value = var.price_label
          }
          env {
            name  = "PRICE_USDC_MICROS"
            value = tostring(var.price_usdc_micros)
          }
          env {
            name  = "NETWORK"
            value = var.network
          }
          env {
            name  = "FACILITATOR_URL"
            value = var.facilitator_url
          }
          dynamic "env" {
            for_each = var.bot_ua_regex == "" ? [] : [1]
            content {
              name  = "BOT_UA_REGEX"
              value = var.bot_ua_regex
            }
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory
            }
            limits = {
              memory = var.memory
            }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            failure_threshold     = 3
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            initial_delay_seconds = 1
            period_seconds        = 5
            failure_threshold     = 2
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 65532
            run_as_group               = 65532
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
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

resource "kubernetes_service" "x402" {
  metadata {
    name      = local.full_name
    namespace = var.namespace
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9090"
    }
  }

  spec {
    selector = { app = local.full_name }
    port {
      name        = "http"
      port        = 8080
      target_port = 8923
      protocol    = "TCP"
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = 9090
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "x402" {
  metadata {
    name      = local.full_name
    namespace = var.namespace
  }
  spec {
    min_available = "1"
    selector {
      match_labels = { app = local.full_name }
    }
  }
}

output "service_name" {
  value       = kubernetes_service.x402.metadata[0].name
  description = "ClusterIP service name. Pass this to ingress_factory `service_name` so Traefik routes through the gateway."
}

output "service_port" {
  value       = 8080
  description = "Service port — same as the Anubis service for drop-in replacement in ingress_factory."
}
