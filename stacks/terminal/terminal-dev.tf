# =============================================================================
# terminal-dev.viktorbarzin.me — the v2 (SolidJS) frontend on a SECOND ttyd
# (:7687), over the SAME shared backends as terminal.viktorbarzin.me. Two
# frontends, ONE set of per-uid tmux sessions (Viktor's explicit ask): the
# vanilla page stays the daily driver on terminal.viktorbarzin.me; this host
# runs the rewrite so it can be iterated on without disturbing it.
#
# SECURITY: ttyd maps X-authentik-username → OS user (vbarzin → wizard = root),
# so the Authentik gate is the whole boundary. terminal-dev is in
# ADMIN_ONLY_HOSTS (stacks/authentik/admin-services-restriction.tf), landed in
# an EARLIER push so this ingress never exists ungated (the policy fails open —
# a host absent from that set admits any authenticated user).
#
# SHARED BACKENDS: clipboard-upload/tmux-api/session-events/file-api Services +
# their strip/compress middlewares are declared once in main.tf for the
# terminal.viktorbarzin.me routes; this file reuses them and only adds the
# terminal-dev host — a Service/Endpoints for ttyd-v2, the catch-all ingress,
# the per-path routes, and the PWA carve-out.
#
# ttyd-v2 (:7687) is deployed by terminal-lobby/scripts/deploy-v2.sh (manual,
# like deploy.sh); it serves index-v2.html (the vite single-file SPA build).
# =============================================================================

# Service+Endpoints → the second ttyd (ttyd-v2) on the DevVM (port 7687).
resource "kubernetes_service" "terminal_dev" {
  metadata {
    name      = "terminal-dev"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal-dev"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7687
    }
  }
}

resource "kubernetes_endpoints" "terminal_dev" {
  metadata {
    name      = "terminal-dev"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7687
    }
  }
}

# Catch-all "/" (+ /ws + /token) on terminal-dev.viktorbarzin.me → ttyd-v2.
# Same shape as module.ingress (the terminal.viktorbarzin.me main route): the
# factory derives host + backend Service from `name`, gates with Authentik
# forward-auth, and rides the wildcard cert/DNS (proxied, ADR-0021). The
# per-path IngressRoutes below beat this catch-all by path specificity.
module "ingress_dev" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal-dev"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  # Reuse the same edge compression as the main route — the v2 SPA is ~4.5 MB
  # raw / ~1.3 MB gzip, so compression matters most here. Traefik skips the WS
  # upgrade + already-compressed bodies, so /ws and sixel are untouched.
  extra_middlewares = [
    "${kubernetes_namespace.terminal.metadata[0].name}-compress@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal (v2 dev)"
    "gethomepage.dev/description"  = "v2 SolidJS web terminal (shares terminal's sessions)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# --- per-path routes on terminal-dev, all Authentik-gated, reusing the shared
#     backend Services + strip middlewares declared in main.tf. -------------

# /clipboard/* → clipboard-upload (strip /clipboard).
resource "kubernetes_manifest" "clipboard_dev_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "clipboard-upload-dev"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal-dev.viktorbarzin.me`) && PathPrefix(`/clipboard/`)"
        kind  = "Rule"
        middlewares = [
          { name = "authentik-forward-auth", namespace = "traefik" },
          { name = "clipboard-strip-prefix", namespace = kubernetes_namespace.terminal.metadata[0].name },
        ]
        services = [{ name = "clipboard-upload", port = 80 }]
      }]
      tls = { secretName = var.tls_secret_name }
    }
  }
}

# /api/sessions/* → tmux-api (strip /api/sessions). Covers sessions/whoami/
# rename/prefs/layout/push/* — the SPA prefixes all tmux-api calls with it.
resource "kubernetes_manifest" "tmux_api_dev_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "tmux-api-dev"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal-dev.viktorbarzin.me`) && PathPrefix(`/api/sessions/`)"
        kind  = "Rule"
        middlewares = [
          { name = "authentik-forward-auth", namespace = "traefik" },
          { name = "tmux-api-strip-prefix", namespace = kubernetes_namespace.terminal.metadata[0].name },
        ]
        services = [{ name = "tmux-api", port = 80 }]
      }]
      tls = { secretName = var.tls_secret_name }
    }
  }
}

