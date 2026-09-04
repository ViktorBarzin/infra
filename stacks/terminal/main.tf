variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "terminal" {
  metadata {
    name = "terminal"
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

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to ttyd at 10.0.10.10:7681
resource "kubernetes_service" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7681
    }
  }
}

resource "kubernetes_endpoints" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7681
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  # gzip/br/zstd the lobby HTML + the ~500 KB single-file frontend served by
  # ttyd on this main route. ttyd serves the index raw (its local patch adds
  # only ETag/no-cache), so compression lives here at the edge. Appended
  # AFTER the factory's own chain (retry/auth/…); Traefik skips the WS
  # upgrade and already-compressed bodies, so /ws and sixel are untouched.
  extra_middlewares = [
    "${kubernetes_namespace.terminal.metadata[0].name}-compress@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal"
    "gethomepage.dev/description"  = "Web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Response compression for the main terminal route (referenced above via
# extra_middlewares). Empty spec = Traefik defaults: gzip/br/zstd by
# Accept-Encoding, ~1 KB minimum, built-in skip of already-compressed
# content types. Same declaration style as the strip-prefix middlewares
# below.
resource "kubernetes_manifest" "terminal_compress" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "compress"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      compress = {}
    }
  }
}

# Clipboard image upload service (same-origin path routing)
resource "kubernetes_service" "clipboard_upload" {
  metadata {
    name      = "clipboard-upload"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "clipboard-upload"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7683
    }
  }
}

resource "kubernetes_endpoints" "clipboard_upload" {
  metadata {
    name      = "clipboard-upload"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7683
    }
  }
}

# IngressRoute for /clipboard/* on terminal.viktorbarzin.me → clipboard-upload service
resource "kubernetes_manifest" "clipboard_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "clipboard-upload"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/clipboard/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          },
          {
            name      = "clipboard-strip-prefix"
            namespace = kubernetes_namespace.terminal.metadata[0].name
          }
        ]
        services = [{
          name = "clipboard-upload"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "clipboard_strip_prefix" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "clipboard-strip-prefix"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/clipboard"]
      }
    }
  }
}

# Carve-out for the PWA manifest + icons + vendored webfonts + the push
# service worker on terminal.viktorbarzin.me. The PWA manifest fetch is
# credential-less by spec, and every OS icon fetcher (iOS Add-to-Home-Screen,
# Android WebAPK install, macOS Safari Add-to-Dock) carries no session
# cookies — behind forward-auth they get the Authentik 302 and the installed
# app falls back to a letter monogram; cookie-less webfont fetches fail the
# same way. /sw.js is the same class: the browser re-fetches the service
# worker bytes on every update check WITHOUT the session cookie, so behind
# forward-auth it would get the 302 and the worker could never register or
# update. Traefik prioritises these longer exact paths over the main "/"
# router, so ONLY these ten static files bypass Authentik; the lobby shell,
# /token, /ws, /clipboard/ and /api/sessions/ stay gated by the routes
# above. The files are served by exact-path GET handlers in
# clipboard-upload (terminal-lobby repo) from a fixed whitelist — no
# directory serving, no user data. Guarded against regression by the
# terminal-pwa-assets entry in the Authentik walling-off probe
# (stacks/monitoring/modules/monitoring/authentik_walloff_probe.tf).
module "ingress_assets" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public PWA manifest + icons, no user data; OS icon
  # fetchers carry no session cookies
  auth         = "none"
  namespace    = kubernetes_namespace.terminal.metadata[0].name
  name         = "terminal-assets"
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
    # The symbol fallback face, added 2026-09-04. JetBrains Mono ships no
    # braille and none of Claude Code's spinner glyphs, so both terminals carry
    # an Iosevka subset for them. term.html embeds it as a data: URI and needed
    # no route; the app-rendered terminal declares it in CSS and asks for it by
    # URL, and while this path was missing here it fell through to the main
    # ingress, reached ttyd, and 404ed, leaving the face at status "error" and
    # the glyphs on whatever font the client happened to have.
    "/fonts/tl-symbols.woff2",
  ]
  full_host        = "terminal.viktorbarzin.me" # MUST match the main ingress host; otherwise the factory derives terminal-assets.viktorbarzin.me and the carve-out never matches.
  dns_type         = "none"                     # host record already owned by the main terminal ingress
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # a manifest, three icons and six OFL font files; nothing for scrapers to mine
  homepage_enabled = false # path carve-out, not its own dashboard tile
}

