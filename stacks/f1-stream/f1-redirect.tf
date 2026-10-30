# f1.viktorbarzin.me redirects to tv.viktorbarzin.me (f1-stream ADR-0053).
#
# tv is the app's only host since 2026-10-29. f1 serves nothing itself: its
# root goes to the F1 section (tv/f1/) and every other path goes to the same
# path and query on tv. The status is 308, so a client that follows it keeps
# its method and body. Old TV builds update through this: their update check
# and APK download are GETs (ops/UpdateTransport.kt in the app repo), OkHttp
# follows those, and their POSTs (heartbeat, telemetry) fail until the TV
# installs the new build at its next open. VLC watch links on f1 follow it too.
#
# Two places answer, because f1 resolves two ways:
#
#   Public DNS. f1 has no record of its own; the zone's proxied `*` CNAME into
#   the tunnel covers it, so every public request reaches Cloudflare, and the
#   Single Redirect rules below answer at the edge before any cache rule,
#   Worker or origin is involved.
#
#   Internal DNS. Technitium is authoritative for viktorbarzin.me inside the
#   cluster and on the 10.0.20.0/24 VLAN, and it holds f1 as a CNAME to the
#   apex (Traefik), created by technitium-ingress-dns-sync while f1 had an
#   ingress. That sync never deletes, so the record stays. Those clients reach
#   Traefik directly and never see the Cloudflare rules, so the IngressRoute at
#   the bottom of this file gives them the same redirect. Without it they would
#   get Traefik's 404. The London and Sofia home LANs resolve through public
#   DNS (checked 2026-10-30 against 192.168.8.1 and 192.168.1.1), so the TVs
#   there take the Cloudflare path.
#
# BEFORE CHANGING THE RULESET: like the cache ruleset in cloudflare-cache.tf,
# this resource owns the zone's whole http_request_dynamic_redirect phase. On
# 2026-10-30 GET /zones/<zone>/rulesets listed no ruleset in that phase, so
# this created it rather than replacing anything. Any other redirect on the
# zone belongs in this list, or it will be deleted on the next apply. The Free
# plan allows 10 Single Redirect rules and no regex; concat() is not regex.

resource "cloudflare_ruleset" "f1_redirect" {
  zone_id     = "fd2c5dd4efe8fe38958944e74d0ced6d"
  name        = "f1 to tv redirect"
  description = "f1.viktorbarzin.me redirects to tv.viktorbarzin.me. See stacks/f1-stream/f1-redirect.tf."
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  # A redirect ends the phase, so the root rule has to come first.
  rules = [
    {
      ref         = "f1_root_to_tv_f1"
      description = "f1/ goes to the F1 section on tv, query kept (party rooms)"
      expression  = "(http.host eq \"f1.viktorbarzin.me\" and http.request.uri.path eq \"/\")"
      action      = "redirect"
      enabled     = true

      action_parameters = {
        from_value = {
          status_code           = 308
          preserve_query_string = true
          target_url = {
            value = "https://tv.viktorbarzin.me/f1/"
          }
        }
      }
    },
    {
      ref         = "f1_path_to_tv"
      description = "Every other f1 path goes to the same path and query on tv"
      expression  = "(http.host eq \"f1.viktorbarzin.me\")"
      action      = "redirect"
      enabled     = true

      action_parameters = {
        from_value = {
          status_code           = 308
          preserve_query_string = true
          target_url = {
            expression = "concat(\"https://tv.viktorbarzin.me\", http.request.uri.path)"
          }
        }
      }
    },
  ]
}

# The internal-DNS half (see the top of this file). Traefik's redirectRegex
# matches the whole request URL, query included. `permanent = true` answers 301
# to a GET and 308 to anything else.
resource "kubernetes_manifest" "f1_redirect_root" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "f1-redirect-root"
      namespace = kubernetes_namespace.f1-stream.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = "^https?://[^/]+/(\\?.*)?$"
        replacement = "https://tv.viktorbarzin.me/f1/$${1}"
        permanent   = true
      }
    }
  }
}

resource "kubernetes_manifest" "f1_redirect_path" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "f1-redirect-path"
      namespace = kubernetes_namespace.f1-stream.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = "^https?://[^/]+(.*)$"
        replacement = "https://tv.viktorbarzin.me$${1}"
        permanent   = true
      }
    }
  }
}

resource "kubernetes_manifest" "f1_redirect_route" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "f1-redirect"
      namespace = kubernetes_namespace.f1-stream.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      # Traefik ranks routes by rule length, so the root route wins for "/".
      routes = [
        {
          match = "Host(`f1.viktorbarzin.me`) && Path(`/`)"
          kind  = "Rule"
          middlewares = [{
            name      = "f1-redirect-root"
            namespace = kubernetes_namespace.f1-stream.metadata[0].name
          }]
          services = [{
            kind = "TraefikService"
            name = "noop@internal"
          }]
        },
        {
          match = "Host(`f1.viktorbarzin.me`)"
          kind  = "Rule"
          middlewares = [{
            name      = "f1-redirect-path"
            namespace = kubernetes_namespace.f1-stream.metadata[0].name
          }]
          services = [{
            kind = "TraefikService"
            name = "noop@internal"
          }]
        },
      ]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
  depends_on = [kubernetes_manifest.f1_redirect_root, kubernetes_manifest.f1_redirect_path]
}
