# Ingest path (ADR-0041): /_t/ on every host we serve, so browsers load the
# analytics script and send events same-origin. One route with no Host
# matcher covers every app without per-stack changes. Its priority sits
# above app routes (Traefik's default priority is the rule's length). No
# forward-auth: beacons have to work for signed-out visitors.
#
#   /_t/r/...  -> Rybbit /api/...        (script.js, track, identify, replay)
#   /_t/e/...  -> Event pipeline (Vector) (Segment SDK endpoints)
#   /_t/x/api/<project>/{envelope,store,minidump}/ -> GlitchTip (stacks/glitchtip).
#     Only the ingest endpoints: the same port also serves GlitchTip's
#     dashboard API, /admin/ and /metrics, which stay off this route.

locals {
  ingest_priority = 10000
  ingest_shared_middlewares = [
    # crowdsec and compress are entrypoint middlewares, already on every router.
    { name = "real-ip", namespace = "traefik" },
    { name = "ingest-rate-limit", namespace = kubernetes_namespace.rybbit.metadata[0].name },
  ]
}

resource "kubernetes_manifest" "ingest_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingest-rate-limit"
      namespace = kubernetes_namespace.rybbit.metadata[0].name
    }
    spec = {
      # Per client IP. A page sends a pageview, a few events and replay chunks
      # every few seconds; 20/s with a burst of 200 leaves room for a busy tab.
      rateLimit = {
        average = 20
        burst   = 200
        period  = "1s"
        sourceCriterion = {
          ipStrategy = { depth = 0 }
        }
      }
    }
  }
}

resource "kubernetes_manifest" "ingest_strip_rybbit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingest-strip-rybbit"
      namespace = kubernetes_namespace.rybbit.metadata[0].name
    }
    spec = {
      replacePathRegex = {
        regex       = "^/_t/r/(.*)"
        replacement = "/api/$1"
      }
    }
  }
}

resource "kubernetes_manifest" "ingest_strip_events" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingest-strip-events"
      namespace = kubernetes_namespace.rybbit.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/_t/e"]
      }
    }
  }
}

resource "kubernetes_manifest" "ingest_strip_errors" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingest-strip-errors"
      namespace = kubernetes_namespace.rybbit.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/_t/x"]
      }
    }
  }
}

resource "kubernetes_manifest" "ingest_route" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "ingest-path"
      namespace = kubernetes_namespace.rybbit.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match    = "PathPrefix(`/_t/r/`)"
          kind     = "Rule"
          priority = local.ingest_priority
          middlewares = concat(local.ingest_shared_middlewares, [
            { name = "ingest-strip-rybbit", namespace = kubernetes_namespace.rybbit.metadata[0].name },
          ])
          services = [{
            name = kubernetes_service.rybbit.metadata[0].name
            port = 80
          }]
        },
        {
          match    = "PathPrefix(`/_t/e/`)"
          kind     = "Rule"
          priority = local.ingest_priority
          middlewares = concat(local.ingest_shared_middlewares, [
            { name = "ingest-strip-events", namespace = kubernetes_namespace.rybbit.metadata[0].name },
          ])
          services = [{
            name = kubernetes_service.event_pipeline.metadata[0].name
            port = 80
          }]
        },
        {
          match    = "PathRegexp(`^/_t/x/api/[0-9]+/(envelope|store|minidump)/`)"
          kind     = "Rule"
          priority = local.ingest_priority
          middlewares = concat(local.ingest_shared_middlewares, [
            { name = "ingest-strip-errors", namespace = kubernetes_namespace.rybbit.metadata[0].name },
          ])
          services = [{
            name      = "glitchtip"
            namespace = "glitchtip"
            port      = 80
          }]
        },
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
  depends_on = [
    kubernetes_manifest.ingest_rate_limit,
    kubernetes_manifest.ingest_strip_rybbit,
    kubernetes_manifest.ingest_strip_events,
    kubernetes_manifest.ingest_strip_errors,
  ]
}
