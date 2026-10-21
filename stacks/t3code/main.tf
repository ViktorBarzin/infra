variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "t3code" {
  metadata {
    name = "t3code"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# TLS secret `tls-secret` (wildcard *.viktorbarzin.me) is auto-cloned into this
# namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local module or
# cert material needed; the renewal pipeline updates the source and Kyverno
# propagates within seconds.

# === T3 Code over terminal-lobby sessions ====================================
# t3.viktorbarzin.me is served by tl-t3-view, the terminal-lobby sidecar on the
# DevVM (10.0.10.10:7690, unit tl-t3-view.service). T3's web, desktop and
# phone apps all connect to it as their server, and every session they show is
# a lobby session (terminal-lobby ADR-0045). It is one T3 environment for every
# lobby user: browsers are told apart by their Authentik identity, native apps
# by the bearer token they got from pairing in the lobby.
#
# The same sidecar also answers t3view.viktorbarzin.me (stacks/terminal/
# t3view.tf), the lobby's framed T3 view; that host keeps serving until a later
# stage turns it into a redirect here.
#
# This stack owns only the K8s edge:
#   browsers: Traefik (Authentik forward-auth, tl-proxy-secret) -> Service t3
#             -> 10.0.10.10:7690
#   native apps: the Authentik-less IngressRoute below -> Service t3-native
#             -> 10.0.10.10:7690
#   /probe: Service t3-dispatch-probe -> 10.0.10.10:3780 (t3-dispatch's echo)
# Reach on the DevVM side is the same as for t3view: nftables in
# playbooks/devvm.yml admits 7690 from the Traefik nodes only, and the
# ClusterNetworkPolicy in stacks/terminal/devvm_lobby_anp.tf keeps every
# namespace but traefik off it.
resource "kubernetes_service" "t3code" {
  metadata {
    name      = "t3"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels = {
      app = "t3"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7690
    }
  }
}

resource "kubernetes_endpoints" "t3code" {
  metadata {
    name      = "t3"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7690
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.t3code.metadata[0].name
  name            = "t3"
  service_name    = kubernetes_service.t3code.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # Authentik forward-auth gates the browser route and injects
  # X-authentik-username. tl-t3-view asks tmux-api /whoami for that user on
  # every request, and verifies X-TL-Proxy-Secret through tmux-api as well, so
  # tl-proxy-secret (stacks/terminal) goes on this route like on t3view. The
  # WebSocket at /ws carries the session cookie and goes through forward-auth
  # on the upgrade.
  auth = "required"
  # ADR-0023: only T3 Users reach t3 (non-admin T3 users need this row); admins via bypass.
  allowed_groups = ["T3 Users"]
  extra_middlewares = [
    "terminal-tl-proxy-secret@kubernetescrd",
  ]
  # A cold load of T3's client fetches 286 files, 155 of them in the first
  # second (measured 2026-10-12, see stacks/terminal/t3view.tf), and the
  # default per-client limit (10/s, burst 50) would answer most of them 429.
  # The route is behind Authentik and T3 Users.
  skip_default_rate_limit = true
  anti_ai_scraping        = false # behind Authentik
  # Framing is narrowed to the lobby, which shows this client as its T3 view.
  # The factory's default (frame-ancestors *.viktorbarzin.me) would let any
  # page on the site frame a signed-in T3 client, including pages other users
  # publish on pages.viktorbarzin.me.
  custom_content_security_policy = "frame-ancestors https://terminal.viktorbarzin.me"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "T3 Code"
    "gethomepage.dev/description"  = "T3 Code over your terminal-lobby sessions"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# === Native-client (desktop and phone app) access ============================
# T3's desktop and phone apps are bearer-token clients: they cannot complete
# Authentik's browser SSO redirect, so on the browser route every request they
# make 302s to the login page. The routes below skip Authentik for the requests
# only a native client makes, and send them to the same tl-t3-view.
#
# Native access is open to every lobby user. tl-t3-view is one environment for
# all of them: it answers the credential-less descriptor fetch
# (/.well-known/t3/environment) with one fixed environment id, and tells users
# apart by the bearer token it checks against tmux-api on every request. Tokens
# come from a pairing code the lobby shows ("Connect T3") and are listed and
# revocable there (terminal-lobby ADR-0045).
#
# SECURITY: these routes skip Authentik, so the sidecar's bearer and pairing
# checks are the only gate on them.
#   * They do NOT carry tl-proxy-secret. Without Authentik in front, nothing
#     overwrites X-authentik-* headers, so a client could send any username it
#     liked. The sidecar trusts an identity header only when the proxy secret
#     comes with it, so stamping the secret here would turn a forged header
#     into a trusted one. Without the secret, an identity header on these
#     routes is worthless, and the bearer path does not need one.
#   * Anyone can reach the sidecar's token check by attaching an
#     `Authorization: Bearer` header; an invalid token gets a 401. The default
#     rate-limit middleware stays attached to slow credential guessing.
resource "kubernetes_service" "t3_native" {
  metadata {
    name      = "t3-native"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3" }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7690
    }
  }
}

resource "kubernetes_endpoints" "t3_native" {
  metadata {
    name      = "t3-native"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7690
    }
  }
}

# Browser traffic is separated from native-client traffic two ways, and it
# needs both. The T3 web client authenticates same-origin with cookies and
# sends no Authorization header (apps/web/.../httpLayer.ts: bearer only when
# `window.desktopBridge` exists), so none of these rules can capture another
# user's browser session.
#
# The first discriminator is the Authentik session cookie (`authentik_proxy_
# <hash>`, scoped to viktorbarzin.me), which a browser always carries here.
# On its own it is NOT enough, because it is self-poisoning: Authentik answers
# an unauthenticated request with a 302 that CARRIES `Set-Cookie:
# authentik_proxy_…`, and the app's CFNetwork cookie jar keeps it. So the app's
# first failed attempt plants the very cookie that then disqualifies it from
# the carve-out forever — cookie-less tools (curl, the blackbox probe) pass
# while the real app is stuck on the Authentik path (observed 2026-08-13:
# `T3Code/26 CFNetwork/… Darwin/…` served 302 by the Ingress router).
#
# So the app is also identified POSITIVELY by its User-Agent, and either
# signal admits it. A browser never sends `T3Code/`, so browsers stay on the
# Authentik path — including old-WebKit ones, which is why this is a positive
# match on the app rather than a negative match on browser-only headers like
# `Sec-Fetch-*` (emo's iPadOS 15.8 Safari does not send those, and would be
# misrouted as a native client). Spoofing the UA grants no new reach: it lands
# on the same bearer check that rule 1 already exposes to anyone willing to
# set an Authorization header.
#
# Priority sits above the catch-all `Host(...)` Ingress that module.ingress
# renders, so these four win; everything else still goes through Authentik and
# tl-proxy-secret to the same sidecar.
resource "kubernetes_manifest" "t3_native_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "t3-native"
      namespace = kubernetes_namespace.t3code.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        # 1. Every authenticated API call the app makes after pairing.
        {
          kind        = "Rule"
          match       = "Host(`t3.viktorbarzin.me`) && HeaderRegexp(`Authorization`, `(?i)^Bearer `)"
          priority    = 1000
          middlewares = local.t3_native_middlewares
          services = [{
            name = kubernetes_service.t3_native.metadata[0].name
            port = 80
          }]
        },
        # 2. The two pre-pairing endpoints, which carry no credential at all:
        #    the descriptor fetch and the pairing-code -> bearer exchange.
        {
          kind        = "Rule"
          match       = "Host(`t3.viktorbarzin.me`) && (Path(`/.well-known/t3/environment`) || Path(`/oauth/token`)) && (!HeaderRegexp(`Cookie`, `authentik_proxy_`) || HeaderRegexp(`User-Agent`, `(?i)^T3Code/`))"
          priority    = 1000
          middlewares = local.t3_native_middlewares
          services = [{
            name = kubernetes_service.t3_native.metadata[0].name
            port = 80
          }]
        },
        # 3. The WebSocket. Its ticket rides the query string, not a header
        #    (authorization/remote.ts:184-190), so rule 1 cannot catch it.
        #    The ticket is ALSO the discriminator here, and a better one than
        #    either signal above: the browser's t3 WebSocket is a bare
        #    `GET /ws` authenticated by the session cookie, while a native
        #    client always carries `?wsTicket=<signed, ~5min ticket>` — so
        #    presence of the ticket separates the two on its own, and it is a
        #    real credential rather than a spoofable header.
        #    Neither signal from rules 1-2 works for this request: the app's
        #    WS upgrade sends NO User-Agent (logged as "-" 2026-08-13) while
        #    still carrying the poisoned Authentik cookie, so requiring either
        #    of them sent every upgrade to Authentik, which 302s it and kills
        #    the connection.
        {
          kind        = "Rule"
          match       = "Host(`t3.viktorbarzin.me`) && Path(`/ws`) && QueryRegexp(`wsTicket`, `.+`)"
          priority    = 1000
          middlewares = local.t3_native_middlewares
          services = [{
            name = kubernetes_service.t3_native.metadata[0].name
            port = 80
          }]
        },
        # 4. CORS preflights. T3 desktop's renderer preflights its bearer
        #    calls, and a preflight never carries the Authorization header, so
        #    rule 1 cannot catch it; on the browser route forward-auth answers
        #    it with a 302 to Authentik and the real call is never sent.
        #    A preflight carries no credential and reaches only the sidecar's
        #    CORS answer, so routing every OPTIONS here exposes nothing new.
        #    Same-origin browser requests do not preflight.
        {
          kind        = "Rule"
          match       = "Host(`t3.viktorbarzin.me`) && Method(`OPTIONS`)"
          priority    = 1000
          middlewares = local.t3_native_middlewares
          services = [{
            name = kubernetes_service.t3_native.metadata[0].name
            port = 80
          }]
        },
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

locals {
  # Mirrors the ingress_factory default chain minus the pieces that would break
  # a native JSON/WebSocket client: no Authentik (the whole point), no
  # tl-proxy-secret (see the SECURITY note above), and no anti-AI PoW/UA
  # filtering (it would block a non-browser client, same reason
  # module.ingress_probe sets anti_ai_scraping = false). error-pages only
  # intercepts 500-504, so the sidecar's JSON 4xx bodies reach the app intact.
  t3_native_middlewares = [
    { name = "retry", namespace = "traefik" },
    { name = "error-pages", namespace = "traefik" },
    { name = "rate-limit", namespace = "traefik" },
  ]
}

# === Drop-attribution probe surface ==========================================
# /probe/* on the t3 host is t3-dispatch's unauthenticated echo surface (see
# scripts/t3-dispatch/probe.go) for the t3-probe below. t3-dispatch no longer
# serves t3.viktorbarzin.me itself, but it keeps running for this echo:
# EgressOnlyDivergence (stacks/monitoring) compares the t3-probe legs that
# reach it through Cloudflare and through Traefik only. So /probe has its own
# Service, pointing at t3-dispatch, independent of Service t3. Guarded against
# Authentik re-walling by `authentik_walloff_targets` in stacks/monitoring.
resource "kubernetes_service" "t3_dispatch_probe" {
  metadata {
    name      = "t3-dispatch-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-dispatch-probe" }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 3780
    }
  }
}

