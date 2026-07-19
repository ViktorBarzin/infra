# Shared Traefik Middleware CRDs
# These are referenced by ingress resources via annotations like:
#   "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-rate-limit@kubernetescrd"

# Rate limiting middleware
resource "kubernetes_manifest" "middleware_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 10
        burst   = 50
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [helm_release.traefik]
}

# Authentik forward auth middleware (default — login required).
# Used by ingress_factory `auth = "required"`.
resource "kubernetes_manifest" "middleware_authentik_forward_auth" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "authentik-forward-auth"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address            = "http://auth-proxy.traefik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik"
        trustForwardHeader = true
        authResponseHeaders = [
          "X-authentik-username",
          "X-authentik-uid",
          "X-authentik-email",
          "X-authentik-name",
          "X-authentik-groups",
          "Set-Cookie",
        ]
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Authentik forward auth — public tier. Calls the dedicated public outpost
# (`ak-outpost-public.authentik.svc`) where the `Public` proxy provider is the
# only bound provider, so every request runs the `public-auto-login` flow and
# auto-binds anonymous users to the `guest` user. Users with an existing
# Authentik session keep their real identity in `X-authentik-username`.
# Used by ingress_factory `auth = "public"`.
#
# This is intentionally a different upstream from the standard middleware
# (which targets the embedded outpost via the auth-proxy nginx fallback). The
# `?app=` query param is NOT a working dispatch knob in current Authentik —
# the embedded outpost dispatches by Host header alone, and the catchall's
# forward_domain mode already claims viktorbarzin.me, so the only way to
# isolate the public flow is via a dedicated outpost.
resource "kubernetes_manifest" "middleware_authentik_forward_auth_public" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "authentik-forward-auth-public"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address            = "http://ak-outpost-public.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik"
        trustForwardHeader = true
        authResponseHeaders = [
          "X-authentik-username",
          "X-authentik-uid",
          "X-authentik-email",
          "X-authentik-name",
          "X-authentik-groups",
          "Set-Cookie",
        ]
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# IP allowlist for local-only access
resource "kubernetes_manifest" "middleware_local_only" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "local-only"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      ipAllowList = {
        sourceRange = [
          "192.168.1.0/24",
          "10.0.0.0/8",
          "fc00::/7",
          "fe80::/10",
        ]
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# IP allowlist for household access across ALL home sites: Sofia LAN + the
# WireGuard spoke LANs (London, Valchedrym) + 10/8 (VLANs, K8s pods/services,
# WG tunnel IPs). Deliberately a SEPARATE middleware from `local-only` —
# widening local-only would grant the remote LANs access to the admin surfaces
# that use it (Prometheus, iDRAC, Loki, …). Use for family-facing services
# (e.g. the immich-frame kiosks) that every household device may open but the
# public internet must not. Pair with ingress_factory `dns_type = "internal"`:
# a Cloudflare-proxied record would deliver public traffic from cloudflared
# POD IPs (inside 10/8) and silently bypass this allowlist.
resource "kubernetes_manifest" "middleware_home_lans_only" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "home-lans-only"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      ipAllowList = {
        sourceRange = [
          "192.168.1.0/24", # Sofia LAN (hub site)
          "10.0.0.0/8",     # VLANs, K8s pod/svc CIDRs, WG tunnel subnet
          "192.168.8.0/24", # London LAN (via WG tunnel)
          "192.168.9.0/24", # London GUEST net — the Portal Plus actually leases here (Portal-75AE8F9C2A8A = 192.168.9.198)
          "192.168.0.0/24", # Valchedrym LAN (via WG tunnel)
          "fc00::/7",
          "fe80::/10",
        ]
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# HTTPS redirect middleware
resource "kubernetes_manifest" "middleware_redirect_https" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "redirect-https"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      redirectScheme = {
        scheme    = "https"
        permanent = true
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# CSP headers middleware (default)
resource "kubernetes_manifest" "middleware_csp_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "csp-headers"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      headers = {
        contentSecurityPolicy = "frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Security headers middleware (HSTS, X-Frame-Options, etc.)
resource "kubernetes_manifest" "middleware_security_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "security-headers"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      headers = {
        stsSeconds           = 31536000
        stsIncludeSubdomains = true
        frameDeny            = true
        contentTypeNosniff   = true
        browserXssFilter     = true
        referrerPolicy       = "strict-origin-when-cross-origin"
        permissionsPolicy    = "camera=(), microphone=(), geolocation=()"
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# TLS option for mTLS (client certificate auth)
resource "kubernetes_manifest" "tls_option_mtls" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "TLSOption"
    metadata = {
      name      = "mtls"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      clientAuth = {
        secretNames    = ["ca-secret"]
        clientAuthType = "RequireAndVerifyClientCert"
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# ServersTransport for backends with self-signed certificates
resource "kubernetes_manifest" "servers_transport_insecure" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = "insecure-skip-verify"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      insecureSkipVerify = true
    }
  }

  depends_on = [helm_release.traefik]
}

# Strip Authentik auth headers/cookies before forwarding to backend
# Useful for backends (iDRAC, TP-Link) that break when receiving extra headers
resource "kubernetes_manifest" "middleware_strip_auth_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "strip-auth-headers"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-authentik-username" = ""
          "X-authentik-uid"      = ""
          "X-authentik-email"    = ""
          "X-authentik-name"     = ""
          "X-authentik-groups"   = ""
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Immich-specific rate limit (higher limits for photo uploads)
resource "kubernetes_manifest" "middleware_immich_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "immich-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 1000
        burst   = 20000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# ActualBudget-specific rate limit. The Actual web app boots with ~70
# near-parallel requests (55 /data/migrations/*.sql + statics, all served
# max-age=0 so every load re-validates them); the default 10/50 limiter
# 429s the tail and stalls every page load with retry backoff (the
# "Server returned an error while checking its status" screen). Burst must
# absorb a few simultaneous device boots from one client IP.
resource "kubernetes_manifest" "middleware_actualbudget_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "actualbudget-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 50
        burst   = 300
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# TripIt-specific rate limit. The trip Photos tab proxies every Immich
# thumbnail through tripit's own /api — scrolling a few-hundred-photo trip
# fires that many parallel image GETs from one client IP, and the default
# 10/50 limiter 429s the tail (fourth instance of the parallel-asset
# pattern, after ha-sofia, ActualBudget, and noVNC). Burst must absorb a
# full trip-gallery scroll plus lightbox prefetches.
resource "kubernetes_manifest" "middleware_tripit_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "tripit-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 100
        burst   = 1000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Health-specific rate limit. The redesigned, data-dense SPA loads the shell
# (JS chunks + two self-hosted Geist woff2) plus a 5-8 call API burst per page,
# and fast tab-to-tab navigation from one client IP blows past the default
# 10/50 limiter — 429ing the tail so cards/pages render empty (fifth instance
# of the burst pattern, after ha-sofia, ActualBudget, noVNC and tripit). Burst
# absorbs a couple of full page loads back-to-back.
resource "kubernetes_manifest" "middleware_health_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "health-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 100
        burst   = 1000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Authentik-specific rate limit. The login SPA cold-loads its flow-executor
# JS/CSS chunks from /static (app-served, not a CDN) plus an API burst on / —
# ~70 parallel requests on a fresh/empty-cache login. The default 10/50 limiter
# 429s the tail, and a 429'd ES-module import aborts SPA bootstrap → blank login
# screen for cold/incognito/cache-cleared clients and any clients sharing a NAT
# egress IP (sixth instance of the burst pattern, after ha-sofia, ActualBudget,
# noVNC, tripit and health). authentik was the only first-party SPA still on the
# default limiter. Burst absorbs a couple of full cold loads back-to-back.
resource "kubernetes_manifest" "middleware_authentik_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "authentik-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 100
        burst   = 1000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Dawarich-specific rate limit. The Rails app serves all its fingerprinted
# assets itself (JS/CSS chunks, SVG store badges, favicons, webmanifest) and
# the map view adds a points/API burst on load — a single page load from one
# client IP blows past the default 10/50 limiter and 429s the asset tail
# (seventh instance of the burst pattern, after ha-sofia, ActualBudget, noVNC,
# tripit, health and authentik). Background location ingestion (OwnTracks
# bridge + mobile api_key POSTs) rides the same host, so 429s here also risk
# dropped pings. Burst absorbs a couple of full page loads back-to-back.
resource "kubernetes_manifest" "middleware_dawarich_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "dawarich-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 100
        burst   = 1000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Executor-specific rate limit. The web UI is a TanStack-Router SPA that
# cold-loads ~40-60 hashed route/asset chunks in one burst on first paint,
# and because it's reached over the internal path via cloudflared (dns_type
# internal), Traefik sees a SINGLE client IP (the cloudflared pod) for all of
# it — so the default 10/50 limiter 429s the tail and the UI renders broken
# (eighth instance of the burst pattern, after ha-sofia, ActualBudget, noVNC,
# tripit, health, authentik and dawarich).
resource "kubernetes_manifest" "middleware_executor_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "executor-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 100
        burst   = 1000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Compress responses to clients at the entrypoint level (outermost).
# Applied at websecure entrypoint so all responses get compressed.
# Uses includedContentTypes (whitelist) instead of excludedContentTypes:
# - Only compresses text-based types that benefit from compression
# - Binary types (images, video, zip) are never compressed (no wasted CPU)
# - SSE (text/event-stream) is not listed = not compressed (safe for streaming)
# - WebSocket is safe regardless (Hijacker interface bypasses compress)
# - gRPC is hardcoded excluded in Traefik source (always safe)
resource "kubernetes_manifest" "middleware_compress" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "compress"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      compress = {
        minResponseBodyBytes = 1024
        includedContentTypes = [
          "text/html",
          "text/css",
          "text/plain",
          "text/xml",
          "text/javascript",
          "application/javascript",
          "application/json",
          "application/xml",
          "application/xhtml+xml",
          "application/rss+xml",
          "application/atom+xml",
          "image/svg+xml",
          "application/wasm",
          "font/woff2",
          "font/woff",
          "font/ttf",
          "application/manifest+json",
        ]
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [helm_release.traefik]
}

# ForwardAuth middleware to block known AI bot User-Agents
resource "kubernetes_manifest" "middleware_ai_bot_block" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ai-bot-block"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address            = "http://bot-block-proxy.traefik.svc.cluster.local:8080/auth"
        trustForwardHeader = true
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# x402 payment-required middleware. Traefik calls the shared x402-gateway
# in this namespace; the gateway returns 200 (allow) to browsers and curl,
# 402 with x402 PaymentRequiredResponse to declared AI-bot UAs (or to any
# request whose X-PAYMENT header fails facilitator validation).
# DRY_RUN until WALLET_ADDRESS is set on the gateway, in which case the
# gateway always returns 200.
resource "kubernetes_manifest" "middleware_x402" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "x402"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address            = "http://x402-gateway.traefik.svc.cluster.local:8080/auth"
        trustForwardHeader = true
      }
    }
  }

  depends_on = [helm_release.traefik, kubernetes_service.x402_gateway]
}