# The two build stamps, which are NOT public assets and so are not in the
# carve-out above.
#
# tl-stamp writes share/build-id and share/term-build-id at package time
# (release/manifest.go installs them into /usr/local/share/ttyd), and
# clipboard-upload serves both. Neither path was routed anywhere, so both fell
# through to the main ingress, reached ttyd and 404ed — the same shape as the
# tl-symbols font above, and the same fix.
#
# What it cost while it was missing: ADR-0007 has the lobby update itself by
# comparing the build it is running against the build being served, and
# /build-id is where it reads the second one. A 404 there leaves the Build row
# of the connection panel reading "not checked yet" forever, and the self-update
# path falls back to refetching the whole document. Measured 2026-09-04:
# clipboard-upload answers 200 for both on :7683, ttyd answers 404.
#
# auth = "required", not "none" like the assets beside it: only the PAGE fetches
# these (frontend-v2/src/deploy/healer.ts), and the page already holds a
# session. The service worker never does — which is worth stating because sw.js
# IS in the public list, and had it been the fetcher these would have to be too.
module "ingress_build_stamps" {
  source       = "../../modules/kubernetes/ingress_factory"
  auth         = "required"
  namespace    = kubernetes_namespace.terminal.metadata[0].name
  name         = "terminal-build-stamps"
  service_name = kubernetes_service.clipboard_upload.metadata[0].name
  port         = 80
  ingress_path = [
    "/build-id",
    "/term-build-id",
  ]
  full_host        = "terminal.viktorbarzin.me" # as above: must match, or the factory derives its own host and the carve-out never matches
  dns_type         = "none"                     # host record already owned by the main terminal ingress
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # two short strings behind auth
  homepage_enabled = false # path carve-out, not its own dashboard tile
}

# === Multi-session lobby on terminal.viktorbarzin.me ===
#
# Application code (frontend, tmux-api, clipboard-upload, DevVM
# systemd units / scripts / config) lives in a separate Forgejo repo:
#   https://forgejo.viktorbarzin.me/viktor/terminal-lobby
#
# That repo's ./scripts/deploy.sh ships everything to wizard@10.0.10.10
# and restarts ttyd / tmux-api / clipboard-upload. Deploy is
# MANUAL via that script — there is no CI pipeline (the lobby's
# .woodpecker.yml was removed under ADR-0002, issue #31; it builds no
# image, so it is not part of the GHA->ghcr fleet). This stack only owns
# the Kubernetes side: Services, Endpoints pointing at
# 10.0.10.10:{7681,7683,7684}, the IngressRoutes, and the Traefik
# middlewares that gate everything behind Authentik forward-auth.
#
# Service map (DevVM):
#   ttyd               :7681  →  serves lobby + xterm WS
#   clipboard-upload   :7683  →  POST /upload, returns saved path
#   tmux-api           :7684  →  GET /sessions, DELETE /sessions/<n>,
#                                POST /sessions/<n>/rename, GET /whoami

# Service+Endpoints → tmux-api on the DevVM (port 7684).
resource "kubernetes_service" "tmux_api" {
  metadata {
    name      = "tmux-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "tmux-api"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7684
    }
  }
}

resource "kubernetes_endpoints" "tmux_api" {
  metadata {
    name      = "tmux-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7684
    }
  }
}

# IngressRoute: /api/sessions/* on terminal.viktorbarzin.me → tmux-api
# service. Path-prefix specificity beats the catch-all `module.ingress`
# (terminal.viktorbarzin.me → ttyd) above, so the lobby HTML reaches
# tmux-api directly while everything else flows to ttyd.
resource "kubernetes_manifest" "tmux_api_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "tmux-api"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/api/sessions/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          },
          {
            name      = "tmux-api-strip-prefix"
            namespace = kubernetes_namespace.terminal.metadata[0].name
          }
        ]
        services = [{
          name = "tmux-api"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "tmux_api_strip_prefix" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "tmux-api-strip-prefix"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/api/sessions"]
      }
    }
  }
}

# =============================================================================
# terminal-lobby v2 backend (roadmap pillars #1 + #6) — two new DevVM services
# behind the SAME terminal.viktorbarzin.me host, gated by Authentik like
# tmux-api. Application code lives in the terminal-lobby repo; this stack owns
# only the K8s Service/Endpoints/IngressRoutes.
#
#   session-events :7685 → normalized event stream + prompt/cancel control
#                          channel. Routes are served at ROOT with path params
#                          (/events/{session}, /prompt/{session},
#                          /cancel/{session}) → PathPrefix, NO strip. The
#                          /hooks/* endpoints are loopback-only in code
#                          (localhostOnly) and MUST NEVER be routed here.
#   file-api       :7686 → per-user file read/write/list for the preview/editor
#                          surface. Serves /files/list|read|write; the /files
#                          prefix is VERBATIM (no strip), mirroring session-events.
# =============================================================================

