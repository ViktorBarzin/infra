# Public links on terminal.viktorbarzin.me/s/ — a URL that shows one Lobby
# session's conversation, read-only, to someone who is not signed in.
# Design: terminal-lobby docs/plans/2026-10-06-public-links-design.md
# (ADR-0039, ADR-0040, ADR-0041). Links carry no terminal since ADR-0041, so
# every route here goes to tmux-api or clipboard-upload.
#
# These are the only routes on this host without forward-auth, so each one is
# narrow:
#
#   /s/api/link/redeem  exact Path, rewritten to tmux-api /link/redeem. Sets
#                       the link's view cookie. A PathPrefix here would hand
#                       every tmux-api route to anyone who sends their own
#                       X-Authentik-Username, so it must stay an exact match.
#   /s/api/link/transcript, /result, /image, /picture
#                       exact Paths, /s/api stripped, to tmux-api: the
#                       conversation and its pictures, authorized by the view
#                       cookie redeem set; same exact-match rule.
#   /s/assets/          clipboard-upload's hashed chunks, with /s stripped
#   /s, /s/             exact Paths to clipboard-upload, which serves the
#                       visitor page
#
# Every route blanks the identity headers first (terminal-api-strip-identity),
# so nothing a client sends can name a user; only the tmux-api routes then
# stamp the proxy secret, after the strip, because tmux-api checks it there.

locals {
  public_link_host = "terminal.viktorbarzin.me"
  public_link_ns   = kubernetes_namespace.terminal.metadata[0].name

  public_link_guard = [
    { name = "terminal-api-strip-identity", namespace = local.public_link_ns },
    { name = "real-ip", namespace = "traefik" },
    { name = "public-link-rate-limit", namespace = local.public_link_ns },
  ]
}

# Keyed on X-Real-Ip, which traefik/real-ip sets from the connection earlier in
# the chain. A page load is a few requests and a redeem, so these leave room
# for a reloading phone and stop a flood. Per Traefik pod (3), so the
# effective ceiling is about 3x.
resource "kubernetes_manifest" "public_link_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "public-link-rate-limit"
      namespace = local.public_link_ns
    }
    spec = {
      rateLimit = {
        average = 5
        burst   = 30
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
      }
    }
  }
}

# The read routes take a live page's poll every few seconds and every picture
# in a conversation at once, which a page-load-sized limit would cut off, so
# they get their own, looser one.
resource "kubernetes_manifest" "public_link_read_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "public-link-read-rate-limit"
      namespace = local.public_link_ns
    }
    spec = {
      rateLimit = {
        average = 20
        burst   = 120
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
      }
    }
  }
}

resource "kubernetes_manifest" "public_link_strip_api" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "public-link-strip-api"
      namespace = local.public_link_ns
    }
    spec = {
      stripPrefix = {
        prefixes = ["/s/api"]
      }
    }
  }
}

resource "kubernetes_manifest" "public_link_redeem_path" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "public-link-redeem-path"
      namespace = local.public_link_ns
    }
    spec = {
      replacePath = {
        path = "/link/redeem"
      }
    }
  }
}

resource "kubernetes_manifest" "public_link_strip_s" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "public-link-strip-s"
      namespace = local.public_link_ns
    }
    spec = {
      stripPrefix = {
        prefixes = ["/s"]
      }
    }
  }
}

resource "kubernetes_manifest" "public_link_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "terminal-public-links"
      namespace = local.public_link_ns
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match    = "Host(`${local.public_link_host}`) && Path(`/s/api/link/redeem`)"
          kind     = "Rule"
          priority = 400
          middlewares = concat(local.public_link_guard, [
            { name = "tl-proxy-secret", namespace = local.public_link_ns },
            { name = "public-link-redeem-path", namespace = local.public_link_ns },
          ])
          services = [{ name = kubernetes_service.tmux_api.metadata[0].name, port = 80 }]
        },
        {
          match = join(" || ", [
            for p in ["transcript", "result", "image", "picture"] :
            "(Host(`${local.public_link_host}`) && Path(`/s/api/link/${p}`))"
          ])
          kind     = "Rule"
          priority = 400
          middlewares = [
            { name = "terminal-api-strip-identity", namespace = local.public_link_ns },
            { name = "real-ip", namespace = "traefik" },
            { name = "public-link-read-rate-limit", namespace = local.public_link_ns },
            { name = "tl-proxy-secret", namespace = local.public_link_ns },
            { name = "public-link-strip-api", namespace = local.public_link_ns },
          ]
          services = [{ name = kubernetes_service.tmux_api.metadata[0].name, port = 80 }]
        },
        {
          match       = "Host(`${local.public_link_host}`) && PathPrefix(`/s/assets/`)"
          kind        = "Rule"
          priority    = 300
          middlewares = concat(local.public_link_guard, [{ name = "public-link-strip-s", namespace = local.public_link_ns }])
          services    = [{ name = kubernetes_service.clipboard_upload.metadata[0].name, port = 80 }]
        },
        {
          match       = "Host(`${local.public_link_host}`) && (Path(`/s`) || Path(`/s/`))"
          kind        = "Rule"
          priority    = 200
          middlewares = local.public_link_guard
          services    = [{ name = kubernetes_service.clipboard_upload.metadata[0].name, port = 80 }]
        },
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}
