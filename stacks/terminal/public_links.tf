# Public links on terminal.viktorbarzin.me/s/ — a URL that opens one Lobby
# session, read-only or read-write, for someone who is not signed in.
# Design: terminal-lobby docs/plans/2026-10-06-public-links-design.md (ADR-0039).
#
# These are the only routes on this host without forward-auth, so each one is
# narrow:
#
#   /s/api/link/redeem  exact Path, rewritten to tmux-api /link/redeem. The one
#                       tmux-api route that serves a caller with no identity.
#                       A PathPrefix here would hand every tmux-api route to
#                       anyone who sends their own X-Authentik-Username, so it
#                       must stay an exact match.
#   /s/rw/              ttyd-link-rw (devvm :7693), read-write links
#   /s/assets/          clipboard-upload's hashed chunks, with /s stripped
#   /s/                 ttyd-link-ro (devvm :7692), the visitor page and
#                       read-only links; that ttyd runs without -W, so it takes
#                       no input at all
#
# Every route blanks the identity headers first (terminal-api-strip-identity),
# so nothing a client sends can name a user; only the redeem route then stamps
# the proxy secret, after the strip, because tmux-api checks it there. What
# authorizes an attach is a single-use ticket the page gets from redeem, spent
# by the devvm's attach scripts.
#
# The two ttyd ports are also restricted to the Traefik nodes by the devvm's
# nftables (playbooks/devvm.yml) and to the traefik namespace in-cluster
# (devvm_lobby_anp.tf), so these middlewares are always in front of them.
#
# Priorities are explicit because Traefik's default is rule length, which
# would rank the /s/ rule (two matchers) above /s/rw/.

locals {
  public_link_host = "terminal.viktorbarzin.me"
  public_link_ns   = kubernetes_namespace.terminal.metadata[0].name

  public_link_guard = [
    { name = "terminal-api-strip-identity", namespace = local.public_link_ns },
    { name = "real-ip", namespace = "traefik" },
    { name = "public-link-rate-limit", namespace = local.public_link_ns },
  ]

  public_link_ttyds = {
    "ttyd-link-ro" = 7692
    "ttyd-link-rw" = 7693
  }
}

resource "kubernetes_service" "public_link_ttyd" {
  for_each = local.public_link_ttyds
  metadata {
    name      = each.key
    namespace = local.public_link_ns
  }
  spec {
    port {
      name        = "http"
      port        = 80
      target_port = each.value
    }
  }
}

resource "kubernetes_endpoints" "public_link_ttyd" {
  for_each = local.public_link_ttyds
  metadata {
    name      = each.key
    namespace = local.public_link_ns
  }
  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = each.value
    }
  }
}

# Keyed on X-Real-Ip, which traefik/real-ip sets from the connection earlier in
# the chain. A page load is three requests and a visit is one redeem plus one
# socket, so these leave room for a reconnecting phone and stop a flood. Per
# Traefik pod (3), so the effective ceiling is about 3x.
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

# Open terminals per client. A socket is held, not repeated, so the rate limit
# does not bound it; each one holds a pty on the devvm.
resource "kubernetes_manifest" "public_link_inflight" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "public-link-inflight"
      namespace = local.public_link_ns
    }
    spec = {
      inFlightReq = {
        amount = 16
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
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
          match    = "Host(`${local.public_link_host}`) && PathPrefix(`/s/assets/`)"
          kind     = "Rule"
          priority = 300
          middlewares = concat(local.public_link_guard, [
            { name = "public-link-strip-s", namespace = local.public_link_ns },
          ])
          services = [{ name = kubernetes_service.clipboard_upload.metadata[0].name, port = 80 }]
        },
        {
          match    = "Host(`${local.public_link_host}`) && PathPrefix(`/s/rw/`)"
          kind     = "Rule"
          priority = 300
          middlewares = concat(local.public_link_guard, [
            { name = "public-link-inflight", namespace = local.public_link_ns },
          ])
          services = [{ name = kubernetes_service.public_link_ttyd["ttyd-link-rw"].metadata[0].name, port = 80 }]
        },
        {
          match    = "Host(`${local.public_link_host}`) && (Path(`/s`) || PathPrefix(`/s/`))"
          kind     = "Rule"
          priority = 200
          middlewares = concat(local.public_link_guard, [
            { name = "public-link-inflight", namespace = local.public_link_ns },
          ])
          services = [{ name = kubernetes_service.public_link_ttyd["ttyd-link-ro"].metadata[0].name, port = 80 }]
        },
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}