# --- session-events (:7685) --------------------------------------------------
resource "kubernetes_service" "session_events" {
  metadata {
    name      = "session-events"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "session-events"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7685
    }
  }
}

resource "kubernetes_endpoints" "session_events" {
  metadata {
    name      = "session-events"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7685
    }
  }
}

# IngressRoute: the authed session-events root paths → session-events.
# NO strip-prefix — session-events serves /events/{session} etc. verbatim.
# /hooks/* is deliberately absent: it is loopback-only and must stay off the
# public ingress.
#
# /search and /answer-text were added on 2026-08-18. /search finds text
# anywhere in a session's transcript — the browser holds only the last 20 turns,
# so the search has to run where the whole file is. /answer-text types the free
# text of an "Other" answer into the pane without submitting it, which is the
# one thing neither /keys (no letters, by design) nor /prompt (clears the line,
# forces an Enter) can do.
#
# /earlier, /result, /pane and /keys were added on 2026-08-16 with the text
# view's native render: older turns on demand, a capped tool result fetched in
# full, the pane behind a blocking prompt, and the keystrokes that answer one
# (terminal-lobby ADR-0010). Without them the SPA ships those features and the
# ingress 404s each one.
#
# /commands was added on 2026-08-17: the text view's `/` menu offers the
# session's OWN skills and custom commands, which the service reads off the
# user's disk. The page ships the CLI's built-ins, so a missing route costs the
# per-user half of the menu rather than the menu.
resource "kubernetes_manifest" "session_events_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "session-events"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && (PathPrefix(`/events/`) || PathPrefix(`/prompt/`) || PathPrefix(`/cancel/`) || PathPrefix(`/earlier/`) || PathPrefix(`/result/`) || PathPrefix(`/pane/`) || PathPrefix(`/keys/`) || PathPrefix(`/commands/`) || PathPrefix(`/search/`) || PathPrefix(`/answer-text/`))"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          }
        ]
        services = [{
          name = "session-events"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

# --- file-api (:7686) --------------------------------------------------------
resource "kubernetes_service" "file_api" {
  metadata {
    name      = "file-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "file-api"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7686
    }
  }
}

resource "kubernetes_endpoints" "file_api" {
  metadata {
    name      = "file-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7686
    }
  }
}

# IngressRoute: /files/* → file-api, authed, NO strip (file-api's own routes
# carry the /files prefix).
resource "kubernetes_manifest" "file_api_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "file-api"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/files/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          }
        ]
        services = [{
          name = "file-api"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

# IngressRoute: /term.html → clipboard-upload (which serves it from its static
# whitelist). AUTHED (unlike the public fonts/manifest/icons carve-out): the SPA
# frames it same-origin so the session cookie flows; the terminal connection it
# opens (/ws + /token) stays authed on ttyd regardless. NO strip — clipboard
# --- skills-api (:7688) ------------------------------------------------------
# The skill manager's backend (terminal-lobby ADR-0011). Same shape as file-api:
# a Service with hand-written Endpoints at the DevVM, and an authed IngressRoute
# that does NOT strip the prefix, because the service's own routes already carry
# /skills. It is a separate service rather than more surface on session-events so
# that releasing it cannot drop an open transcript stream, and so its one
# privileged write path stays auditable on its own.
resource "kubernetes_service" "skills_api" {
  metadata {
    name      = "skills-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "skills-api"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7688
    }
  }
}

resource "kubernetes_endpoints" "skills_api" {
  metadata {
    name      = "skills-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7688
    }
  }
}

