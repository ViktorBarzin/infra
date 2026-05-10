terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

# Per-site Anubis reverse proxy.
# Sits between Traefik and the real backend. On first visit, serves a
# proof-of-work challenge; on success, drops a long-lived JWT cookie and
# proxies the request through to `target_url`.
#
# Sharing a single ed25519 signing key across instances + COOKIE_DOMAIN at
# the registrable domain means a token solved on one viktorbarzin.me subdomain
# is honoured by every other Anubis-fronted site.

variable "name" {
  type        = string
  description = "Short logical name (e.g. \"blog\"). Used to derive Service / Deployment / Secret names as anubis-<name>."
}

variable "namespace" {
  type        = string
  description = "Namespace to deploy into — typically the same as the protected backend service."
}

variable "target_url" {
  type        = string
  description = "Backend URL Anubis forwards passing requests to (e.g. http://blog.website.svc.cluster.local)."
}

variable "cookie_domain" {
  type        = string
  default     = "viktorbarzin.me"
  description = "Cookie domain — set to the registrable domain so a single PoW solve covers every Anubis-fronted subdomain."
}

variable "difficulty" {
  type        = number
  default     = 2
  description = "PoW difficulty (leading-zero hex chars). 2 = ~250ms desktop / ~700ms mobile. Bump for stronger filtering."
}

variable "cookie_expiration_hours" {
  type        = number
  default     = 720 # 30 days
  description = "Lifetime of the issued JWT cookie in hours."
}

variable "image_tag" {
  type        = string
  default     = "v1.25.0"
  description = "ghcr.io/techarohq/anubis tag — pin to a release, never :latest."
}

variable "replicas" {
  type        = number
  default     = 2
  description = "Replica count. 2 + matching ed25519 key = HA without sticky sessions."
}

variable "memory" {
  type        = string
  default     = "128Mi"
  description = "requests==limits memory. Anubis docs suggest 128Mi handles many concurrent clients."
}

variable "cpu_request" {
  type        = string
  default     = "20m"
  description = "CPU request. PoW verification is server-cheap (just hash check)."
}

locals {
  full_name = "anubis-${var.name}"
  labels = {
    "app"                          = local.full_name
    "app.kubernetes.io/name"       = "anubis"
    "app.kubernetes.io/instance"   = local.full_name
    "app.kubernetes.io/component"  = "ai-bot-challenge"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# ED25519 signing key — pulled from Vault `secret/viktor` -> field
# `anubis_ed25519_key`. Same key across every instance so JWTs are
# cross-validatable, enabling cross-subdomain SSO.
resource "kubernetes_manifest" "ed25519_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.full_name}-key"
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "${local.full_name}-key"
        creationPolicy = "Owner"
      }
      data = [{
        secretKey = "key"
        remoteRef = {
          key      = "viktor"
          property = "anubis_ed25519_key"
        }
      }]
    }
  }
}

resource "kubernetes_deployment" "anubis" {
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
        # Spread replicas across nodes to survive a single node failure.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = local.full_name }
          }
        }

        container {
          name  = "anubis"
          image = "ghcr.io/techarohq/anubis:${var.image_tag}"

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
            name  = "DIFFICULTY"
            value = tostring(var.difficulty)
          }
          env {
            name  = "COOKIE_EXPIRATION_TIME"
            value = "${var.cookie_expiration_hours}h"
          }
          # Cross-subdomain SSO: cookie scoped to the registrable domain so
          # a JWT solved on any Anubis-fronted subdomain is honoured on every
          # other one. (COOKIE_DOMAIN and COOKIE_DYNAMIC_DOMAIN are mutually
          # exclusive — picking the explicit form.)
          env {
            name  = "COOKIE_DOMAIN"
            value = var.cookie_domain
          }
          env {
            name  = "COOKIE_SECURE"
            value = "true"
          }
          env {
            name  = "COOKIE_SAME_SITE"
            value = "Lax"
          }
          # Built-in robots.txt that disallows known AI scrapers — well-behaved
          # bots get blocked here without ever paying the PoW cost.
          env {
            name  = "SERVE_ROBOTS_TXT"
            value = "true"
          }
          # Drop cluster-internal IPs from XFF so Anubis sees the real client.
          env {
            name  = "XFF_STRIP_PRIVATE"
            value = "true"
          }
          env {
            name  = "SLOG_LEVEL"
            value = "INFO"
          }
          env {
            name = "ED25519_PRIVATE_KEY_HEX_FILE"
            # Mounted from the ESO-managed Secret below.
            value = "/keys/key"
          }

          volume_mount {
            name       = "ed25519-key"
            mount_path = "/keys"
            read_only  = true
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

          # Liveness + readiness on the metrics endpoint (zero auth, always 200).
          liveness_probe {
            http_get {
              path = "/metrics"
              port = "metrics"
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 3
          }
          readiness_probe {
            http_get {
              path = "/metrics"
              port = "metrics"
            }
            initial_delay_seconds = 2
            period_seconds        = 5
            failure_threshold     = 2
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 1000
            run_as_group               = 1000
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "ed25519-key"
          secret {
            secret_name = "${local.full_name}-key"
            items {
              key  = "key"
              path = "key"
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

  depends_on = [kubernetes_manifest.ed25519_secret]
}

resource "kubernetes_service" "anubis" {
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

resource "kubernetes_pod_disruption_budget_v1" "anubis" {
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
  value       = kubernetes_service.anubis.metadata[0].name
  description = "ClusterIP service name. Pass this to ingress_factory's `service_name` so Traefik routes through Anubis."
}

output "service_port" {
  value       = 8080
  description = "Service port. Anubis listens on 8923 inside; the Service exposes 8080."
}
