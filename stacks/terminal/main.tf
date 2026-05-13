variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "terminal" {
  metadata {
    name = "terminal"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to ttyd at 10.0.10.10:7681
resource "kubernetes_service" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7681
    }
  }
}

resource "kubernetes_endpoints" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7681
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal"
    "gethomepage.dev/description"  = "Web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Read-only terminal session at terminal-ro.viktorbarzin.me
resource "kubernetes_service" "terminal_ro" {
  metadata {
    name      = "terminal-ro"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal-ro"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7682
    }
  }
}

resource "kubernetes_endpoints" "terminal_ro" {
  metadata {
    name      = "terminal-ro"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7682
    }
  }
}

# Clipboard image upload service (same-origin path routing)
resource "kubernetes_service" "clipboard_upload" {
  metadata {
    name      = "clipboard-upload"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "clipboard-upload"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7683
    }
  }
}

resource "kubernetes_endpoints" "clipboard_upload" {
  metadata {
    name      = "clipboard-upload"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7683
    }
  }
}

# IngressRoute for /clipboard/* on terminal.viktorbarzin.me → clipboard-upload service
resource "kubernetes_manifest" "clipboard_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "clipboard-upload"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/clipboard/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          },
          {
            name      = "clipboard-strip-prefix"
            namespace = kubernetes_namespace.terminal.metadata[0].name
          }
        ]
        services = [{
          name = "clipboard-upload"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "clipboard_strip_prefix" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "clipboard-strip-prefix"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/clipboard"]
      }
    }
  }
}

module "ingress_ro" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal-ro"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal (Read-Only)"
    "gethomepage.dev/description"  = "Read-only web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# === Multi-session terminal: term.viktorbarzin.me ===
#
# Additive lobby UX on a fresh hostname + ports — does not touch the existing
# terminal.viktorbarzin.me (7681), terminal-ro.viktorbarzin.me (7682) or
# /clipboard/* (7683) wiring above. DevVM-side units (ttyd-multi.service on
# port 7685, tmux-api.service on port 7684) ship from
# files/devvm/ — see files/devvm/README.md.

# Service+Endpoints → ttyd-multi on the DevVM (port 7685).
resource "kubernetes_service" "terminal_multi" {
  metadata {
    name      = "terminal-multi"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal-multi"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7685
    }
  }
}

resource "kubernetes_endpoints" "terminal_multi" {
  metadata {
    name      = "terminal-multi"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7685
    }
  }
}

# Service+Endpoints → tmux-api on the DevVM (port 7684).
resource "kubernetes_service" "tmux_api" {
  metadata {
    name      = "tmux-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "tmux-api"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7684
    }
  }
}

resource "kubernetes_endpoints" "tmux_api" {
  metadata {
    name      = "tmux-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7684
    }
  }
}

# Public ingress for the lobby + per-session attach.
# Hostname: term.viktorbarzin.me (via `host = "term"` override).
module "ingress_multi" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal-multi"
  host            = "term"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal (Multi)"
    "gethomepage.dev/description"  = "Multi-session tmux lobby (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# IngressRoute: /api/sessions/* on term.viktorbarzin.me → tmux-api service.
# Path-prefixed routes beat the catch-all module ingress above by
# specificity, so the lobby HTML reaches tmux-api directly while everything
# else flows to ttyd-multi.
resource "kubernetes_manifest" "tmux_api_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "tmux-api"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`term.viktorbarzin.me`) && PathPrefix(`/api/sessions/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          },
          {
            name      = "tmux-api-strip-prefix"
            namespace = kubernetes_namespace.terminal.metadata[0].name
          }
        ]
        services = [{
          name = "tmux-api"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "tmux_api_strip_prefix" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "tmux-api-strip-prefix"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/api/sessions"]
      }
    }
  }
}
