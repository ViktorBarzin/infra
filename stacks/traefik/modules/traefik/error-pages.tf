# Custom error pages using tarampampam/error-pages
# Serves themed error pages for 5xx errors and catch-all 404 for unknown hosts

resource "kubernetes_deployment" "error_pages" {
  metadata {
    name      = "error-pages"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "error-pages"
    }
  }

  spec {
    replicas = 2
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "error-pages"
      }
    }
    template {
      metadata {
        labels = {
          app = "error-pages"
        }
        annotations = {
          "diun.enable" = "true"
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "error-pages"
            }
          }
        }
        container {
          name  = "error-pages"
          image = "ghcr.io/tarampampam/error-pages:3"

          port {
            container_port = 8080
          }

          env {
            name  = "TEMPLATE_NAME"
            value = "shuffle"
          }

          env {
            # fasthttp's per-connection read buffer ALSO caps total request
            # header size (default 5120 bytes). Authentik forward-auth sets
            # one authentik_proxy_* cookie per protected service, all scoped
            # to .viktorbarzin.me — 30+ services puts the aggregate Cookie
            # header way past 5KB, so every error-middleware dispatch here
            # answered 431 "Too big request header" instead of the styled
            # error page (same cookie-bloat class as the 2026-06-01 openresty
            # buffer fixes on bot-block-proxy/auth-proxy).
            name  = "READ_BUFFER_SIZE"
            value = "131072"
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "32Mi"
            }
            limits = {
              memory = "32Mi"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
    ]
  }
}

resource "kubernetes_service" "error_pages" {
  metadata {
    name      = "error-pages"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "error-pages"
    }
  }

  spec {
    selector = {
      app = "error-pages"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Errors middleware — intercepts 5xx from backends and serves themed error pages
resource "kubernetes_manifest" "middleware_error_pages" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "error-pages"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      errors = {
        status = ["500-504"]
        service = {
          name      = "error-pages"
          namespace = kubernetes_namespace.traefik.metadata[0].name
          port      = 8080
        }
        query = "/{status}"
      }
    }
  }

  depends_on = [helm_release.traefik, kubernetes_service.error_pages]
}

# Default TLSStore — serves wildcard cert for unknown hosts instead of self-signed fallback
resource "kubernetes_manifest" "tlsstore_default" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "TLSStore"
    metadata = {
      name      = "default"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      defaultCertificate = {
        secretName = var.tls_secret_name
      }
    }
  }

  depends_on = [helm_release.traefik, module.tls_secret]
}

# Catch-all IngressRoute — serves 404 for unmatched *.viktorbarzin.me hosts (lowest priority)
# Only matches *.viktorbarzin.me — non-viktorbarzin.me domains get TLS rejection (no matching router)
# This prevents leaking the wildcard cert to attackers who point arbitrary domains at our IP
resource "kubernetes_manifest" "ingressroute_catchall" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "catchall-error-pages"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match    = "HostRegexp(`^(.+\\.)?viktorbarzin\\.me$`)"
        kind     = "Rule"
        priority = 1
        middlewares = [
          { name = "rate-limit", namespace = kubernetes_namespace.traefik.metadata[0].name },
          { name = "crowdsec", namespace = kubernetes_namespace.traefik.metadata[0].name },
        ]
        services = [{
          name      = "error-pages"
          namespace = kubernetes_namespace.traefik.metadata[0].name
          port      = 8080
        }]
      }]
      tls = {}
    }
  }

  depends_on = [helm_release.traefik, kubernetes_service.error_pages]
}
