# terminal-api.viktorbarzin.me — Terminal Lobby's HTTP APIs for machine
# clients on the public internet (first caller: Meta Muse, which runs in Meta's
# cloud with no VPN). The browser host terminal.viktorbarzin.me is untouched.
#
# Layers, outermost first:
#   1. Source-IP allowlist (local.api_allowed_sources): Cloudflare WARP, which
#      Muse egresses through, plus mx2. Everyone else gets 403 at Traefik.
#   2. CrowdSec bouncer (websecure entrypoint) + a 401 ban scenario for this
#      host (stacks/crowdsec).
#   3. Per-client rate limit and concurrency cap.
#   4. Lobby's own bearer check (authuser, sha256 digests, constant-time). The
#      header path is closed here on purpose: this host injects NO proxy
#      secret and blanks the identity headers, so a forged
#      X-Authentik-Username cannot authenticate. A bearer token is the only
#      way in. Do not add tl-proxy-secret to these routes.
#
# Exposed: agent-api /v1/* and /openapi.json, tmux-api (minus /metrics,
# /health, /push*, /internal/*), session-events, file-api /files/*,
# skills-api. NOT exposed: ttyd (/, /ws, /token — an interactive shell),
# clipboard-upload (reads the body before checking auth), assets and build
# stamps.
#
# A valid token acts as the OS user it maps to (muse -> wizard, Viktor's
# decision 2026-10-02), which on this box means sudo, cluster-admin and Vault.
#
# Runbook: docs/runbooks/terminal-api.md

variable "public_ip" { type = string }
variable "public_ipv6" { type = string }
variable "cloudflare_zone_id" { type = string }

locals {
  api_host = "terminal-api.viktorbarzin.me"

  # Who may reach the API at all.
  #
  # Muse does not egress from Meta's address space: its requests arrive from
  # Cloudflare WARP, rotating across 2a09:bac1::/32 and 2a09:bac5::/32 almost
  # per request (seen 2026-10-02). 2a09:bac0::/29 is the WARP IPv6 block
  # (bac0 through bac7 each register as CLOUDFLAREWARP, AS13335). WARP is
  # shared by everyone running the free app, so this list cannot single Muse
  # out; it keeps non-WARP traffic (datacenter scanners, botnets) from ever
  # reaching the token check, and the bearer token is what identifies Muse.
  # Viktor chose this over removing the allowlist (2026-10-02). No WARP IPv4
  # range is listed: Muse has only used IPv6, and 104.28.0.0/16 registers as
  # generic CLOUDFLARENET, not WARP. Add one only if Muse is seen using it.
  api_allowed_sources = [
    "2a09:bac0::/29",  # Cloudflare WARP IPv6 (Muse's egress)
    "92.5.132.215/32", # mx2, external verification vantage
  ]

  # Shared by every route below. Order: cheapest refusal first.
  api_middlewares = [
    { name = "terminal-api-allowlist", namespace = kubernetes_namespace.terminal.metadata[0].name },
    { name = "terminal-api-strip-identity", namespace = kubernetes_namespace.terminal.metadata[0].name },
    { name = "real-ip", namespace = "traefik" },
    { name = "terminal-api-rate-limit", namespace = kubernetes_namespace.terminal.metadata[0].name },
    { name = "terminal-api-inflight", namespace = kubernetes_namespace.terminal.metadata[0].name },
  ]
}

# --- agent-api backend (devvm 10.0.10.10:8710) ---
# agent-api binds loopback plus TL_AGENT_BIND (playbooks/devvm.yml sets
# 10.0.10.10); the devvm's nftables lets only the Traefik nodes reach 8710.
resource "kubernetes_service" "agent_api" {
  metadata {
    name      = "agent-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }
  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 8710
    }
  }
}

resource "kubernetes_endpoints" "agent_api" {
  metadata {
    name      = "agent-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }
  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 8710
    }
  }
}

