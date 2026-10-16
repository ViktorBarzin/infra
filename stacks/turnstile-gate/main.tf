# CLOUDFLARE TURNSTILE GATE for the public *.viktorbarzin.me sites.
# Design: docs/plans/2026-10-16-turnstile-sitewide-design.md. Started as the
# Forgejo canary of 2026-10-15 (Turnstile let ~0.8% of crawler IPs through,
# Anubis ~42%).
#
# Request path on a gated site (ingress_factory `turnstile = true`, after real-ip):
#   strip          deletes any client-sent X-Turnstile-Pass, so only the gate sets it
#   auth / auth-standard
#                  forwardAuth -> nginx shim -> gate /auth. 200 + X-Turnstile-Pass
#                  = let through; 200 without it = Anubis decides; 403 = the
#                  Turnstile page, on the URL the visitor asked for.
#   anubis         (standard sites only) forwardAuth -> shim -> the shared
#                  Anubis below; the shim answers 200 itself when the header is set.
# `auth` is the STRICT variant, for sites behind their own Anubis (only a solved
# Turnstile skips it); `auth-standard` is for every other site.
#
# The challenge page posts the token cross-origin to challenge.viktorbarzin.me,
# which sets one pass cookie for the whole domain (30 days).
#
# GLOBAL SWITCH: local.mode. "on" challenges; "anubis" never challenges and
# sends browsers asking for HTML to Anubis; "open" never challenges and leaves
# every site as it was before Turnstile. One apply of this stack flips them all.
#
# Fails open: the shim turns a gate or Anubis timeout or 5xx into a plain 200.
# The shim itself is the one hard dependency (forwardAuth to a dead address is
# a 500), hence two replicas and a PDB.
#
# REMOVAL ORDER MATTERS. Traefik drops a router whose middleware does not
# exist, so every ingress that references turnstile-gate-* (ingress_factory
# attaches strip to every Anubis-fronted ingress) must stop doing so, and be
# applied, before this stack is destroyed.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  name             = "turnstile-gate"
  domain           = "viktorbarzin.me"
  challenge_host   = "challenge.${local.domain}"
  anubis_host      = "anubis.${local.domain}"
  action           = "site-gate"
  mode             = "on" # the global switch: on | anubis | open
  anubis_check_uri = "/.within.website/x/cmd/anubis/api/check"
  # Mirrors var.trusted_local_cidrs in modules/kubernetes/anubis_instance.
  trusted_cidrs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10"]
  gate_labels   = { app = local.name }
  shim_labels   = { app = "${local.name}-shim" }
}

data "cloudflare_accounts" "main" {}

# Managed mode: Cloudflare decides per visitor whether a checkbox is needed.
# The registrable domain covers every subdomain. Resource name kept from the
# canary so the sitekey does not change.
resource "cloudflare_turnstile_widget" "forgejo_gate" {
  account_id = data.cloudflare_accounts.main.result[0].id
  name       = "site-gate"
  domains    = [local.domain]
  mode       = "managed"
}

resource "random_password" "cookie_key" {
  length  = 48
  special = false
}

resource "kubernetes_namespace" "gate" {
  metadata {
    name = local.name
    labels = {
      "istio-injection" : "disabled"
      # edge, not aux: every gated site's requests pass through the shim.
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.gate.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_secret" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  data = {
    "turnstile-secret" = cloudflare_turnstile_widget.forgejo_gate.secret
    "cookie-key"       = random_password.cookie_key.result
  }
}

resource "kubernetes_config_map" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  data = {
    "gate.py" = file("${path.module}/files/gate.py")
  }
}

resource "kubernetes_deployment" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.gate_labels
  }
  spec {
    replicas = 2
    selector {
      match_labels = local.gate_labels
    }
    template {
      metadata {
        labels = local.gate_labels
        annotations = {
          # Roll the pods when the script changes.
          "turnstile-gate/gate-sha" = sha256(file("${path.module}/files/gate.py"))
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.gate_labels
          }
        }
        container {
          name    = "gate"
          image   = "python:3.12-slim"
          command = ["python3", "-u", "/app/gate.py"]
          env {
            name  = "TURNSTILE_SITEKEY"
            value = cloudflare_turnstile_widget.forgejo_gate.id
          }
          env {
            name = "TURNSTILE_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gate.metadata[0].name
                key  = "turnstile-secret"
              }
            }
          }
          env {
            name = "COOKIE_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gate.metadata[0].name
                key  = "cookie-key"
              }
            }
          }
          env {
            name  = "GATE_DOMAIN"
            value = local.domain
          }
          env {
            name  = "CHALLENGE_ORIGIN"
            value = "https://${local.challenge_host}"
          }
          env {
            name  = "GATE_MODE"
            value = local.mode
          }
          env {
            name  = "TURNSTILE_ACTION"
            value = local.action
          }
          env {
            name  = "TRUSTED_CIDRS"
            value = join(",", local.trusted_cidrs)
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "gate"
            mount_path = "/app"
            read_only  = true
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
              cpu    = "25m"
              memory = "48Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "gate"
          config_map {
            name = kubernetes_config_map.gate.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.gate_labels
  }
  spec {
    selector = local.gate_labels
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.gate_labels
    }
  }
}

