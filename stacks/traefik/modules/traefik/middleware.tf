# Shared Traefik Middleware CRDs
# These are referenced by ingress resources via annotations like:
#   "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-rate-limit@kubernetescrd"

# Rate limiting middleware.
#
# THIS IS A CHAIN, NOT THE LIMITER. `rate-limit` is the name ~115 ingresses
# reference (ingress_factory auto-attaches it, plus two hand-rolled ingresses in
# stacks/owntracks and stacks/freedify and the reverse_proxy factory), so the
# name stays and the chain expands in place: real-ip first, then the limiter.
#
# WHY A CHAIN. Until 2026-09-09 this was a bare rateLimit with no
# `sourceCriterion`, which Traefik turns into an IPStrategy over "the request's
# remote address field" (rate_limiter.go New(): a nil SourceCriterion becomes
# &dynamic.IPStrategy{}). Behind the cloudflared tunnel that remote address is
# the cloudflared pod, so every external viewer of every PROXIED host shared ONE
# bucket of 10 req/s. The fix is to key on X-Real-Ip, which the vendored real-ip
# plugin overwrites from the unspoofable TCP peer.
#
# But real-ip was only attached to anubis-* backends (ingress_factory:408).
# Verified on the live forgejo Ingress the same day: its chain was
# retry, error-pages, rate-limit, csp-headers, ai-bot-block, anti-ai-headers,
# buffering — no real-ip anywhere. Adding `requestHeaderName` alone would
# therefore have made things WORSE, not better, for the ~110 non-Anubis
# ingresses:
#
#   - Missing header means an empty key, not a fallback. oxy's
#     makeHeaderExtractor returns req.Header.Get() with no missing-header check,
#     so every request without the header shares a single bucket keyed "". For
#     the NON-PROXIED hosts (forgejo, kms, mail) that is a straight regression:
#     pfSense PROXY-protocol already put the real client in the remote address,
#     so they had working per-client buckets and would have lost them.
#   - Without real-ip the header is client-supplied, so a crawler sending a
#     random X-Real-Ip per request would mint itself an unlimited number of
#     buckets.
#
# Putting real-ip inside the chain fixes both in ONE apply of this stack. The
# alternative — attaching real-ip per-ingress in ingress_factory — fans a
# modules/ change out over ~95 app stacks applied serially, and until each one
# re-applied its ingress would carry the new source key with no header to read.
# The other alternative, adding real-ip to the websecure ENTRYPOINT chain, is a
# static-config change (helm upgrade plus a 3-replica roll) and that block is
# deliberately left alone.
#
# ORDER IS LOAD-BEARING and this is the whole reason for the chain: reached
# before real-ip, the header extractor returns "" for every request and they all
# share one bucket again — no error, just silent collapse.
#
# Running real-ip twice on an Anubis-fronted ingress is harmless: it recomputes
# from the TCP peer, which no middleware changes, so the second pass writes the
# same value.
#
# WHAT THIS DOES NOT DO. Per-client buckets still cannot catch a crawl that
# sends one request per address — 1,993 distinct addresses each making a single
# request never fill any per-client bucket. That is what
# viktor/distributed-crawl-range in stacks/crowdsec is for. And the limits stay
# PER-POD across the 3 Traefik replicas, so the real ceiling is ~3x nominal
# (~30 req/s average, ~150 burst). Traefik 3.7 can share buckets through Redis
# (`rateLimit.redis`), which would make the numbers mean what they say; not done
# here because it puts Redis on the hot path of every request.
resource "kubernetes_manifest" "middleware_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      chain = {
        middlewares = [
          { name = kubectl_manifest.middleware_real_ip.name },
          { name = kubernetes_manifest.middleware_rate_limit_per_client.manifest.metadata.name },
        ]
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [helm_release.traefik]
}