# --- middlewares ---
resource "kubernetes_manifest" "terminal_api_allowlist" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "terminal-api-allowlist"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      # Default strategy = the connection's remote address, which is the real
      # client here: the host is non-proxied, Traefik's IPv4 Service is
      # externalTrafficPolicy Local, and IPv6 arrives with PROXY v2 trusted
      # only from pfSense. Do not add an ipStrategy that reads headers.
      ipAllowList = {
        sourceRange = local.api_allowed_sources
      }
    }
  }
}

# Closes the header path: with no X-TL-Proxy-Secret the services refuse the
# identity header anyway, and blanking these makes sure a client can supply
# neither. An empty value in customRequestHeaders removes the header.
resource "kubernetes_manifest" "terminal_api_strip_identity" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "terminal-api-strip-identity"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Authentik-Username" = ""
          "X-Forwarded-User"     = ""
          "X-TL-Proxy-Secret"    = ""
        }
      }
    }
  }
}

# Keyed on X-Real-Ip, which traefik/real-ip (earlier in the chain) sets from
# the connection; same pattern as traefik/rate-limit-per-client. Per Traefik
# pod, and there are 3, so the effective ceiling is about 3x these numbers.
resource "kubernetes_manifest" "terminal_api_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "terminal-api-rate-limit"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 5
        burst   = 20
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
      }
    }
  }
}

# Caps concurrent requests per client, which a rate limit does not: long-lived
# event streams and slow bodies are held open, not repeated.
resource "kubernetes_manifest" "terminal_api_inflight" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "terminal-api-inflight"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      inFlightReq = {
        amount = 10
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
      }
    }
  }
}

# agent-api's ?wait=N (send-and-wait and task long-poll, up to 300 s) holds the
# request and sends headers only when the wait ends. Traefik's global
# serversTransport gives a backend 30 s to send headers
# (forwardingTimeouts.responseHeaderTimeout in stacks/traefik), so without this
# every wait past 30 s came back as a 504. 330 s = the 300 s cap plus margin.
resource "kubernetes_manifest" "terminal_api_longpoll_transport" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = "terminal-api-longpoll"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      forwardingTimeouts = {
        responseHeaderTimeout = "330s"
      }
    }
  }
}

# --- routes ---
# One IngressRoute, so every router is named terminal-terminal-api-<hash>; the
# Prometheus alert and dashboards match on that prefix. Anything not matched
# here falls to traefik's catch-all error page.
resource "kubernetes_manifest" "terminal_api_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "terminal-api"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match       = "Host(`${local.api_host}`) && PathPrefix(`/v1/`)"
          kind        = "Rule"
          middlewares = local.api_middlewares
          services = [{
            name             = kubernetes_service.agent_api.metadata[0].name
            port             = 80
            serversTransport = kubernetes_manifest.terminal_api_longpoll_transport.manifest.metadata.name
          }]
        },
        {
          # agent-api's API description. Callers build and refresh their
          # connector from the live contract. agent-api serves it without a
          # token (a caller has to read it before it can call anything) and it
          # holds routes, not data. Exact Path, so /health stays unrouted.
          match       = "Host(`${local.api_host}`) && Path(`/openapi.json`)"
          kind        = "Rule"
          middlewares = local.api_middlewares
          services = [{
            name = kubernetes_service.agent_api.metadata[0].name
            port = 80
          }]
        },
        {
          # tmux-api serves /metrics, /health, /push/* and /internal/* without
          # a login (they assume a private listener); keep them off this host.
          match = "Host(`${local.api_host}`) && PathPrefix(`/api/sessions/`) && !PathRegexp(`^/api/sessions/(metrics|health|internal|push)`)"
          kind  = "Rule"
          middlewares = concat(local.api_middlewares, [
            { name = "tmux-api-strip-prefix", namespace = kubernetes_namespace.terminal.metadata[0].name },
          ])
          services = [{ name = "tmux-api", port = 80 }]
        },
        {
          match       = "Host(`${local.api_host}`) && (PathPrefix(`/events/`) || PathPrefix(`/prompt/`) || PathPrefix(`/cancel/`) || PathPrefix(`/earlier/`) || PathPrefix(`/result/`) || PathPrefix(`/pane/`) || PathPrefix(`/keys/`) || PathPrefix(`/commands/`) || PathPrefix(`/search/`) || PathPrefix(`/answer-text/`) || PathPrefix(`/answer/`) || PathPrefix(`/model/`))"
          kind        = "Rule"
          middlewares = local.api_middlewares
          services    = [{ name = "session-events", port = 80 }]
        },
        {
          match       = "Host(`${local.api_host}`) && PathPrefix(`/files/`)"
          kind        = "Rule"
          middlewares = local.api_middlewares
          services    = [{ name = "file-api", port = 80 }]
        },
        {
          match       = "Host(`${local.api_host}`) && (Path(`/skills`) || PathPrefix(`/skills/`))"
          kind        = "Rule"
          middlewares = local.api_middlewares
          services    = [{ name = "skills-api", port = 80 }]
        },
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
  depends_on = [
    kubernetes_manifest.terminal_api_allowlist,
    kubernetes_manifest.terminal_api_strip_identity,
    kubernetes_manifest.terminal_api_rate_limit,
    kubernetes_manifest.terminal_api_inflight,
    kubernetes_manifest.terminal_api_longpoll_transport,
  ]
}

