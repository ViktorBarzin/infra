variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# webmux (github.com/jordanhubbard/webmux) — a browser grid of live SSH/mosh
# sessions, being trialled alongside terminal-lobby. It runs as a systemd
# --user unit on the devvm (10.0.10.10:7692), not in-cluster: upstream ships
# no container image, and the point of the tool is to open sessions from a
# host that already has the SSH keys and reachability. So this stack is only
# the front door — a selectorless Service + Endpoints pointing at the devvm,
# exactly like the ttyd routes in stacks/terminal.
resource "kubernetes_namespace" "webmux" {
  metadata {
    name = "webmux"
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
  namespace       = kubernetes_namespace.webmux.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to webmux at 10.0.10.10:7692
resource "kubernetes_service" "webmux" {
  metadata {
    name      = "webmux"
    namespace = kubernetes_namespace.webmux.metadata[0].name
    labels = {
      app = "webmux"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7692
    }
  }
}

resource "kubernetes_endpoints" "webmux" {
  metadata {
    name      = "webmux"
    namespace = kubernetes_namespace.webmux.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7692
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.webmux.metadata[0].name
  name            = "webmux"
  tls_secret_name = var.tls_secret_name
  # Two gates, deliberately. Authentik forward-auth is the outer one; webmux
  # ALSO keeps its own login (auth.mode: local, Argon2id + JWT) because the
  # backend port is reachable from the LAN — the devvm runs no host firewall,
  # so a request that never passes through Traefik must still hit a login.
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "WebMux"
    "gethomepage.dev/description"  = "SSH session grid (trial)"
    "gethomepage.dev/icon"         = "mdi-view-grid-outline"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