# The actual limiter. Same 10/50 as before — no new ceiling here, deliberately:
# the 2026-09-09 crawl came through with zero 5xx and zero 504s, so the numbers
# are not what failed, and eight prior per-app carve-outs
# (actualbudget, tripit, health, authentik, dawarich, immich, f1, android-emulator)
# say a tighter global ceiling is the change most likely to break real traffic.
#
# What changed is the bucket KEY. Reference it through `rate-limit` above, never
# directly, or real-ip will not have run and the key will be empty.
resource "kubernetes_manifest" "middleware_rate_limit_per_client" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "rate-limit-per-client"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 10
        burst   = 50
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
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
          # Break-glass marker. When the embedded outpost 5xxs, the auth-proxy
          # nginx @fallback_auth block serves the static htpasswd and stamps
          # `X-authentik-username: admin` plus `X-Auth-Fallback: true`. Without
          # the header listed here Traefik drops it, so backends and logs see a
          # basic-auth break-glass principal as an indistinguishable SSO admin.
          # Listing it also makes it unforgeable: Traefik deletes each listed
          # header from the client request before copying the auth server's
          # value, so a client-supplied X-Auth-Fallback never reaches a backend.
          "X-Auth-Fallback",
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
          # Same break-glass marker as the standard middleware. This tier talks
          # to the dedicated public outpost directly, so the auth-proxy nginx
          # fallback cannot fire on it and the header should never be set here.
          # Listed regardless: Traefik deletes every listed header from the
          # client request, so this is what stops a client from spoofing
          # X-Auth-Fallback into a public-tier backend, and it keeps the two
          # lists identical so a future header addition is not missed on one.
          "X-Auth-Fallback",
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
# Useful for backends (iDRAC, TP-Link) that break when receiving extra headers.
#
# X-Auth-Fallback is blanked here too, and this is the SAFE DEFAULT. Where this
# middleware is a route's only anti-spoof control (health/health-api, tripit x3,
# vpn-portal/vpn-portal-sub) a client could otherwise send X-Auth-Fallback itself
# and have it reach the backend untouched, claiming the break-glass principal
# that the nginx auth fallback stamps. Routes where this runs AFTER forward-auth
# need the genuine marker instead, and use the keep-fallback variant below.
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
          "X-Auth-Fallback"      = ""
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [helm_release.traefik]
}

