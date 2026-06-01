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

# === Per-user dispatch + auto-provisioning ===================================
# t3 is single-owner (no in-app multi-user), so each person runs their OWN
# `t3 serve` instance on the DevVM as their own OS user (file perms enforced by
# the uid). A DevVM service `t3-dispatch` (10.0.10.10:3780) routes the single
# hostname t3.viktorbarzin.me by Authentik identity and auto-mints+injects the
# user's t3 session on first visit. Source of truth: /etc/ttyd-user-map. All the
# DevVM-side pieces (t3-serve@ template, reconcile, dispatch, t3-mint, sudoers)
# live in infra/scripts/ and are deployed there (outside TF, like t3-serve and
# terminal-lobby). This stack only owns the K8s edge:
#   Traefik (Authentik forward-auth, auth="required") -> Service/Endpoints
#   -> 10.0.10.10:3780 (t3-dispatch).
# See docs/plans/2026-06-01-t3-auto-provision-{design,plan}.md.
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
      target_port = 3780
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
      port = 3780
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.t3code.metadata[0].name
  name            = "t3"
  service_name    = kubernetes_service.t3code.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # Authentik forward-auth gates t3.viktorbarzin.me and injects
  # X-authentik-username, which the DevVM t3-dispatch service maps to each user's
  # own `t3 serve` instance (per-user isolation mirroring the terminal stack).
  # The same-origin self-served UI works behind forward-auth (WS carries the
  # Authentik cookie); t3's own pairing/bearer is the inner gate, auto-injected
  # on first visit. Cross-origin clients (native app / app.t3.codes) are
  # intentionally NOT supported here — deferred until the native app is published.
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "T3 Code"
    "gethomepage.dev/description"  = "Coding-agent GUI (per-user, t3 serve on DevVM)"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
