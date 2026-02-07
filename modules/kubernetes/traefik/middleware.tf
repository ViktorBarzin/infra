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
        average = 5
        burst   = 250
      }
    }
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
        address            = "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik"
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
          crowdsecLapiKey  = var.crowdsec_api_key
          crowdsecLapiHost = "crowdsec-service.crowdsec.svc.cluster.local:8080"
          crowdsecMode     = "stream"
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
        average = 100
        burst   = 1000
      }
    }
  }

  depends_on = [helm_release.traefik]
}
