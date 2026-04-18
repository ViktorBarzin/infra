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
  protected       = true
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
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal (Read-Only)"
    "gethomepage.dev/description"  = "Read-only web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
