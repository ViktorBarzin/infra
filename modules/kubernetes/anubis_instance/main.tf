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
#
# X-REAL-IP: Anubis binds its cookie to X-Real-Ip. ingress_factory AUTO-ATTACHES
# the shared real-ip middleware (traefik-real-ip@kubernetescrd) for any anubis-*
# backend — no per-site wiring. It rewrites X-Real-Ip to the true client, trusting
# Cf-Connecting-Ip only from the cloudflared pod peer (trustedProxyCIDRs = the
# pod CIDR) and otherwise using the unspoofable TCP peer, so the value is stable
# AND client-unspoofable on both proxied and non-proxied paths. This replaced the
# old per-site strip_x_real_ip / drop-x-real-ip middleware (retired 2026-07-19),
# which fixed the 2026-07-14 blank-page flap on proxied sites but 500'd
# header-less requests on non-proxied ones. Post-mortem:
# docs/post-mortems/2026-07-14-anubis-x-real-ip-cookie-flap.md.
#
# LOCAL BYPASS (2026-08-22): this module renders the `bots:` key itself and puts a
# trusted-local-networks ALLOW rule first, so browsing and automation from our own
# networks reach the real app instead of the proof-of-work page. It rests on
# exactly the X-Real-Ip guarantee described above — the trust decision reads a
# header the client cannot set. See var.trusted_local_cidrs and
# docs/plans/2026-08-22-local-network-bot-wall-bypass-design.md.

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
    condition     = var.replicas == null ? true : (var.replicas >= 1 && var.replicas <= 2)
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

variable "policy_rules_yaml" {
  type        = string
  default     = null
  description = <<-EOT
    Override the default bot-policy RULES. This is the contents of the `bots:`
    list ONLY — do NOT include the top-level `bots:` key. The module owns that
    key so it can always render the trusted-local-networks ALLOW rule first;
    see `trusted_local_cidrs`. Leave null to use the strict default rules.

    Renamed from `policy_yaml` (which took a whole policy document) on
    2026-08-22 deliberately: a caller still passing a full document now fails
    at plan time with "Unsupported argument" instead of silently producing a
    policy whose first rule is not the trusted-network bypass.
  EOT
}