# --- DNS ---
# Non-proxied so Traefik sees the real client address (the allowlist and the
# per-client limits depend on it). Internal DNS: technitium static_records.tf.
resource "cloudflare_record" "terminal_api_a" {
  name            = "terminal-api"
  content         = var.public_ip
  proxied         = false
  ttl             = 1
  type            = "A"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

resource "cloudflare_record" "terminal_api_aaaa" {
  name            = "terminal-api"
  content         = var.public_ipv6
  proxied         = false
  ttl             = 1
  type            = "AAAA"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

# --- in-cluster reach to the devvm Lobby ports ---
# The devvm's nftables admits the Traefik NODE addresses, and Calico SNATs
# every pod's egress to its node address, so without this any pod on those
# nodes could reach ttyd (7681, header-trust auth) or skip Traefik's
# allowlist and limits on 8710. AdminNetworkPolicy is evaluated before
# namespace NetworkPolicies and Calico's default tier, and traffic it does not
# match continues to them unchanged.
locals {
  devvm_lobby_ports = [
    { portNumber = { protocol = "TCP", port = 7681 } },
    { portRange = { protocol = "TCP", start = 7683, end = 7688 } },
    { portNumber = { protocol = "TCP", port = 8710 } },
  ]
}

resource "kubernetes_manifest" "devvm_lobby_anp" {
  manifest = {
    apiVersion = "policy.networking.k8s.io/v1alpha1"
    kind       = "AdminNetworkPolicy"
    metadata = {
      name = "devvm-lobby-ports"
    }
    spec = {
      priority = 10
      subject = {
        namespaces = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            # traefik: the proxy itself. monitoring: scrapes tmux-api :7684
            # (prometheus_chart_values.tpl). headscale: the subnet-router probe
            # checks ttyd :7681 (subnet-router-probe.tf). The second policy
            # below narrows those two to the one port each needs.
            values = ["traefik", "monitoring", "headscale"]
          }]
        }
      }
      egress = [{
        name   = "deny-devvm-lobby"
        action = "Deny"
        to     = [{ networks = ["10.0.10.10/32"] }]
        ports  = local.devvm_lobby_ports
      }]
    }
  }
}

resource "kubernetes_manifest" "devvm_lobby_anp_observers" {
  manifest = {
    apiVersion = "policy.networking.k8s.io/v1alpha1"
    kind       = "AdminNetworkPolicy"
    metadata = {
      name = "devvm-lobby-ports-observers"
    }
    spec = {
      priority = 11
      subject = {
        namespaces = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["monitoring", "headscale"]
          }]
        }
      }
      egress = [{
        name   = "deny-devvm-lobby-except-probes"
        action = "Deny"
        to     = [{ networks = ["10.0.10.10/32"] }]
        ports = [
          { portNumber = { protocol = "TCP", port = 7683 } },
          { portRange = { protocol = "TCP", start = 7685, end = 7688 } },
          { portNumber = { protocol = "TCP", port = 8710 } },
        ]
      }]
    }
  }
}
