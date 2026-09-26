variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# agentmd: a web app on the DevVM that shows, checks and edits the markdown
# files coding agents read (github.com/ViktorBarzin/agentmd). Each user runs
# their own instance as their own OS user (agentmd@<user> in
# playbooks/devvm.yml), so each gets a port, a hostname and a proxy secret of
# their own: one Service with two users' endpoints would send one person's
# requests to the other's instance, and a shared secret would let one user's
# instance vouch for the other.
#
# The instance trusts the X-Authentik-Username header only when the request
# also carries X-Agentmd-Proxy-Secret, which the middleware below stamps after
# Authentik has run. Both halves read Vault secret/agentmd ->
# proxy_secret_<user>.
#
# ORDER on a change: apply this stack BEFORE the playbook, so the header is
# already being sent when the instance starts demanding it.

locals {
  devvm_ip = "10.0.10.10"
  # user => hostname (under viktorbarzin.me) and the port agentmd@user listens on.
  # Keep in step with devvm_agentmd_users in playbooks/devvm.yml.
  users = {
    wizard = { host = "agentmd", port = 7390 }
  }
  # agentmd's own policy, repeated here because the default csp-headers
  # middleware would replace it with a frame-ancestors-only one.
  csp = "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
}

data "vault_kv_secret_v2" "agentmd" {
  mount = "secret"
  name  = "agentmd"
}

resource "kubernetes_namespace" "agentmd" {
  metadata {
    name = "agentmd"
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

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.agentmd.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints per user, to agentmd@<user> on the DevVM.
resource "kubernetes_service" "agentmd" {
  for_each = local.users
  metadata {
    name      = "agentmd-${each.key}"
    namespace = kubernetes_namespace.agentmd.metadata[0].name
    labels = {
      app = "agentmd"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = each.value.port
    }
  }
}

resource "kubernetes_endpoints" "agentmd" {
  for_each = local.users
  metadata {
    name      = "agentmd-${each.key}"
    namespace = kubernetes_namespace.agentmd.metadata[0].name
  }

  subset {
    address {
      ip = local.devvm_ip
    }
    port {
      name = "http"
      port = each.value.port
    }
  }
}

# Stamps the user's proxy secret on every request. customRequestHeaders
# replaces any value the client sent, so a caller cannot supply their own.
resource "kubernetes_manifest" "proxy_secret" {
  for_each = local.users
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "proxy-secret-${each.key}"
      namespace = kubernetes_namespace.agentmd.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Agentmd-Proxy-Secret" = data.vault_kv_secret_v2.agentmd.data["proxy_secret_${each.key}"]
        }
      }
    }
  }
}

module "ingress" {
  for_each                       = local.users
  source                         = "../../modules/kubernetes/ingress_factory"
  dns_type                       = "proxied"
  namespace                      = kubernetes_namespace.agentmd.metadata[0].name
  name                           = each.value.host
  service_name                   = kubernetes_service.agentmd[each.key].metadata[0].name
  tls_secret_name                = var.tls_secret_name
  auth                           = "required"
  custom_content_security_policy = local.csp
  # Runs after the factory's own chain, so after Authentik.
  extra_middlewares = [
    "${kubernetes_namespace.agentmd.metadata[0].name}-proxy-secret-${each.key}@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "agentmd"
    "gethomepage.dev/description"  = "Agent instruction files: graph, findings, editor"
    "gethomepage.dev/icon"         = "mdi-file-tree"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
