# =============================================================================
# Authentik walling-off guard
# =============================================================================
# Detects regressions where a service that MUST work WITHOUT Authentik SSO gets
# accidentally walled off — i.e. an ingress that should be `auth = "none"` (or a
# path-scoped carve-out) starts returning an Authentik forward-auth 302.
#
# The "walled off" signature (captured live 2026-06-02): a request to a
# must-stay-public URL returns 301/302 whose `Location` header points at
# Authentik:
#   https://authentik.viktorbarzin.me/application/o/authorize/?client_id=...
# A correctly-carved path returns a non-redirect (200/400/401/403/404/405/426/…)
# OR a redirect whose Location is NOT Authentik (e.g. a short-link 302).
#
# Mechanism: a tiny blackbox-exporter (below) probes each guarded URL with
# `no_follow_redirects: true` and FAILS the probe iff the `Location` header
# matches Authentik (`fail_if_header_matches`). Prometheus scrapes the probe
# (job `blackbox-authentik-walloff` in extraScrapeConfigs) and the
# `AuthentikWallingOffPublicPath` PrometheusRule (alerting_rules.yml, lane=security)
# routes a firing alert to the #security Slack receiver.
#
# Chosen over a CronJob+pushgateway probe (the apex-probe pattern) because that
# pattern's `pip install`/`apk add` per-run footprint is a known disk-write
# anti-pattern that got status-page-pusher disabled (memory id=559). blackbox is
# a single long-lived deployment — zero per-run disk writes, fully declarative.
#
# ---------------------------------------------------------------------------
# TARGET LIST — HOW TO ADD A NEW CARVE-OUT (one-line edit)
# ---------------------------------------------------------------------------
# When you add a new `auth = "none"` carve-out (or path-scoped carve-out) to any
# stack, add ONE representative GET-able URL here that returns a NON-Authentik
# response today. The map key becomes the `service` label on the probe metric
# and the alert. Verify with:
#   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' '<url>'
# It must NOT 302 to authentik.viktorbarzin.me before you add it.
# ---------------------------------------------------------------------------
locals {
  # Representative URL per `auth = "none"` carve-out service. Each MUST return a
  # non-Authentik response (200/3xx-non-authentik/400/404/426/…) when the
  # carve-out is intact. Probed every 60s; alert fires only on an Authentik 302.
  authentik_walloff_targets = {
    # meshcentral agent/relay paths (auth="none"): native mesh-cert clients.
    # /agent.ashx 404s without WebSocket upgrade headers — non-redirect = OK.
    "meshcentral-agent" = "https://meshcentral.viktorbarzin.me/agent.ashx"
    # uptime-kuma public status page (auth="none" on /status, /api/push, …).
    "uptime-status" = "https://uptime.viktorbarzin.me/status/infra"
    # shlink REST API health (auth="none"): X-Api-Key self-gated, CORS XHR.
    "shlink-rest-health" = "https://url.viktorbarzin.me/rest/health"
    # rybbit analytics tracker beacon (auth="none"): public sites embed this JS.
    "rybbit-script" = "https://rybbit.viktorbarzin.me/api/script.js"
    # insta2spotify API (auth="none"): browser fetch() XHRs, CORS preflight.
    "insta2spotify-api-health" = "https://insta2spotify.viktorbarzin.me/api/health"
    # k8s-portal setup script (auth="none"): curl-ed by automation, no cookies.
    "k8s-portal-setup-script" = "https://k8s-portal.viktorbarzin.me/setup/script"
    # instagram-poster image derivative endpoint (auth="none"): Meta's fetcher.
    # /image 404s without a query param — non-redirect = OK.
    "instagram-poster-image" = "https://instagram-poster.viktorbarzin.me/image"
    # trading-bot app root (auth="app"): WebAuthn/JWT in-app; was walled, now 200.
    "trading-bot-app" = "https://trading.viktorbarzin.me/"
    # t3 dispatch probe surface (auth="none" path carve-out on /probe): WS echo
    # + healthz for the t3-probe drop-attribution client (stacks/t3code).
    "t3-probe-ws" = "https://t3.viktorbarzin.me/probe/healthz"
    # NOTE: openclaw task-webhook (auth="none") is intentionally NOT probed — it
    # has no public DNS record (NXDOMAIN, external_monitor=false), so there is no
    # externally GET-able URL to probe. Its carve-out is internal-only.
  }
}

