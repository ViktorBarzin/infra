# -----------------------------------------------------------------------------
# The forward-auth Service.
#
# Every auth="required" ingress in the estate reaches Authentik through this
# name, via the nginx auth-proxy in stacks/traefik. It points at the INLINE
# outpost, which runs inside the goauthentik-server pods, so its selector is the
# server Deployment's own labels.
#
# Adopted into Terraform 2026-09-19 (bead code-osvg). Authentik's outpost
# controller created it and we repointed it by hand during the cutover, which
# left it owned by nobody: the controller no longer writes it ("service" is in
# kubernetes_disabled_components, see ../../authentik_provider.tf) and no .tf
# declared it. Declaring it here is what makes the target durable.
#
# cluster_ip is PINNED. nginx OSS resolves an upstream name once at startup and
# caches the address for the life of the worker, so a Service that comes back
# with a different ClusterIP leaves nginx dialling a dead address until it is
# restarted. The 3s connect timeout then trips and error_page hands every
# forward-auth host to @fallback_auth, which is Emergency Access basic-auth for
# the whole estate. That is the 2026-08-19 outage. Pinning costs nothing and
# removes the failure mode from recreation.
#
# The name is load-bearing beyond nginx: it is the backend of the
# authentik-outpost Ingress (main.tf) that serves /outpost.goauthentik.io, so
# forward-auth and the OAuth callback resolve to the same pods. Renaming it
# means changing both together.
# -----------------------------------------------------------------------------

resource "kubernetes_service_v1" "outpost" {
  metadata {
    name      = "ak-outpost-authentik-embedded-outpost"
    namespace = kubernetes_namespace.authentik.metadata[0].name
    labels = {
      "app.kubernetes.io/instance"   = "authentik-embedded-outpost"
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = "authentik-proxy"
      "goauthentik.io/outpost-name"  = "authentik-embedded-outpost"
      "goauthentik.io/outpost-type"  = "proxy"
      "goauthentik.io/outpost-uuid"  = "0eecac0797c7443c892505f2f4fe3e47"
    }
  }

  spec {
    type       = "ClusterIP"
    cluster_ip = "10.101.169.236"

    # The goauthentik-server Deployment's pod labels. The inline outpost listens
    # on the same 9000/9443 as a standalone outpost did, so nothing downstream
    # had to change when forward-auth moved here.
    selector = {
      "app.kubernetes.io/name"      = "authentik"
      "app.kubernetes.io/component" = "server"
    }

    port {
      name        = "http"
      port        = 9000
      target_port = 9000
      protocol    = "TCP"
    }

    port {
      name        = "https"
      port        = 9443
      target_port = 9443
      protocol    = "TCP"
    }
  }
}
