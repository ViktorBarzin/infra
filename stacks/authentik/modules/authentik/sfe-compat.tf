# Old-browser login compatibility, at the ingress instead of in the image.
#
# authentik's flow UI is an ES2022 bundle that old WebKit cannot parse, so an
# affected device renders a COMPLETELY BLANK login page. authentik ships a
# no-JS ES5 Simplified Flow Executor and serves it when the request carries
# ?sfe. That check is upstream and unpatched, at flows/views/interface.py:
#   if self.compat_needs_sfe() or "sfe" in request.GET
# so rewriting the URL here reaches the same code path the old overlay image
# reached by widening compat_needs_sfe() itself.
#
# WHO NEEDS IT: emil.barzin@gmail.com's iPadOS 15.8 tablet. Measured from
# authentik's own login events, 4 of his last 5 logins from that device went
# through the Google source, and every iOS browser shares the system WebKit so
# switching browser does not help. Verified against the version/2026.8.3
# source on 2026-09-18: compat_needs_sfe there still has only IE, Edge<=18 and
# PKeyAuth, so this is still needed at 2026.8.3.
#
# WHY REWRITE RATHER THAN REDIRECT TO A SOURCE LOGIN: the flow page must
# actually load, because the flow executor is what writes
# session["authentik/flows/get"]["next"], the target forward-auth put in the
# URL. Measured both ways in the cluster browser on 2026-09-12: through this
# hop a cold request for grafana.viktorbarzin.me ended on the Grafana
# dashboard; jumping straight to /source/oauth/login/google/ ended on the
# authentik dashboard with the target lost.
#
# RETIREMENT: goauthentik/authentik#25247 does this upstream in
# compat_needs_sfe() itself. Merged to main under the 2026.11.0 milestone with
# no backport label. Delete this file once the running version carries it; the
# check is that an iOS 15 user agent gets dist/sfe/index.js with no ?sfe in
# the URL.

locals {
  # Browsers whose WebKit cannot parse the ES2022 flow bundle:
  #   (a) any browser on iOS <= 16.3, since Chrome/CriOS, Firefox/FxiOS and
  #       Edge all share the system WebKit, so the family is irrelevant;
  #   (b) Safari <= 16.3, which also covers iPadOS in desktop mode, because
  #       that reports itself as Safari on macOS rather than as an iPad.
  # Matching too broadly is a real regression, not a harmless one: it would put
  # modern browsers on an executor with no passkey support. Checked against 20
  # real user-agent strings with Go's RE2, the engine Traefik uses, including
  # the iOS 16.3/16.4 boundary and every device in our own login events.
  sfe_compat_ua = trimspace(<<-EOT
    \(iP(hone|ad|od)[^)]*OS ((\d|1[0-5])_|16_[0-3])|Version/((\d|1[0-5])\.|16\.[0-3])[0-9.]* Safari
  EOT
  )

  authentik_host = "authentik.viktorbarzin.me"
}

# Append sfe=1 to the flow URL, preserving every existing query parameter.
# [^?]* stops at the query string, so group 2 is whatever followed the "?"
# (empty when there was none, leaving a harmless trailing "&").
resource "kubernetes_manifest" "sfe_compat_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "authentik-sfe-compat"
      namespace = kubernetes_namespace.authentik.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = "^(https://${replace(local.authentik_host, ".", "\\.")}/if/flow/[^?]*)\\??(.*)$"
        replacement = "$${1}?sfe=1&$${2}"
        # Temporary on purpose. A 301 would be cached for the life of the
        # browser profile, so a device that later updates past iOS 16.3 would
        # keep being sent to the SFE with no way to clear it from here.
        permanent = false
      }
    }
  }
}

# Only old WebKit, only the flow pages, and only when sfe=1 is not already
# present, because without that last clause the redirect matches its own
# target and loops.
#
# depends_on IS LOAD-BEARING, and its absence is why this failed on 2026-09-12.
# Terraform created the IngressRoute before the Middleware, Traefik rejected
# the router at config load with
#   middleware "authentik-authentik-sfe-compat@kubernetescrd" does not exist
# on all three replicas, and the rule never entered the routing table. A single
# curl returning 302 looked like proof it worked; the router census said zero
# hits. Verify in Traefik's /api/http/routers, not with one request.
resource "kubernetes_manifest" "sfe_compat_route" {
  depends_on = [kubernetes_manifest.sfe_compat_middleware]

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "authentik-sfe-compat"
      namespace = kubernetes_namespace.authentik.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        kind     = "Rule"
        priority = 100000
        match    = "Host(`${local.authentik_host}`) && PathPrefix(`/if/flow/`) && HeaderRegexp(`User-Agent`, `${local.sfe_compat_ua}`) && !Query(`sfe`, `1`)"
        middlewares = [{
          name      = "authentik-sfe-compat"
          namespace = kubernetes_namespace.authentik.metadata[0].name
        }]
        services = [{
          kind = "TraefikService"
          name = "noop@internal"
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}
