variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "t3code" {
  metadata {
    name = "t3code"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
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

# === Per-user dispatch + auto-provisioning ===================================
# t3 is single-owner (no in-app multi-user), so each person runs their OWN
# `t3 serve` instance on the DevVM as their own OS user (file perms enforced by
# the uid). A DevVM service `t3-dispatch` (10.0.10.10:3780) routes the single
# hostname t3.viktorbarzin.me by Authentik identity and auto-mints+injects the
# user's t3 session on first visit. Source of truth: /etc/ttyd-user-map. All the
# DevVM-side pieces (t3-serve@ template, reconcile, dispatch, t3-mint, sudoers)
# live in infra/scripts/ and are deployed there (outside TF, like t3-serve and
# terminal-lobby). This stack only owns the K8s edge:
#   Traefik (Authentik forward-auth, auth="required") -> Service/Endpoints
#   -> 10.0.10.10:3780 (t3-dispatch).
# See docs/plans/2026-06-01-t3-auto-provision-{design,plan}.md.
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
      target_port = 3780
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
      port = 3780
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
  # Authentik forward-auth gates t3.viktorbarzin.me and injects
  # X-authentik-username, which the DevVM t3-dispatch service maps to each user's
  # own `t3 serve` instance (per-user isolation mirroring the terminal stack).
  # The same-origin self-served UI works behind forward-auth (WS carries the
  # Authentik cookie); t3's own pairing/bearer is the inner gate, auto-injected
  # on first visit. Cross-origin clients (native app / app.t3.codes) are
  # intentionally NOT supported here — deferred until the native app is published.
  auth = "required"
  # ADR-0023: only T3 Users reach t3 (non-admin T3 users need this row); admins via bypass.
  allowed_groups = ["T3 Users"]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "T3 Code"
    "gethomepage.dev/description"  = "Coding-agent GUI (per-user, t3 serve on DevVM)"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# === Native-client (mobile/desktop app) access ===============================
# The T3 mobile app is a bearer-token client: it cannot complete Authentik's
# browser SSO redirect, so every request it makes 302s to the login page and it
# fails at the first hop with "Remote environment endpoint returned an invalid
# response" (it gets Authentik's HTML where it expects the JSON descriptor).
#
# Per-user routing is IMPOSSIBLE for a native client on a shared hostname, and
# that is a protocol constraint, not a missing feature here (verified against
# t3code @ 6bc6cb6b):
#   * connection/onboarding.ts:89-94 — the app GETs /.well-known/t3/environment
#     BEFORE it sends the pairing code, so its first request carries no
#     credential and no identity of any kind.
#   * authorization/service.ts:113,242 — every reconnect re-fetches that same
#     credential-less descriptor and hard-fails if `environmentId` changed, so
#     we cannot answer with an arbitrary instance's descriptor.
#   * rpc/http.ts:89-95 — the client sets `url.pathname = "/"`, so a per-user
#     path prefix is discarded before the request is built.
# `t3-dispatch` routes on the Authentik-injected X-authentik-username, which a
# native client never has. So native access here is scoped to ONE user
# (wizard); everyone else keeps browser access exactly as before. Lifting this
# needs upstream support for client-supplied custom headers (then the app can
# carry an Authentik credential and dispatch routes it like any browser).
#
# SECURITY: these routes deliberately skip Authentik, so t3's own bearer/pairing
# auth is the only gate on them. Two consequences worth knowing:
#   * They point STRAIGHT at wizard's `t3 serve` (:3773), NEVER at t3-dispatch
#     (:3780). Without the Authentik middleware to overwrite it, a client could
#     forge `X-authentik-username: <someone-else>` and dispatch would proxy —
#     and auto-pair — into that person's instance.
#   * Anyone can now reach wizard's t3 auth surface by attaching an
#     `Authorization: Bearer` header; an invalid token gets a t3 401. The
#     default rate-limit middleware stays attached to slow credential guessing.
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
      target_port = 3773
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
      port = 3773
    }
  }
}

# Browser traffic is separated from native-client traffic two ways, and it
# needs both. The t3 web UI authenticates same-origin with cookies and sends NO
# Authorization header (apps/web/.../httpLayer.ts: bearer only when
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
# on the same t3 bearer gate that rule 1 already exposes to anyone willing to
# set an Authorization header.
#
# Priority sits above the catch-all `Host(...)` Ingress that module.ingress
# renders, so these three win; everything else still goes through Authentik to
# t3-dispatch and per-user routing is untouched.
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
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

locals {
  # Mirrors the ingress_factory default chain minus the pieces that would break
  # a native JSON/WebSocket client: no Authentik (the whole point), and no
  # anti-AI PoW/UA filtering (it would block a non-browser client, same reason
  # module.ingress_probe sets anti_ai_scraping = false). error-pages only
  # intercepts 500-504, so t3's JSON 4xx bodies reach the app intact.
  t3_native_middlewares = [
    { name = "retry", namespace = "traefik" },
    { name = "error-pages", namespace = "traefik" },
    { name = "rate-limit", namespace = "traefik" },
  ]
}

# === Drop-attribution probe surface ==========================================
# /probe/* on the t3 host is dispatch's unauthenticated echo surface (see
# scripts/t3-dispatch/probe.go) for the t3-probe below. Guarded against
# Authentik re-walling by `authentik_walloff_targets` in stacks/monitoring.
module "ingress_probe" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": WS echo + healthz for the in-cluster path-health probe; no
  # user data, no t3 instance reachable — auth would break the synthetic client.
  auth             = "none"
  anti_ai_scraping = false  # the probe IS a bot; PoW/UA filtering would block it
  dns_type         = "none" # main `module.ingress` owns the DNS record for this host
  namespace        = kubernetes_namespace.t3code.metadata[0].name
  name             = "t3-probe"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  service_name     = kubernetes_service.t3code.metadata[0].name
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
          image = "python:3.12-alpine"
          # Long-running pod, not a high-cadence CronJob: a one-time pinned
          # pip install at start (with retries against transient DNS) is the
          # lightweight alternative to owning a registry image for ~200 lines.
          command = ["sh", "-c", <<-EOT
            for i in 1 2 3 4 5; do
              pip install --no-cache-dir --quiet aiohttp==3.9.5 prometheus-client==0.20.0 && break
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
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],                    # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
      metadata[0].labels["tier"],                                         # stamped by Kyverno sync-tier-label-from-namespace
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
