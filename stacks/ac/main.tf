# agent-conductor web port — k8s edge for ac.viktorbarzin.me.
#
# Mirrors stacks/terminal (the terminal-lobby analog): this stack owns ONLY the
# Kubernetes/Traefik side — Services + Endpoints pointing at the DevVM
# (10.0.10.10), the IngressRoutes, and the middlewares. The application (the
# de-BUCK'd acd daemon, the per-user ac-relay systemd units, the acd-demux
# gateway, and the SPA static server) runs on the DevVM and is installed by the
# agent-conductor repo's scripts/deploy.sh (manual, no CI image — like terminal).
#
# DevVM service map:
#   acd-demux    :7690  → browser WS → per-user relay (systemd socket-activated)
#                         → that user's acd 0600 UDS. The ONLY browser-facing
#                         port. Requires X-Gateway-Auth (injected below) +
#                         X-Authentik-Username (forward-auth).
#   ac-static    :7691  → serves the M1 web SPA (dist-web), SPA-fallback.
#
# Security posture (M2, docs/m2/gateway-design.md in the app repo):
#   - Admin-gated: ac.viktorbarzin.me is added to ADMIN_ONLY_HOSTS in
#     stacks/authentik/admin-services-restriction.tf, so only "Home Server
#     Admins" reach it until the multi-user red-team passes on the live path.
#   - X-Gateway-Auth shared secret (Vault secret/ac-gateway#gateway_secret) is
#     injected by Traefik here and required by acd-demux — a second, independent
#     control on demuxer reachability so a bind/firewall slip alone is not
#     shell-as-victim. The DevVM acd-demux reads the SAME value from
#     /etc/acd-gateway/gateway-secret (provisioned from the same Vault key).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Single source of truth for the gateway shared secret. Provisioned out of band
# (one-time): `vault kv put secret/ac-gateway gateway_secret=$(openssl rand -hex 32)`.
# Read here for the Traefik inject middleware; read on the DevVM for acd-demux.
data "vault_kv_secret_v2" "ac_gateway" {
  mount = "secret"
  name  = "ac-gateway"
}

resource "kubernetes_namespace" "ac" {
  metadata {
    name = "ac"
    labels = {
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks stamps this label on every namespace.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Wildcard TLS cert for the ac namespace. Rather than ship a per-stack
# git-crypt'd secrets/{fullchain,privkey}.pem, copy the existing wildcard cert
# out of the traefik namespace (the same cert Traefik's default TLSStore
# serves). Single source of truth, no cert material committed to this stack;
# re-copied on each apply (renew-tls maintains the traefik-namespace original).
data "kubernetes_secret" "wildcard" {
  metadata {
    name      = var.tls_secret_name
    namespace = "traefik"
  }
}

resource "kubernetes_secret" "tls" {
  metadata {
    name      = var.tls_secret_name
    namespace = kubernetes_namespace.ac.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = data.kubernetes_secret.wildcard.data["tls.crt"]
    "tls.key" = data.kubernetes_secret.wildcard.data["tls.key"]
  }
}

# --- acd-demux (browser WS → per-user relay → acd) : DevVM 10.0.10.10:7690 ---
resource "kubernetes_service" "ac_demux" {
  metadata {
    name      = "ac-demux"
    namespace = kubernetes_namespace.ac.metadata[0].name
    labels    = { app = "ac-demux" }
  }
  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7690
    }
  }
}

resource "kubernetes_endpoints" "ac_demux" {
  metadata {
    name      = "ac-demux"
    namespace = kubernetes_namespace.ac.metadata[0].name
  }
  subset {
    address { ip = "10.0.10.10" }
    port {
      name = "http"
      port = 7690
    }
  }
}

# --- SPA static server (serves dist-web) : DevVM 10.0.10.10:7691 ---
resource "kubernetes_service" "ac_static" {
  metadata {
    name      = "ac-static"
    namespace = kubernetes_namespace.ac.metadata[0].name
    labels    = { app = "ac-static" }
  }
  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7691
    }
  }
}

resource "kubernetes_endpoints" "ac_static" {
  metadata {
    name      = "ac-static"
    namespace = kubernetes_namespace.ac.metadata[0].name
  }
  subset {
    address { ip = "10.0.10.10" }
    port {
      name = "http"
      port = 7691
    }
  }
}

# --- X-Gateway-Auth inject middleware ---
# customRequestHeaders SETS the header, overwriting any client-supplied copy
# (strip + inject in one). Attached ONLY to the /ws route (→ acd-demux); the
# SPA static route does not need it. Pairs with acd-demux's constant-time check.
resource "kubernetes_manifest" "ac_gateway_secret_header" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ac-gateway-secret"
      namespace = kubernetes_namespace.ac.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Gateway-Auth" = data.vault_kv_secret_v2.ac_gateway.data["gateway_secret"]
        }
      }
    }
  }
}

# --- Main host: SPA static server, admin-gated (auth=required + the Authentik
# admin-services-restriction policy scoping ac.viktorbarzin.me to Home Server
# Admins). Catch-all "/" — the /ws IngressRoute below wins on path specificity. ---
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ac.metadata[0].name
  name            = "ac"
  service_name    = kubernetes_service.ac_static.metadata[0].name
  port            = 80
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Agent Conductor"
    "gethomepage.dev/description"  = "Multi-agent web console (agent-conductor port)"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# --- /ws on ac.viktorbarzin.me → acd-demux, behind forward-auth (injects
# X-Authentik-Username) + the X-Gateway-Auth inject. Path specificity beats the
# module.ingress "/" catch-all, so the SPA loads from ac-static while the
# WebSocket reaches the gateway. ---
resource "kubernetes_manifest" "ac_ws_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "ac-ws"
      namespace = kubernetes_namespace.ac.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`ac.viktorbarzin.me`) && PathPrefix(`/ws`)"
        kind  = "Rule"
        middlewares = [
          { name = "authentik-forward-auth", namespace = "traefik" },
          { name = "ac-gateway-secret", namespace = kubernetes_namespace.ac.metadata[0].name },
        ]
        services = [{
          name = "ac-demux"
          port = 80
        }]
      }]
      tls = { secretName = var.tls_secret_name }
    }
  }
}