variable "trusted_local_cidrs" {
  type = list(string)
  default = [
    "10.0.0.0/8",     # VLANs (devvm 10.0.10.10), k8s pods/services, WG tunnel IPs
    "172.16.0.0/12",  # RFC1918
    "192.168.0.0/16", # Sofia LAN + London (incl. guest) + Valchedrym, via WG
    "100.64.0.0/10",  # Headscale tailnet (CGNAT)
    "fc00::/7",       # IPv6 ULA
    "fe80::/10",      # IPv6 link-local
  ]
  description = <<-EOT
    Source networks that skip the whole bot policy — rendered as the FIRST rule
    so local browsing and local automation reach the real app instead of the
    proof-of-work interstitial. This list is the CANONICAL definition.

    MIRRORED in stacks/traefik/modules/traefik/main.tf as the x402-gateway's
    TRUSTED_CIDRS env, because the two live in different CI fan-out scopes: a
    modules/ edit re-applies this module's consuming app stacks, and a
    stacks/traefik edit re-applies the traefik platform stack. Keeping a copy in
    each place means every edit is applied where it is made. Change both.

    Private + CGNAT ranges only. Our public egress IP is deliberately absent, so
    the bypass is unreachable from the internet by construction — no dependency
    on the ISP keeping our lease. Matching is against X-Real-Ip, which the
    vendored Traefik real-ip plugin overwrites with the unspoofable TCP peer for
    any peer outside the pod CIDR, so a client cannot forge its way in.

    The validation below enforces that "private only" rather than trusting the
    comment: a public range added here would hand the bypass an
    internet-reachable key, which is the one property the design cannot lose.
  EOT

  # RFC1918 + CGNAT + IPv6 ULA/link-local, as an allowlist of prefixes. Terraform
  # has no "is this CIDR inside that one" function, so this matches the textual
  # form — enough to reject 0.0.0.0/0 and any public range at plan time, which
  # is what matters. Anubis itself validates each entry parses as a CIDR.
  validation {
    condition = alltrue([
      for c in var.trusted_local_cidrs : can(regex(
        "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.|[fF][cCdD]|[fF][eE]80:)",
        c
      ))
    ])
    error_message = "trusted_local_cidrs must contain only private (RFC1918), CGNAT (100.64/10) or IPv6 ULA/link-local ranges. A public range here would make the local bypass reachable from the internet."
  }
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
  default_policy_rules_yaml = <<-EOT
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

  # Trusted-local ALLOW rule, rendered by the module for EVERY caller so no site
  # can miss it. Built with join() rather than a heredoc so the YAML indentation
  # is explicit: sequence items sit at column 0 under `bots:` (valid YAML, and
  # the same level the rules heredocs land on after `<<-` de-indents them), and
  # mixing levels within one sequence would be a parse error.
  #
  # POSITION IS LOAD-BEARING — this MUST stay the first rule. Anubis evaluates
  # rules in order, first match wins (lib/policy/policy.go), and
  # `_deny-pathological` imports headless-browsers.yaml which DENYs any
  # HeadlessChrome UA. A trusted-network rule placed after it would still block
  # local Playwright and agent traffic, which is most of the point.
  trusted_local_rule_yaml = join("\n", concat([
    "# Trusted local networks bypass every check below — LAN, VLANs, WireGuard",
    "# spokes, Headscale tailnet and the cluster itself. Lets local humans skip the",
    "# proof-of-work interstitial and lets non-JS local clients (curl, Playwright,",
    "# scripts, in-cluster probes) reach the real app at all.",
    "#",
    "# Matched against X-Real-Ip, which the vendored Traefik real-ip plugin",
    "# overwrites with the unspoofable TCP peer for every peer outside the pod",
    "# CIDR — ingress_factory auto-attaches it to all anubis-* backends. So this",
    "# cannot be forged from the internet, and our public egress IP is",
    "# deliberately NOT in the list. See var.trusted_local_cidrs.",
    "- name: trusted-local-networks",
    "  action: ALLOW",
    "  remote_addresses:",
    ], [for cidr in var.trusted_local_cidrs : "  - \"${cidr}\""]
  ))

  # Final policy YAML: the module-owned `bots:` key, the trusted-local rule, the
  # caller's rules (or the strict defaults), then an optional store block when
  # shared_store_url is set. Store block is module-managed and appended
  # universally — callers passing custom rules shouldn't include their own
  # `store:` block (they would collide).
  rendered_policy_yaml = join("\n", [
    "bots:",
    local.trusted_local_rule_yaml,
    trimspace(coalesce(var.policy_rules_yaml, local.default_policy_rules_yaml)),
  ]) + local.store_yaml_block
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
  # The live CRs were created under the v1beta1 field manager; without
  # force_conflicts the v1 re-apply fails with a field-manager conflict
  # (same pattern as every other ExternalSecret kubernetes_manifest in the
  # repo, e.g. stacks/grampsweb).
  field_manager {
    force_conflicts = true
  }
  manifest = {
    # v1 since the ESO 2.6.0 migration (2026-06-22) — v1beta1 was removed from
    # the CRD, and this inline manifest was the one declaration the migration
    # missed: every apply of every Anubis-fronted stack failed GVK discovery
    # ("CRD may not be installed") from 06-22 until this fix (2026-07-09).
    apiVersion = "external-secrets.io/v1"
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
    #
    # metadata annotations/labels are ignored for the same reason, added
    # 2026-08-14: two Kyverno mutate policies stamp this Deployment's metadata
    # and Terraform then planned to strip what they added, so every anubis-using
    # stack reported drift forever (7 of the 118 in the 2026-08-14 detection
    # run). The policies are `inject-keel-annotations` (rule add-keel-annotations
    # -> keel.sh/policy, keel.sh/pollSchedule, keel.sh/trigger) and
    # `sync-tier-label-from-namespace` (rule sync-tier-<tier> -> the `tier`
    # label). Both live in stacks/kyverno/modules/kyverno/.
    #
    # Ignoring the whole map is the same trade-off the shared tls_secret module
    # already takes for its Kyverno-stamped labels: module-defined
    # labels/annotations are set at create time and not reconciled afterwards.
    # local.labels still seeds them on create, and spec.selector.match_labels is
    # a separate attribute, so pod selection is unaffected.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      metadata[0].annotations,
      metadata[0].labels,
    ]
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