# /events/ /prompt/ /cancel/ → session-events (NO strip; served
# verbatim). /hooks/* stays loopback-only and is deliberately NOT routed.
resource "kubernetes_manifest" "session_events_dev_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "session-events-dev"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal-dev.viktorbarzin.me`) && (PathPrefix(`/events/`) || PathPrefix(`/prompt/`) || PathPrefix(`/cancel/`))"
        kind  = "Rule"
        middlewares = [
          { name = "authentik-forward-auth", namespace = "traefik" },
        ]
        services = [{ name = "session-events", port = 80 }]
      }]
      tls = { secretName = var.tls_secret_name }
    }
  }
}

# /files/* → file-api (NO strip; file-api's routes carry the /files prefix).
resource "kubernetes_manifest" "file_api_dev_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "file-api-dev"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal-dev.viktorbarzin.me`) && PathPrefix(`/files/`)"
        kind  = "Rule"
        middlewares = [
          { name = "authentik-forward-auth", namespace = "traefik" },
        ]
        services = [{ name = "file-api", port = 80 }]
      }]
      tls = { secretName = var.tls_secret_name }
    }
  }
}

# /term.html → clipboard-upload (its static whitelist). AUTHED — the SPA frames
# it same-origin so the session cookie flows; the /ws + /token it opens hit
# ttyd-v2 via the catch-all and stay authed. NO strip (exact path).
resource "kubernetes_manifest" "term_html_dev_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "terminal-dev-term-html"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal-dev.viktorbarzin.me`) && Path(`/term.html`)"
        kind  = "Rule"
        middlewares = [
          { name = "authentik-forward-auth", namespace = "traefik" },
        ]
        services = [{ name = "clipboard-upload", port = 80 }]
      }]
      tls = { secretName = var.tls_secret_name }
    }
  }
}

# PWA carve-out (manifest + icons + fonts + sw.js) on terminal-dev — same
# reasoning as module.ingress_assets for terminal: OS icon fetchers + the sw.js
# update check carry no session cookie, so these ten exact static paths bypass
# Authentik. Everything else on the host (shell, /token, /ws, /term.html,
# /api/sessions/, /files/, /events/) stays gated by the routes above. Served by
# the shared clipboard-upload exact-path whitelist (no directory serving, no
# user data).
module "ingress_assets_dev" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public PWA manifest + icons + fonts + sw.js, no user data;
  # OS icon fetchers + the sw.js update check carry no session cookie.
  auth         = "none"
  namespace    = kubernetes_namespace.terminal.metadata[0].name
  name         = "terminal-dev-assets"
  service_name = kubernetes_service.clipboard_upload.metadata[0].name
  port         = 80
  ingress_path = [
    "/manifest.webmanifest",
    "/icon-192.png",
    "/icon-512.png",
    "/icon-512-maskable.png",
    "/sw.js",
    "/fonts/JetBrainsMono-Regular.woff2",
    "/fonts/JetBrainsMono-Bold.woff2",
    "/fonts/JetBrainsMono-Italic.woff2",
    "/fonts/JetBrainsMono-BoldItalic.woff2",
    "/fonts/dm-sans-latin-wght-normal.woff2",
  ]
  full_host        = "terminal-dev.viktorbarzin.me" # MUST match the host above; else the factory derives terminal-dev-assets.viktorbarzin.me and the carve-out never matches.
  dns_type         = "none"                         # host record already owned by module.ingress_dev
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # a manifest, three icons and five OFL font files
  homepage_enabled = false # path carve-out, not its own dashboard tile
}
