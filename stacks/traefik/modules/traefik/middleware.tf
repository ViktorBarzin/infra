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

# Authentik forward auth middleware
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

# CrowdSec bouncer plugin middleware
resource "kubernetes_manifest" "middleware_crowdsec" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "crowdsec"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      plugin = {
        crowdsec-bouncer = {
          crowdsecLapiKey            = var.crowdsec_api_key
          crowdsecLapiHost           = "crowdsec-service.crowdsec.svc.cluster.local:8080"
          crowdsecMode               = "stream"
          updateMaxFailure           = -1 # fail-open: serve from cache when LAPI is unreachable
          redisCacheEnabled          = true
          redisCacheHost             = var.redis_host
          redisCacheUnreachableBlock = false                            # don't block traffic if Redis is also unreachable
          clientTrustedIPs           = ["10.0.20.0/24", "10.10.0.0/16"] # node + pod CIDRs bypass CrowdSec
        }
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
        average = 500
        burst   = 5000
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Strip Accept-Encoding header so backends send uncompressed responses.
# Used alongside rewrite-body plugin (rybbit analytics) which fails to
# decompress certain gzip responses (flate: corrupt input before offset 5).
# Also used by anti-AI trap links rewrite-body middleware.
resource "kubernetes_manifest" "middleware_strip_accept_encoding" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "strip-accept-encoding"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "Accept-Encoding" = ""
        }
      }
    }
  }

  depends_on = [helm_release.traefik]
}

# Re-compress responses to clients after rewrite-body plugin has modified them.
# Applied at websecure entrypoint level (outermost), so the response path is:
# backend → rewrite-body modifies uncompressed HTML → compress gzips → client.
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

# Inject hidden trap links before </body> to catch AI scrapers
# Links are CSS-hidden and aria-hidden so humans never see them
resource "kubernetes_manifest" "middleware_anti_ai_trap_links" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "anti-ai-trap-links"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      plugin = {
        traefik-plugin-rewritebody = {
          lastModified = true
          rewrites = [{
            regex       = "</body>"
            replacement = "<div style=\"position:absolute;left:-9999px;height:0;overflow:hidden\" aria-hidden=\"true\"><a href=\"https://poison.viktorbarzin.me/article/training-data-2024-research-corpus\">Research Archive</a><a href=\"https://poison.viktorbarzin.me/article/dataset-export-machine-learning-v3\">Dataset Export</a><a href=\"https://poison.viktorbarzin.me/article/nlp-benchmark-evaluation-results\">Benchmark Results</a><a href=\"https://poison.viktorbarzin.me/article/web-crawl-index-2024-archive\">Web Index</a><a href=\"https://poison.viktorbarzin.me/article/text-corpus-english-dump\">Text Corpus</a></div></body>"
          }]
          monitoring = {
            types   = ["text/html"]
            methods = ["GET"]
          }
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
