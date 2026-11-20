# The settings page, https://notify.viktorbarzin.me (files/page.py), served by
# the adapter on port 8081. Forward auth is the gate: the page trusts
# X-authentik-username, which the forward-auth middleware sets and the
# websecure entrypoint strips from clients (docs/agents/ingress.md).
#
# Forward auth cannot say whether a request came through Traefik at all: any
# pod can open the Service and send its own X-authentik-username. So the
# ingress also sets X-Notify-Ingress-Proof to a value only this stack knows,
# and the page refuses requests without it. Same pattern as
# stacks/tv/ingress-proof.tf. customRequestHeaders sets the header, so a
# client's own copy is replaced on the way through.
#
# Rotate: taint random_password.ingress_proof and apply. The adapter reads the
# mounted file on every request, so it follows within the kubelet's refresh.

locals {
  page_host = "notify.viktorbarzin.me"
}

resource "random_password" "ingress_proof" {
  length  = 48
  special = false
}

resource "kubernetes_secret" "ingress_proof" {
  metadata {
    name      = "notify-ingress-proof"
    namespace = kubernetes_namespace.notify.metadata[0].name
  }
  data = {
    proof = random_password.ingress_proof.result
  }
}

resource "kubernetes_manifest" "ingress_proof" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingress-proof"
      namespace = kubernetes_namespace.notify.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Notify-Ingress-Proof" = random_password.ingress_proof.result
        }
      }
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Household members set their own notifications; the host is also listed in
  # stacks/authentik/forward-auth-apps.json.
  auth            = "required"
  allowed_groups  = ["Home Server Admins", "Home Users"]
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.notify.metadata[0].name
  name            = "notify"
  service_name    = kubernetes_service.adapter.metadata[0].name
  port            = 8081
  tls_secret_name = var.tls_secret_name
  # Runs after forward auth, so only signed-in requests carry the proof.
  extra_middlewares = ["notify-ingress-proof@kubernetescrd"]
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Notifications"
    "gethomepage.dev/description" = "Choose which infra alerts reach your phone or email"
    "gethomepage.dev/icon"        = "mdi-bell-ring"
    "gethomepage.dev/group"       = "Productivity"
  }
}