# The fail-open shim, same idea as bot_block_proxy_config in
# stacks/traefik/modules/traefik/main.tf: the gate's 403 and Anubis's redirect
# pass through, anything either cannot answer becomes a plain 200. Writes
# never reach the gate at all.
resource "kubernetes_config_map" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  data = {
    "default.conf" = <<-EOT
      # Gate down: standard sites get the pass header (fail open, as before
      # Turnstile), strict sites get none and fall back to their own Anubis.
      # A map, not an `if` with add_header: nginx copies the outer add_header
      # into the if block, so the strict branch sent the header too (found in
      # the 2026-10-16 fail-open drill). An empty value sends no header.
      map $arg_variant $gate_down_pass {
          strict  "";
          default "1";
      }
      upstream gate {
          server ${kubernetes_service.gate.metadata[0].name}.${kubernetes_namespace.gate.metadata[0].name}.svc.cluster.local:80;
          keepalive 16;
      }
      upstream anubis {
          server ${module.anubis.service_name}.${kubernetes_namespace.gate.metadata[0].name}.svc.cluster.local:${module.anubis.service_port};
          keepalive 16;
      }
      server {
          listen 8080;
          # Same reason as bot-block-proxy: browsers carry large cookie piles
          # for *.viktorbarzin.me, and forwardAuth passes them all through.
          client_header_buffer_size 8k;
          large_client_header_buffers 8 256k;
          access_log off;
          proxy_http_version 1.1;
          proxy_pass_request_body off;
          proxy_intercept_errors on;
          proxy_connect_timeout 1s;
          proxy_send_timeout 3s;
          proxy_read_timeout 3s;

          # /auth?variant=strict is the strict variant; the query string
          # passes through to the gate unchanged.
          location = /auth {
              if ($http_x_forwarded_method !~ ^(GET|HEAD)$) {
                  return 200;
              }
              proxy_pass http://gate;
              proxy_set_header Connection "";
              proxy_set_header Content-Length "";
              error_page 500 502 503 504 = @gate_down;
          }
          # Gate down: standard sites let everything through with the header
          # (as they were before Turnstile; without it every API call would go
          # to Anubis), strict sites fall back to their own Anubis.
          location @gate_down {
              add_header X-Turnstile-Pass $gate_down_pass;
              return 200;
          }
          # The shared Anubis, for standard sites. The gate's header (set by
          # the previous forwardAuth, and stripped from clients at the edge)
          # means the visitor already passed, so Anubis is not asked at all.
          location = /anubis {
              if ($http_x_turnstile_pass = "1") {
                  return 200;
              }
              if ($http_x_forwarded_method !~ ^(GET|HEAD)$) {
                  return 200;
              }
              proxy_pass http://anubis${local.anubis_check_uri};
              proxy_set_header Host $http_x_forwarded_host;
              proxy_set_header Connection "";
              proxy_set_header Content-Length "";
              # 400: Anubis refusing a redirect target or a missing header.
              error_page 400 500 502 503 504 = @open;
          }
          location @open {
              return 200;
          }
          location = /healthz {
              return 200 "ok";
          }
      }
    EOT
  }
}

resource "kubernetes_deployment" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.shim_labels
  }
  spec {
    replicas = 2
    selector {
      match_labels = local.shim_labels
    }
    template {
      metadata {
        labels = local.shim_labels
        annotations = {
          # nginx does not reload a ConfigMap-mounted config on its own.
          "turnstile-gate/shim-sha" = sha256(kubernetes_config_map.shim.data["default.conf"])
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.shim_labels
          }
        }
        container {
          name  = "nginx"
          image = "nginx:1.31.7"
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map.shim.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.shim_labels
  }
  spec {
    selector = local.shim_labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.shim_labels
    }
  }
}

