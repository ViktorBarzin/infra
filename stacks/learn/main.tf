# === learn Viewer — learn.viktorbarzin.me ===
#
# Authentik-gated, per-user web surface for the /teach skill's learning
# workspaces (monorepo learn/ — lessons are interactive HTML with quizzes,
# so they need a real browser, not a PNG render). Serves each user's
# ~/code/learn on the DevVM LIVE from disk: a lesson is viewable the moment
# the file is written — no publish step, no copies to drift. Decision +
# rejected alternatives (Nextcloud links, PNG rasterize, publish-based
# hosting): monorepo learn/docs/adr/0001-viewer-serves-workspaces-live-from-devvm.md
#
# This stack owns only the Kubernetes side (same split as stacks/terminal):
# Service + Endpoints → 10.0.10.10:7685 and the Authentik-gated IngressRoute.
# The DevVM side is Caddy (system service) with a :7685 site block. Authentik
# usernames are FULL EMAILS (e.g. vbarzin@gmail.com), so like tmux-attach.sh
# (`${auth_user%%@*}`) and t3-dispatch the block strips the @domain and maps
# the local part to the OS user (vbarzin→wizard, emil.barzin→emo,
# ancaelena98→ancamilea — keep in sync with /etc/ttyd-user-map, generated
# from roster.yaml), then serves /home/<os_user>/code/learn (file_server
# browse). Canonical Caddyfile: scripts/devvm-caddyfile — deploy with
#   sudo install -m 644 scripts/devvm-caddyfile /etc/caddy/Caddyfile
#   sudo systemctl reload caddy
# Per-user access needs: caddy in group code-shared (wizard's 770 ~/code);
# other users opt in with `chmod o+x ~` (their ~/code is world-readable).
# Header-trust model matches ttyd :7681 / t3-dispatch: backends trust
# X-Authentik-Username from the cluster proxy; the Caddy regex confines the
# local part to a plain username (no '/', no leading dot) so the docroot
# can't be steered, and unmapped users fall to a nonexistent root (404).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "learn" {
  metadata {
    name = "learn"
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
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to the DevVM Caddy learn block
resource "kubernetes_service" "learn" {
  metadata {
    name      = "learn"
    namespace = kubernetes_namespace.learn.metadata[0].name
    labels = {
      app = "learn"
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

resource "kubernetes_endpoints" "learn" {
  metadata {
    name      = "learn"
    namespace = kubernetes_namespace.learn.metadata[0].name
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

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Learn"
    "gethomepage.dev/description"  = "Learning-workspace Viewer (lessons, live from DevVM)"
    "gethomepage.dev/icon"         = "mdi-school"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}
