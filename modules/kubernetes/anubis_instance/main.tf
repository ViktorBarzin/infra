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
  default     = null
  description = "Optional replica count override. When null, defaults to 1 if shared_store_url is null and 2 otherwise. Capped at 2 — Redis can handle more but anti-affinity assumes ≤2 replicas per Anubis instance on a 5-node cluster."

  validation {
    condition     = var.replicas == null || (var.replicas >= 1 && var.replicas <= 2)
    error_message = "replicas must be 1 or 2 (or null to auto-pick from shared_store_url presence)."
  }
}

variable "shared_store_url" {
  type        = string
  default     = null
  description = "If set, Anubis stores in-flight challenge state in this Valkey/Redis-protocol URL instead of in-process memory, enabling HA across replicas. Format: redis://host:port/<db-index>. The DB index MUST be unique per Anubis instance (this module assumes 16 DBs available, common in standalone Redis). Cluster Redis is redis-master.redis.svc.cluster.local:6379 with HA via Sentinel + haproxy. Without this, replicas>1 causes ~50% PoW failures (challenge issued by pod A, solved against pod B → 500)."

  validation {
    condition     = var.shared_store_url == null || can(regex("^redis://[a-zA-Z0-9_.-]+:[0-9]+/[0-9]+$", var.shared_store_url))
    error_message = "shared_store_url must look like redis://host:port/<db-index> (explicit DB index required)."
  }
}

variable "memory" {
  type        = string
  default     = "128Mi"
  description = "requests==limits memory. Anubis docs suggest 128Mi handles many concurrent clients."
}

variable "policy_yaml" {
  type        = string
  default     = null
  description = "Override the strict default bot-policy YAML. Leave null to use the catch-all CHALLENGE policy."
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

  # Effective replicas: caller-override > shared-store-aware default.
  effective_replicas = coalesce(var.replicas, var.shared_store_url == null ? 1 : 2)

  # Anubis store config. With backend=valkey, multiple Anubis pods can share
  # in-flight PoW state and a challenge issued by pod A is verifiable by pod
  # B. Default backend is in-process memory which only works at replicas=1.
  store_yaml_block = var.shared_store_url == null ? "" : <<-EOT


    store:
      backend: valkey
      parameters:
        url: "${var.shared_store_url}"
  EOT

  # Strict bot policy. Default Anubis policy only WEIGHs Mozilla|Opera UAs
  # and lets unmatched UAs (curl, wget, Python-requests, scrapy, headless
  # CLI scrapers) fall through to ALLOW. We import the same upstream
  # snippets and append a catch-all CHALLENGE so anyone without JS+PoW
  # capability is filtered.
  default_policy_yaml = <<-EOT
    bots:
      # Hard-deny known-bad bots first — runs before the method bypass so
      # a declared bad bot can't sneak through by sending a POST.
      - import: (data)/bots/_deny-pathological.yaml
      - import: (data)/bots/aggressive-brazilian-scrapers.yaml
      # Hard-deny declared AI/LLM crawlers (ClaudeBot, GPTBot, Bytespider, …).
      - import: (data)/meta/ai-block-aggressive.yaml
      # Whitelist legitimate search-engine crawlers (Googlebot, Bingbot, …).
      - import: (data)/crawlers/_allow-good.yaml
      # Challenge Firefox AI previews specifically.
      - import: (data)/clients/x-firefox-ai.yaml
      # Allow /.well-known, /robots.txt, /favicon.*, /sitemap.xml — keeps
      # the internet working for benign crawlers and discovery clients.
      - import: (data)/common/keep-internet-working.yaml
      # Allow every non-GET request through. Rationale: AI scrapers steal
      # the body of GETs (page content) — they don't POST. State-mutating
      # methods come from app XHRs (PrivateBin paste creation, Komga
      # uploads, SPA actions) and CORS preflight (OPTIONS). Challenging
      # those breaks the app, because the JS expects JSON and gets the
      # Anubis HTML challenge page. CrowdSec + rate-limit + per-app auth
      # already cover abuse on these methods.
      - name: allow-non-get-methods
        action: ALLOW
        expression: method != "GET"
      # Catch-all: every remaining (GET) request must solve the challenge.
      # This closes the "unmatched UA falls through to ALLOW" gap that
      # lets curl/wget/Python-requests scrape non-CDN-fronted hosts.
      - name: catchall-challenge
        path_regex: .*
        action: CHALLENGE
  EOT

  # Final policy YAML: defaults (or caller override) plus an optional store
  # block when shared_store_url is set. Store block is module-managed and
  # appended universally — callers passing a custom policy_yaml shouldn't
  # include their own `store:` block (they would collide).
  rendered_policy_yaml = "${coalesce(var.policy_yaml, local.default_policy_yaml)}${local.store_yaml_block}"
}

# Bot policy ConfigMap. Mounted into the pod and referenced by POLICY_FNAME.
resource "kubernetes_config_map" "policy" {
  metadata {
    name      = "${local.full_name}-policy"
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    "botPolicies.yaml" = local.rendered_policy_yaml
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
    replicas = local.effective_replicas

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
        annotations = {
          # Roll the deployment whenever the policy YAML changes — Anubis
          # reads the policy at startup, so a ConfigMap update alone
          # doesn't take effect until pods restart.
          "checksum/policy" = sha256(local.rendered_policy_yaml)
        }
      }

      spec {
        # Spread replicas across nodes to survive a single node failure.
        # DoNotSchedule (not ScheduleAnyway) so 2 replicas are forced onto
        # different hosts — otherwise the scheduler may pile them on the
        # same node and a single node reboot takes the whole Anubis instance
        # down despite replicas=2. On a 5-node cluster the spread is always
        # satisfiable; the worst case (4 nodes unavailable) leaves one
        # replica Pending, but the other keeps serving.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
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
          env {
            name  = "POLICY_FNAME"
            value = "/config/botPolicies.yaml"
          }

          volume_mount {
            name       = "ed25519-key"
            mount_path = "/keys"
            read_only  = true
          }
          volume_mount {
            name       = "policy"
            mount_path = "/config"
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
        volume {
          name = "policy"
          config_map {
            name = kubernetes_config_map.policy.metadata[0].name
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
    # max_unavailable=1 means: at most one pod can be voluntarily disrupted
    # at a time. With replicas=2 this allows clean rolling drains (one pod
    # goes down → other serves traffic → first recreates elsewhere). With
    # replicas=1 (no shared store) this is functionally equivalent to no
    # PDB — drain proceeds, brief outage, new pod schedules elsewhere.
    # Was min_available=1 before 2026-05-16 which deadlocked drains on
    # single-replica instances (eviction API can never satisfy the
    # constraint at replicas=1). See PM-2026-05-11.
    max_unavailable = "1"
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