resource "kubernetes_manifest" "skills_api_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "skills-api"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        # BOTH forms, and the bare one is load-bearing: the panel's first call is
        # GET /skills exactly (the whole inventory), with nothing after the
        # prefix, so PathPrefix(`/skills/`) alone does not match it — that
        # request fell through to the catch-all, ttyd answered 404, and the
        # Skills group rendered nothing but an error (2026-08-19). file-api needs
        # no equivalent because every one of its routes carries a verb
        # (/files/list, /files/read, /files/write). An unauthenticated probe
        # cannot tell the two cases apart, since Authentik gates the catch-all
        # too, so verify this one as a logged-in browser or against the router.
        match = "Host(`terminal.viktorbarzin.me`) && (Path(`/skills`) || PathPrefix(`/skills/`))"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          }
        ]
        services = [{
          name = "skills-api"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

# serves the exact path /term.html.
resource "kubernetes_manifest" "term_html_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "terminal-term-html"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && Path(`/term.html`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          }
        ]
        services = [{
          name = "clipboard-upload"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

# IngressRoute: /assets/ → clipboard-upload. The lobby's content-hashed build
# output lives here: the SPA's JS/CSS chunks, and an immutable copy of the
# terminal page (assets/term-<asset>.html).
#
# WHY: ttyd serves exactly one file, so anything the lobby splits out needs an
# origin of its own, and clipboard-upload already serves static files from
# /usr/local/share/ttyd. Every name under here is content-hashed, so
# clipboard-upload answers with `immutable, max-age=31536000` and a client never
# revalidates: a deploy changes the NAME rather than invalidating a path. That
# also fixes the terminal page costing ~474 KB per attach on a real device
# (measured via term.ready telemetry), where `no-cache` meant a conditional
# round trip at best and a full refetch after every deploy.
#
# AUTHED, same posture as /term.html rather than the public fonts/icons
# carve-out: these chunks ARE the application. Same-origin, so the session
# cookie flows. NO strip — clipboard-upload maps the path into its asset dir and
# validates the name (single flat directory, no separators, so no traversal).
resource "kubernetes_manifest" "lobby_assets_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "terminal-lobby-assets"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/assets/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          }
        ]
        services = [{
          name = "clipboard-upload"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

# =============================================================================
# Webterminal probe (added 2026-05-17 after a Traefik replica came up with a
# partial routing table — only the IngressRoute CRDs registered; the
# kubernetes_ingress for terminal.viktorbarzin.me was missing, so ~70% of
# /token requests routed to that replica returned 404 with router="-". The
# lobby's WebSocket retry loop kept the user stuck on "Failed to connect.
# Retrying..." because Cloudflare → that replica → 404 broke /token and the
# /ws upgrade intermittently.
#
# The probe exercises the full external path (Cloudflare → Traefik → ttyd
# Service) every 5 minutes and pushes 4 gauges to Pushgateway:
#   webterminal_probe_token_status        — HTTP status of GET /token (want 302)
#   webterminal_probe_ws_status           — HTTP status of WS upgrade /ws (want 302)
#   webterminal_probe_ttyd_status         — In-cluster ttyd /token (want 200)
#   webterminal_probe_last_success_timestamp — Unix ts of last fully-OK run
#
# Alerts live in monitoring/prometheus_chart_values.tpl group "Webterminal".
# =============================================================================

resource "kubernetes_cron_job_v1" "webterminal_probe" {
  metadata {
    name      = "webterminal-probe"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "*/5 * * * *"
    # SUSPENDED 2026-08-16 (Viktor). This ran `apk add curl python3` on EVERY
    # invocation — 47 MB written to the node's container layer per run, 288 runs
    # a day, ~13.2 GB/day of pure churn plus thousands of small-file writes,
    # which is IOPS on the shared sdc spindle rather than just bytes. That is
    # the status-page-pusher anti-pattern the other CronJobs in this repo
    # explicitly warn about.
    #
    # None of its three alerts (WebterminalTtydUnreachable / TokenDegraded /
    # WebsocketDegraded / ProbeStale) had fired in 30 days, and Uptime Kuma
    # already carries an external monitor for terminal.viktorbarzin.me, so
    # up/down coverage survives.
    #
    # WHAT IS LOST, honestly: the WebSocket-upgrade check and the
    # edge-vs-ClusterIP distinction. A broken /ws route would now present as
    # "the terminal loads but will not connect" rather than as an alert — which
    # is the exact symptom this job was built for. If that recurs, re-enable
    # (and rebuild it on python:3.12-alpine so the apk goes away: python3 is
    # already in that image and the two curl calls are trivially http.client).
    #
    # Its four alerts were removed from prometheus_chart_values.tpl in the same
    # commit — leaving them would have fired ProbeStale forever against the
    # frozen Pushgateway metrics.
    suspend = true
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        # A hung run must not block every later run. With concurrency_policy
        # Forbid and no deadline, one wedged Job stops the schedule dead: on
        # 2026-08-10 02:00 this pod's `apk add curl python3` opened a TLS
        # connection to the Alpine CDN that never returned (ESTABLISHED but
        # black-holed, no FIN/RST, and apk applies no timeout), so the Job sat
        # Running for 3d19h and the probe reported nothing for nearly four days
        # -- WebterminalProbeStale fired the whole time while the webterminal
        # itself was perfectly healthy (a fresh run returns token=302 ws=302
        # ttyd=200 in 7s). 300s is ~40x a normal run and well over the sum of
        # the script's own curl/socket timeouts, so it only ever trips on a hang.
        active_deadline_seconds    = 300
        ttl_seconds_after_finished = 600
        template {
          metadata {
            labels = {
              app = "webterminal-probe"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "probe"
              image             = "docker.io/library/alpine:3.20"
              image_pull_policy = "IfNotPresent"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
              env {
                name  = "TARGET_HOST"
                value = "terminal.viktorbarzin.me"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/webterminal-probe"
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -u
                apk add --no-cache curl python3 >/dev/null 2>&1

                # Probe 1 — HTTP GET /token (Cloudflare → Traefik → ttyd).
                # Without an Authentik cookie the response MUST be 302
                # (forward-auth redirect). 404 means a Traefik router is
                # missing on the replica that received the request.
                TOKEN_STATUS=$(curl -sk -o /dev/null -w "%%{http_code}" \
                    --max-time 10 \
                    "https://$${TARGET_HOST}/token?arg=probe" || echo 0)

                # Probe 2 — WebSocket upgrade to /ws. Same expectation: 302.
                # 404 here is what produced "Failed to connect" in the lobby
                # iframe. Use Python for a true Upgrade request — curl's
                # synthetic upgrade headers don't always trigger the WS path
                # through every Cloudflare POP.
                WS_STATUS=$(python3 - <<'PYEOF' 2>/dev/null || echo 0
                import ssl, socket, base64, os
                try:
                    ctx = ssl.create_default_context()
                    ctx.check_hostname = False
                    ctx.verify_mode = ssl.CERT_NONE
                    ctx.set_alpn_protocols(["http/1.1"])
                    sock = socket.create_connection((os.environ["TARGET_HOST"], 443), timeout=10)
                    ssock = ctx.wrap_socket(sock, server_hostname=os.environ["TARGET_HOST"])
                    key = base64.b64encode(os.urandom(16)).decode()
                    req = (
                        "GET /ws?arg=probe HTTP/1.1\r\n"
                        f"Host: {os.environ['TARGET_HOST']}\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\n"
                        "Sec-WebSocket-Version: 13\r\n"
                        "Sec-WebSocket-Protocol: tty\r\n"
                        f"Origin: https://{os.environ['TARGET_HOST']}\r\n"
                        "\r\n"
                    )
                    ssock.sendall(req.encode())
                    ssock.settimeout(5)
                    data = ssock.recv(2048)
                    ssock.close()
                    first = data.split(b"\r\n")[0].decode("ascii", "ignore")
                    parts = first.split()
                    print(parts[1] if len(parts) >= 2 and parts[1].isdigit() else 0)
                except Exception:
                    print(0)
                PYEOF
                )

                # Probe 3 — ttyd Service ClusterIP. Bypasses Cloudflare /
                # Traefik / Authentik so we can tell whether the failure mode
                # is "ttyd down" vs "edge proxy misrouting".
                TTYD_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
                    --max-time 5 -H "X-authentik-username: probe" \
                    "http://terminal.terminal.svc.cluster.local/token" || echo 0)

                OK=0
                if [ "$$TOKEN_STATUS" = "302" ] && [ "$$WS_STATUS" = "302" ] && [ "$$TTYD_STATUS" = "200" ]; then
                  OK=1
                fi
                NOW=$(date +%s)

                cat <<METRICS | curl -sf --max-time 10 --data-binary @- "$$PUSHGATEWAY" >/dev/null 2>&1 || true
                # HELP webterminal_probe_token_status HTTP status from GET /token via Cloudflare.
                # TYPE webterminal_probe_token_status gauge
                webterminal_probe_token_status $${TOKEN_STATUS:-0}
                # HELP webterminal_probe_ws_status HTTP status from WebSocket upgrade /ws via Cloudflare.
                # TYPE webterminal_probe_ws_status gauge
                webterminal_probe_ws_status $${WS_STATUS:-0}
                # HELP webterminal_probe_ttyd_status HTTP status from in-cluster ttyd /token.
                # TYPE webterminal_probe_ttyd_status gauge
                webterminal_probe_ttyd_status $${TTYD_STATUS:-0}
                # HELP webterminal_probe_last_success_timestamp Unix ts of last fully-OK probe.
                # TYPE webterminal_probe_last_success_timestamp gauge
                webterminal_probe_last_success_timestamp $$([ "$$OK" = "1" ] && echo "$$NOW" || echo 0)
                METRICS

                echo "probe: token=$${TOKEN_STATUS} ws=$${WS_STATUS} ttyd=$${TTYD_STATUS} ok=$${OK}"
              EOT
              ]
            }
          }
        }
      }
    }
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
