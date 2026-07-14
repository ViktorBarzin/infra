variable "tls_secret_name" {}
variable "secret_key" {}
variable "postgres_password" {}
variable "tier" { type = string }
variable "redis_host" { type = string }
variable "homepage_token" {
  type      = string
  default   = ""
  sensitive = true
}


module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# The embedded outpost auto-creates an ingress expecting this secret name
module "tls_secret_outpost" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  tls_secret_name = "authentik-outpost-tls"
}

resource "kubernetes_namespace" "authentik" {
  metadata {
    name = "authentik"
    labels = {
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
      # Keel intentionally NOT enrolled: server+worker run our custom overlay image
      # (ghcr.io/viktorbarzin/authentik-server — see values.yaml global.image +
      # stacks/authentik/Dockerfile). The tag is pinned explicitly and bumped
      # manually (rebuild the overlay FROM the new authentik version + repoint), so
      # a Keel auto-bump would only risk re-introducing the upstream tag / the
      # 2026-06-10 downgrade-boot-storm class. Re-enroll only if the overlay is dropped.
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_resource_quota" "authentik" {
  metadata {
    name      = "authentik-quota"
    namespace = kubernetes_namespace.authentik.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "96Gi"
      pods              = "50"
    }
  }
}

resource "helm_release" "authentik" {
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  create_namespace = true
  name             = "goauthentik"

  repository = "https://charts.goauthentik.io/"
  chart      = "authentik"
  # version    = "2025.10.3"
  # version    = "2025.12.4"
  version = "2026.2.2"
  atomic  = true
  timeout = 6000

  values = [templatefile("${path.module}/values.yaml", { postgres_password = var.postgres_password, secret_key = var.secret_key })]
}


module "ingress" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # Authentik's own UI cannot be gated by Authentik forward-auth — that
  # creates a chicken-and-egg loop (users can't reach the login page).
  # auth = "none": Authentik UI cannot be gated by Authentik forward-auth (chicken-and-egg loop prevents login).
  auth             = "none"
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  name             = "authentik"
  service_name     = "goauthentik-server"
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
  # Swap the shared 10/50 default limiter for a dedicated 100/1000 carve-out:
  # the login SPA + flow-executor API burst on a cold load otherwise 429s into
  # a blank screen (see traefik middleware "authentik-rate-limit").
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-authentik-rate-limit@kubernetescrd"]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Authentik"
    "gethomepage.dev/description"  = "Identity provider"
    "gethomepage.dev/icon"         = "authentik.png"
    "gethomepage.dev/group"        = "Identity & Security"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "authentik"
    "gethomepage.dev/widget.url"   = "http://goauthentik-server.authentik.svc.cluster.local"
    "gethomepage.dev/widget.key"   = var.homepage_token
  }
}

module "ingress-outpost" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # Authentik forward-auth outpost callback path — protecting this with
  # forward-auth would loop the outpost back onto itself.
  # auth = "none": Authentik outpost callback path for forward-auth flow; protecting with forward-auth creates circular dependency.
  auth      = "none"
  namespace = kubernetes_namespace.authentik.metadata[0].name
  name      = "authentik-outpost"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  host             = "authentik"
  service_name     = "ak-outpost-authentik-embedded-outpost"
  port             = 9000
  ingress_path     = ["/outpost.goauthentik.io"]
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
}

# Immutable caching for the flow-executor static assets. Authentik serves
# /static/dist/* with version-fingerprinted filenames (e.g. poly-2026.2.4.js)
# but no max-age, so browsers re-validate the login JS bundle on every signin
# — and split-horizon internal users (direct to Traefik, no Cloudflare) get no
# edge cache at all. Long-lived immutable caching is safe: every authentik
# upgrade changes the asset URLs.
resource "kubernetes_manifest" "static_cache_headers" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "static-cache-headers"
      namespace = kubernetes_namespace.authentik.metadata[0].name
    }
    spec = {
      headers = {
        customResponseHeaders = {
          "Cache-Control" = "public, max-age=31536000, immutable"
        }
      }
    }
  }
}

module "ingress-static" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # Same-host path carve-out of the public authentik UI ingress above, only
  # adding the cache-headers middleware for the static asset prefix.
  # auth = "none": versioned static assets of the (already public) Authentik login UI.
  auth             = "none"
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  name             = "authentik-static"
  host             = "authentik"
  service_name     = "goauthentik-server"
  ingress_path     = ["/static"]
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
  homepage_enabled = false
  # /static serves ALL the SPA JS/CSS chunks; the default 10/50 limiter 429s the
  # cold-load fan-out → blank screen. Dedicated 100/1000 carve-out (note the two
  # namespaces: cache-headers is in ns authentik, rate-limit is in ns traefik).
  skip_default_rate_limit = true
  extra_middlewares = [
    "authentik-static-cache-headers@kubernetescrd",
    "traefik-authentik-rate-limit@kubernetescrd",
  ]
}
