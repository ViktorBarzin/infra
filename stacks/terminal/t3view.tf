# --- t3view.viktorbarzin.me: the lobby's T3 view (terminal-lobby ADR-0044) ---
#
# The lobby frames T3 Code's web client as a third way to look at a Claude
# session, beside the terminal and the text view. tl-t3-view, a sidecar on the
# DevVM (port 7690, unit tl-t3-view.service), serves that client and speaks
# T3's protocol, translating to tmux-api and session-events.
#
# Its own host rather than a path on terminal.viktorbarzin.me: T3's client
# needs the root of its origin (/assets, /api, /ws and its own routes), and
# the lobby already uses those paths.
#
# Admin only. Authentik admits the admin group (the factory's default
# allowed_groups), and the sidecar asks tmux-api /whoami on every request and
# refuses anyone who is not a lobby admin. It verifies X-TL-Proxy-Secret
# through tmux-api as well, so tl-proxy-secret goes on this route like on the
# other secret-checking services. The WebSocket at /ws carries the session
# cookie and goes through forward-auth on the upgrade, like the lobby's own.
#
# The factory's default CSP is frame-ancestors *.viktorbarzin.me, which is
# what lets terminal.viktorbarzin.me frame it.
#
# Reach on the DevVM side: the nftables table in playbooks/devvm.yml admits
# 7690 from the Traefik nodes only, and the AdminNetworkPolicy in
# devvm_lobby_anp.tf keeps every namespace but traefik off it.

resource "kubernetes_service" "t3view" {
  metadata {
    name      = "t3view"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "t3view"
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

resource "kubernetes_endpoints" "t3view" {
  metadata {
    name      = "t3view"
    namespace = kubernetes_namespace.terminal.metadata[0].name
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

module "ingress_t3view" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "t3view"
  service_name    = kubernetes_service.t3view.metadata[0].name
  port            = 80
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_middlewares = [
    "${kubernetes_namespace.terminal.metadata[0].name}-tl-proxy-secret@kubernetescrd",
  ]
  # A cold load of T3's client fetches 286 files, 155 of them in the first
  # second (measured 2026-10-12 against the pinned build), and the default
  # per-client limit (10/s, burst 50) would answer most of them 429. Every
  # chunk is content-hashed and cached as immutable, so later loads fetch a
  # handful; the route is behind Authentik and admin only.
  skip_default_rate_limit = true
  anti_ai_scraping        = false # behind Authentik, admin only
  homepage_enabled        = false # a view inside the lobby, not a tile of its own
}