# --- blackbox-exporter -------------------------------------------------------
# Single-purpose blackbox-exporter. The `http_no_authentik_redirect` module does
# NOT follow redirects and FAILS the probe ONLY when the Location header points
# at Authentik. The status code alone must NEVER fail the probe — carve-outs
# legitimately return 404 (meshcentral /agent.ashx without WS headers,
# instagram-poster /image without a query) or 400/401/403/426, all of which mean
# "carve-out intact". So `valid_status_codes` enumerates every plausible
# non-Authentik response INCLUDING 301/302 — a redirect is status-valid, and the
# Authentik case is then singled out by `fail_if_header_matches` on Location
# (NOT empty: blackbox treats an empty list as "2xx only", which would
# false-fire on every 404 carve-out). probe_failed_due_to_regex isolates the
# Authentik match even further (used as a tie-break in the alert expr).
resource "kubernetes_config_map" "blackbox_exporter_config" {
  metadata {
    name      = "blackbox-exporter-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "blackbox.yml" = yamlencode({
      modules = {
        http_no_authentik_redirect = {
          prober  = "http"
          timeout = "10s"
          http = {
            method                = "GET"
            no_follow_redirects   = true
            preferred_ip_protocol = "ip4"
            ip_protocol_fallback  = false
            fail_if_not_ssl       = false
            valid_http_versions   = ["HTTP/1.1", "HTTP/2.0"]
            # Every non-Authentik response a carve-out may legitimately return.
            # 301/302 are INCLUDED so a redirect passes the status check and is
            # judged solely by the Location header match below. 5xx is excluded:
            # a backend 500 isn't a walling-off but is still worth surfacing as a
            # probe failure. The full 2xx/3xx/4xx set keeps probe_success==1 for
            # all intact carve-outs (404s included).
            valid_status_codes = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 405, 409, 410, 426, 429]
            # FAIL the probe if the response redirects to Authentik. This is the
            # walling-off signature: forward-auth 301/302 -> /application/o/authorize
            # on authentik.viktorbarzin.me (also matches /outpost.goauthentik.io).
            fail_if_header_matches = [
              {
                header        = "Location"
                regexp        = "(authentik\\.viktorbarzin\\.me|/outpost\\.goauthentik\\.io|/application/o/authorize)"
                allow_missing = true
              },
            ]
          }
        }
      }
    })
  }
}

resource "kubernetes_deployment" "blackbox_exporter" {
  metadata {
    name      = "blackbox-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "blackbox-exporter"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "blackbox-exporter"
      }
    }
    template {
      metadata {
        labels = {
          app = "blackbox-exporter"
        }
      }
      spec {
        container {
          name  = "blackbox-exporter"
          image = "prom/blackbox-exporter:v0.25.0"
          args  = ["--config.file=/etc/blackbox_exporter/blackbox.yml"]
          port {
            container_port = 9115
            name           = "http"
          }
          resources {
            requests = {
              cpu    = "5m"
              memory = "24Mi"
            }
            limits = {
              memory = "48Mi"
            }
          }
          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/blackbox_exporter/"
          }
        }
        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map.blackbox_exporter_config.metadata[0].name
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    # KEEL: monitoring ns is keel-enrolled (policy=patch) — Keel owns the image
    # tag and injects keel.sh annotations. Ignore so TF stops reverting Keel.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "blackbox_exporter" {
  metadata {
    name      = "blackbox-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "blackbox-exporter"
    }
  }
  spec {
    selector = {
      app = "blackbox-exporter"
    }
    port {
      name        = "http"
      port        = 9115
      target_port = 9115
    }
  }
}