resource "kubernetes_endpoints" "t3_dispatch_probe" {
  metadata {
    name      = "t3-dispatch-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 3780
    }
  }
}

module "ingress_probe" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": WS echo + healthz for the in-cluster path-health probe; no
  # user data, no T3 server reachable; auth would break the synthetic client.
  auth             = "none"
  anti_ai_scraping = false  # the probe IS a bot; PoW/UA filtering would block it
  dns_type         = "none" # main `module.ingress` owns the DNS record for this host
  namespace        = kubernetes_namespace.t3code.metadata[0].name
  name             = "t3-probe"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  service_name     = kubernetes_service.t3_dispatch_probe.metadata[0].name
  full_host        = "t3.viktorbarzin.me"
  ingress_path     = ["/probe"]
  tls_secret_name  = var.tls_secret_name
}

# t3-probe: differential WS/HTTP prober (see probe.py docstring for the
# attribution model). Runs in-cluster so it measures the shared path WITHOUT
# any user's last mile; Prometheus scrapes it via the static `t3-probe` job
# in stacks/monitoring.
resource "kubernetes_config_map_v1" "t3_probe" {
  metadata {
    name      = "t3-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }
  data = {
    "probe.py" = file("${path.module}/probe.py")
  }
}

resource "kubernetes_deployment_v1" "t3_probe" {
  metadata {
    name      = "t3-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-probe" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "t3-probe" }
    }
    template {
      metadata {
        labels = { app = "t3-probe" }
        annotations = {
          "checksum/probe" = sha256(file("${path.module}/probe.py"))
        }
      }
      spec {
        container {
          name  = "probe"
          image = "library/python:3.15.0-alpine"
          # Long-running pod, not a high-cadence CronJob: a one-time pinned
          # pip install at start (with retries against transient DNS) is the
          # lightweight alternative to owning a registry image for ~200 lines.
          command = ["sh", "-c", <<-EOT
            for i in 1 2 3 4 5; do
              pip install --no-cache-dir --quiet aiohttp==3.14.5 prometheus-client==0.26.0 && break
              echo "pip attempt $i failed; retrying" >&2; sleep 10
            done
            exec python /app/probe.py
          EOT
          ]
          port {
            container_port = 9108
            name           = "metrics"
          }
          volume_mount {
            name       = "app"
            mount_path = "/app"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "192Mi"
            }
          }
        }
        volume {
          name = "app"
          config_map {
            name = kubernetes_config_map_v1.t3_probe.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].labels["tier"],             # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }
}

resource "kubernetes_service" "t3_probe" {
  metadata {
    name      = "t3-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-probe" }
  }
  spec {
    selector = { app = "t3-probe" }
    port {
      name        = "metrics"
      port        = 9108
      target_port = 9108
    }
  }
}
