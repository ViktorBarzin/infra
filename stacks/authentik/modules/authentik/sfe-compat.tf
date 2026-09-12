# Old-browser login compatibility, done at the ingress instead of in the image.
#
# authentik's flow UI is an ES2022 bundle that old WebKit cannot parse, so an
# affected device renders a COMPLETELY BLANK login page. authentik already ships
# a no-JS ES5 Simplified Flow Executor (SFE) and serves it when the request
# carries ?sfe — that check is upstream, unpatched, at
# flows/views/interface.py: `if self.compat_needs_sfe() or "sfe" in request.GET`.
#
# We used to widen compat_needs_sfe() itself with a patched image
# (stacks/authentik/Dockerfile + patch-compat-sfe.py). Rewriting the URL here
# reaches the same code path and lets us run the STOCK goauthentik image, which
# is what makes the version a single chart-version bump.
#
# WHY THE REWRITE AND NOT A REDIRECT STRAIGHT TO A SOURCE LOGIN: the flow page
# must actually load, because the flow executor is what writes
# session["authentik/flows/get"]["next"] — the "where was the user heading"
# target that forward-auth put in the URL. Skipping the flow page loses it and
# dumps the user on the authentik dashboard instead of the app they asked for.
# Measured both ways in the cluster browser on 2026-09-12: with this hop, a
# cold request for grafana.viktorbarzin.me ended on the Grafana dashboard;
# jumping straight to /source/oauth/login/google/ ended on authentik.
#
# RETIREMENT: goauthentik/authentik#25247 does this upstream, in
# compat_needs_sfe() itself, with a version_below() helper and
# MIN_WEBKIT_VERSION. It is merged to main under the 2026.11.0 milestone with
# no backport label, so it arrives in 2026.11 and NOT in any 2026.8.x. Delete
# this whole file once the running version carries it — the acceptance check is
# that an iOS 15 user agent gets dist/sfe/index.js with no ?sfe in the URL.

locals {
  # Browsers whose WebKit cannot parse the ES2022 flow bundle:
  #   (a) any browser on iOS <= 16.3 — Chrome/CriOS, Firefox/FxiOS and Edge all
  #       share the system WebKit, so the browser family is irrelevant;
  #   (b) Safari <= 16.3, which also covers iPadOS in desktop mode, since that
  #       reports itself as Safari on macOS rather than as an iPad.
  # Matching too broadly is not harmless: it would push modern browsers onto the
  # SFE, which has no passkey support. Checked against 20 real user-agent
  # strings with Go's RE2 (the engine Traefik uses) before landing, including
  # the iOS 16.3/16.4 boundary and every device seen in our own login events.
  sfe_compat_ua = trimspace(<<-EOT
    \(iP(hone|ad|od)[^)]*OS ((\d|1[0-5])_|16_[0-3])|Version/((\d|1[0-5])\.|16\.[0-3])[0-9.]* Safari
  EOT
  )

  authentik_host = "authentik.viktorbarzin.me"
}

# Append sfe=1 to the flow URL, preserving every existing query parameter.
# [^?]* stops at the query string, so group 2 is whatever came after the "?"
# (empty when there was none, which just leaves a harmless trailing "&").
resource "kubernetes_manifest" "sfe_compat_redirect" {
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
        # Temporary on purpose. A 301 would be cached by the browser for the
        # life of the profile, so a device that later updates past iOS 16.3
        # would keep being sent to the SFE with no way to clear it from here.
        permanent = false
      }
    }
  }
}

# Only old WebKit, only the flow pages, and only when sfe=1 is not already
# present — without that last clause the redirect matches its own target and
# loops. Priority is explicit so this wins over the catch-all authentik Ingress
# rather than relying on Traefik's rule-length tie-break.
resource "kubernetes_manifest" "sfe_compat_route" {
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