# turnstile-gate-strip@kubernetescrd, attached by ingress_factory to every
# gated or Anubis-fronted ingress. An empty value makes Traefik delete the header.
resource "kubernetes_manifest" "strip" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "strip"
      namespace = kubernetes_namespace.gate.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Turnstile-Pass" = ""
        }
      }
    }
  }
}

locals {
  shim_url = "http://${kubernetes_service.shim.metadata[0].name}.${kubernetes_namespace.gate.metadata[0].name}.svc.cluster.local:8080"
  # The challenge page is ~4 KB; 1 MiB matches authentik-forward-auth.
  gate_middlewares = {
    auth            = "${local.shim_url}/auth?variant=strict" # sites behind their own Anubis
    "auth-standard" = "${local.shim_url}/auth"
  }
}

resource "kubernetes_manifest" "gate_auth" {
  for_each = local.gate_middlewares
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace.gate.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address             = each.value
        maxResponseBodySize = 1048576
        authResponseHeaders = ["X-Turnstile-Pass"]
      }
    }
  }
}

# The shared Anubis as the second forwardAuth on standard sites. A failed check
# comes back as Anubis's redirect to its challenge page on anubis.viktorbarzin.me.
resource "kubernetes_manifest" "anubis_auth" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "anubis"
      namespace = kubernetes_namespace.gate.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address             = "${local.shim_url}/anubis"
        maxResponseBodySize = 1048576
      }
    }
  }
}

# The fallback for sites without their own Anubis: one instance in forwardAuth
# mode, its challenge pages on anubis.viktorbarzin.me, its cookie on the whole
# domain (same signing key as every per-site instance, so a solve on either
# counts on both).
module "anubis" {
  source = "../../modules/kubernetes/anubis_instance"
  # renovate: datasource=docker depName=ghcr.io/techarohq/anubis
  image_tag        = "v1.28.1"
  name             = "shared"
  namespace        = kubernetes_namespace.gate.metadata[0].name
  public_url       = "https://${local.anubis_host}"
  redirect_domains = "${local.domain},*.${local.domain}"
  # DB index 13 — 5 to 12 are taken by the per-site instances.
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/13"
}

# The shared Anubis's own pages (challenge, pass-challenge, static assets).
module "anubis_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": this IS the bot check; it has to be reachable before any login
  auth             = "none"
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.gate.metadata[0].name
  name             = "anubis"
  full_host        = local.anubis_host
  service_name     = module.anubis.service_name
  port             = module.anubis.service_port
  tls_secret_name  = var.tls_secret_name
  turnstile        = false # it is the fallback; gating it would loop
  anti_ai_scraping = false
  homepage_enabled = false
  external_monitor = false
}

# challenge.viktorbarzin.me: POST /verify and /fallback from the challenge page
# on any site (CORS, credentials).
module "challenge_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the Turnstile verify endpoint has to be reachable before any login, that is its job
  auth              = "none"
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.gate.metadata[0].name
  name              = "challenge"
  full_host         = local.challenge_host
  service_name      = kubernetes_service.gate.metadata[0].name
  port              = 80
  tls_secret_name   = var.tls_secret_name
  extra_middlewares = ["traefik-real-ip@kubernetescrd"]
  turnstile         = false
  # A Traefik error page carries no CORS headers, so the page's fetch would
  # fail without telling it why; the gate's own answers are always JSON.
  skip_error_pages = true
  anti_ai_scraping = false
  homepage_enabled = false
  external_monitor = false
}

# /_gate/verify and /_gate/fallback on forgejo, for challenge pages the canary
# served before 2026-10-16 that are still open in a browser. Forgejo user and
# org names must start with a letter or digit, so no Forgejo route can begin
# with /_gate/. dns_type = "none": the forgejo ingress owns the record.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the Turnstile verify endpoint has to be reachable before any login, that is its job
  auth              = "none"
  dns_type          = "none"
  namespace         = kubernetes_namespace.gate.metadata[0].name
  name              = "forgejo-gate"
  full_host         = "forgejo.${local.domain}"
  ingress_path      = ["/_gate/"]
  service_name      = kubernetes_service.gate.metadata[0].name
  port              = 80
  tls_secret_name   = var.tls_secret_name
  extra_middlewares = ["traefik-real-ip@kubernetescrd"]
  homepage_enabled  = false
  external_monitor  = false
}

# The canary's single "auth" middleware became the strict entry of gate_auth.
# Without this, Terraform would delete and recreate it, and forgejo's router
# would drop for the seconds in between.
moved {
  from = kubernetes_manifest.auth
  to   = kubernetes_manifest.gate_auth["auth"]
}
