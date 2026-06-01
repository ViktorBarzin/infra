variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "t3code" {
  metadata {
    name = "t3code"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# TLS secret `tls-secret` (wildcard *.viktorbarzin.me) is auto-cloned into this
# namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local module or
# cert material needed; the renewal pipeline updates the source and Kyverno
# propagates within seconds.

# Service + Endpoints reverse-proxy to t3code (`t3 serve`) on the DevVM at
# 10.0.10.10:3773. The t3 server is a systemd unit (t3-serve.service) bound to
# 0.0.0.0:3773 on the DevVM LAN; this stack only owns the Kubernetes side so
# Traefik can route t3.viktorbarzin.me to it. App code lives on the DevVM, not
# in this monorepo (installed globally via `npm i -g t3`).
resource "kubernetes_service" "t3code" {
  metadata {
    name      = "t3"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels = {
      app = "t3"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 3773
    }
  }
}

resource "kubernetes_endpoints" "t3code" {
  metadata {
    name      = "t3"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 3773
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.t3code.metadata[0].name
  name            = "t3"
  tls_secret_name = var.tls_secret_name
  # auth = "app": t3code (`t3 serve`) ships its own user auth — one-time owner
  # pairing tokens exchanged for 30-day bearer sessions, with the WebSocket
  # guarded by a short-lived wsToken. Authentik forward-auth is deliberately NOT
  # used here: it would block the cross-origin native mobile app and the hosted
  # app.t3.codes client (both bearer-only, no Authentik cookie). CrowdSec (on by
  # default) + anti-AI scraping rate-limit the public surface; t3's pairing is
  # the gate. Trade-off accepted by Viktor 2026-06-01 to keep the native app.
  auth = "app"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "T3 Code"
    "gethomepage.dev/description"  = "Coding-agent GUI (t3 serve on DevVM)"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