# real-ip: rewrites X-Real-Ip to the true client. Trusts Cf-Connecting-Ip only
# from the cloudflared pod peer (trustedProxyCIDRs = the pod CIDR); for any other
# peer it sets X-Real-Ip = the TCP peer — so the value is stable AND unspoofable
# by clients. Attached to every Anubis-fronted site via extra_middlewares (Anubis
# binds its auth JWT to X-Real-Ip). Replaced the old drop-x-real-ip strip, which
# fixed the 2026-07-14 home.viktorbarzin.me cookie flap but 500'd header-less
# requests (no X-Real-Ip and no XFF).
# MUST be kubectl_manifest, NOT kubernetes_manifest: a plugin-shaped Middleware
# spec (spec.plugin.<name>) breaks kubernetes_manifest's type inference and
# taints on every apply — same reason the sablier Middleware uses kubectl.
resource "kubectl_manifest" "middleware_real_ip" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "real-ip"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      plugin = {
        realip = {
          trustedProxyCIDRs = ["10.10.0.0/16"]
        }
      }
    }
  })

  depends_on = [helm_release.traefik]
}

# X-Robots-Tag header to discourage compliant AI crawlers
resource "kubernetes_manifest" "middleware_anti_ai_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "anti-ai-headers"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      headers = {
        customResponseHeaders = {
          "X-Robots-Tag" = "noai, noimageai"
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Retry middleware for transient backend failures (502/503 during restarts)
resource "kubernetes_manifest" "middleware_retry" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "retry"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      retry = {
        attempts        = 2
        initialInterval = "100ms"
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# android-emulator noVNC rate limit. noVNC 1.3 ships unbundled: vnc.html
# pulls ~60 ES modules in parallel on every page open, and the default
# 10/50 limiter 429s the tail — the loader then waits forever on the
# missing modules ("stuck on loading", verified 38x429 at a 90-request
# burst on 2026-06-12). Same remedy as actualbudget/immich.
resource "kubernetes_manifest" "middleware_android_emulator_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "android-emulator-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 50
        burst   = 300
      }
    }
  }

  depends_on = [helm_release.traefik]
}