# Same strip, but LEAVES X-Auth-Fallback intact. For routes where this runs after
# traefik-authentik-forward-auth, so the header was stamped by our own auth layer
# rather than sent by the client. Used by the reverse-proxy factory (gw, idrac),
# whose middleware chain puts forward-auth on the line above the strip.
resource "kubernetes_manifest" "middleware_strip_auth_headers_keep_fallback" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "strip-auth-headers-keep-fallback"
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

  field_manager {
    force_conflicts = true
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

# crowdsec: enforces CrowdSec ban decisions in-process. Attached to the
# `websecure` ENTRYPOINT (main.tf), not to individual routers, so it covers all
# ~195 Ingresses, the 10 IngressRoutes and the catchall without per-ingress
# wiring — including the hand-rolled ingresses that bypass ingress_factory.
#
# Why in-process rather than the Cloudflare edge: every HTTP host in the zone is
# proxied (`cloudflare_proxied_names = []`), so proxied traffic reaches Traefik
# from the cloudflared pod and the L3 nftables bouncer only ever sees 10.10.x.x.
# The edge channel that covered those hosts is throttled by a hard 72h floor
# between successful Lists-API writes, so the edge list disagreed with LAPI for
# 107 of 216 observed hours. Here a decision lands within one poll (~30s).
#
# Why not ForwardAuth: Traefik's forward.go answers 500/502 when the auth backend
# is unreachable with no option to allow (which is why auth-proxy and
# bot-block-proxy exist as shims), and a ForwardAuth backend's RemoteAddr is
# always a Traefik pod, so it cannot tell a real Cf-Connecting-Ip from a spoofed
# one. In-process both problems disappear.
#
# MUST be kubectl_manifest, NOT kubernetes_manifest: a plugin-shaped Middleware
# spec (spec.plugin.<name>) breaks kubernetes_manifest's type inference and
# taints on every apply — same reason real-ip and sablier use kubectl.
resource "kubectl_manifest" "middleware_crowdsec" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "crowdsec"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      plugin = {
        crowdsec = {
          lapiUrl = "http://crowdsec-service.crowdsec.svc.cluster.local:8080"
          lapiKey = var.crowdsec_bouncer_key
          # Fresh enough that an unban is felt immediately (the whole point of
          # moving off the edge), cheap because the origin filter below keeps the
          # response at a few KB.
          pollSeconds = 30
          # Origins to ENFORCE. CAPI is deliberately ABSENT: it is ~22.7k
          # community bans that have never been enforced on proxied hosts, and
          # its false positives (CGNAT, carrier ranges) would land as
          # user-visible 403s. It is already dropped in-kernel on direct hosts by
          # cs-firewall-bouncer. Adding "CAPI" enables it — measure in dryRun
          # first, and note the snapshot then weighs ~3MB per poll.
          origins = ["crowdsec", "cscli", "cscli-import", "lists", "console"]
          # Trust Cf-Connecting-Ip / X-Forwarded-For ONLY from the cloudflared pod
          # peer; any other peer is judged on its own unspoofable TCP address.
          # Same model and same CIDR as real-ip.
          trustedProxyCIDRs = ["10.10.0.0/16"]
          # Never gate the auth hosts: a false-positive ban must not be able to
          # wall someone out of the login / WebAuthn flow they would need to fix
          # it. Carried over from the Cloudflare WAF rule this replaces.
          skipHosts = ["authentik.viktorbarzin.me", "public-auth.viktorbarzin.me"]
          # ENFORCING. It landed as dryRun=true first and the measured window was
          # clean: zero organic would-blocks in an hour, since the enforced set is
          # currently the 4 non-CAPI decisions (cscli-import scanner IPs). The
          # only dry-run hits were the deliberate test bans.
          #
          # Flip back to true to decide-and-log without blocking. Either way the
          # decision lines are `[crowdsec-bouncer] action=block|dry-run-block ...`
          # on the traefik pods' stdout, which is also the alerting surface
          # (Prometheus counters are not cheaply available inside Yaegi).
          dryRun = false
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

# f1-stream video rate limit. Separate from the shared `rate-limit` above
# because f1 serves HLS, and HLS is a request-per-segment protocol rather than
# a page load.
#
# Why a separate middleware and not a bump to the shared one: 115 ingresses
# reference `rate-limit`, and raising it for all of them to suit one video host
# would remove a limit those hosts still want.
#
# Two problems it fixes, in order of severity.
#
# 1. THE BUCKET KEY. The shared `rate-limit` sets no `sourceCriterion`, so
#    Traefik falls back to an IPStrategy over "the request's remote address
#    field" (rate_limiter.go New(): a nil SourceCriterion becomes
#    &dynamic.IPStrategy{}). Behind the cloudflared tunnel that remote address
#    is the cloudflared pod, so every viewer on the planet shares ONE bucket of
#    10 req/s. `requestHeaderName = "X-Real-Ip"` moves the key to the real
#    client. This works because ingress_factory auto-attaches the `real-ip`
#    plugin FIRST for every anubis-* backend and extra_middlewares are appended
#    LAST, so real-ip has already stamped X-Real-Ip by the time this runs —
#    on the tunnel path from Cf-Connecting-Ip, on the grey-cloud path from the
#    unspoofable TCP peer (real-ip-plugin/main.go:125 sets it unconditionally
#    once the peer parses). Order is load-bearing: reached before real-ip, the
#    oxy header extractor returns "" for every request and they all share one
#    bucket again — no error, just silent collapse (oxy utils/source.go
#    makeHeaderExtractor returns req.Header.Get() with no missing-header check).
#    NOTE the collapse this fixes is pre-existing for the five other proxied
#    Anubis hosts (blog, jsoncrack, cyberchef, homepage, real-estate-crawler);
#    fixing it here does not fix it for them.
#
# 2. THE CEILING. Measured against the app's own constants rather than guessed:
#      - live ladder: SEGMENT_SECONDS = 4, PLAYLIST_LENGTH = 6
#        (f1-stream backend/transcode.py:75, :91)
#      - replay ladder: SEGMENT_SECONDS = 6, three rungs
#        (backend/replays/library.py:51, :87), and the upstream feeds run 6s too
#        (backend/pdt.py:75-77)
#    So one viewer costs ~0.5 req/s live (a segment plus a media-playlist
#    refresh every 4s) and ~0.33 req/s on a replay. The bursts are what bite:
#    a cold start with p2p-media-loader prefetching a 20-30s buffer pulls ~8
#    segments plus two playlists at once, a replay seek fires a Range storm,
#    and the SvelteKit SPA shell has the same parallel-asset shape that already
#    pushed actualbudget, tripit, health, authentik, dawarich and noVNC off the
#    default 10/50.
#    average 200 / burst 2000 (per second — Traefik's default period) is ~80x
#    the worst realistic steady state (a five-person watch party sharing one
#    CGNAT egress, ~2.5 req/s) and ~25x its worst burst. Deliberately loose:
#    a 429 on a segment is a stall mid-race, the request itself is a static
#    file read or a proxy pass, and abuse is already covered by CrowdSec at the
#    entrypoint, the Anubis PoW on the HTML and the x402 gateway. Sits between
#    the 100/1000 SPA family and immich's 1000/20000.
#
# RIGHTSIZING NOTE: do not fold this back into the shared 10/50. The numbers
# above are the reason it exists, and the sourceCriterion is not optional on a
# tunnelled host.
resource "kubernetes_manifest" "middleware_f1_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "f1-rate-limit"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 200
        burst   = 2000
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}
