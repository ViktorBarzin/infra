# -----------------------------------------------------------------------------
# oauth2-proxy: runs the Authentik OIDC code-flow and injects the user's
# id_token as `Authorization: Bearer` upstream to kong-proxy, so the dashboard
# talks to the apiserver AS THE USER (per-user RBAC applies).
# -----------------------------------------------------------------------------

resource "kubernetes_manifest" "oauth2_proxy_externalsecret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "oauth2-proxy"
      namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "oauth2-proxy", creationPolicy = "Owner" }
      data = [
        { secretKey = "client-id", remoteRef = { key = "k8s-dashboard", property = "oauth2_proxy_client_id" } },
        { secretKey = "client-secret", remoteRef = { key = "k8s-dashboard", property = "oauth2_proxy_client_secret" } },
        { secretKey = "cookie-secret", remoteRef = { key = "k8s-dashboard", property = "oauth2_proxy_cookie_secret" } },
      ]
    }
  }
}

locals {
  oauth2_proxy_upstream = "https://kubernetes-dashboard-kong-proxy.kubernetes-dashboard.svc.cluster.local:443"
}

resource "kubernetes_deployment" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    labels    = { app = "oauth2-proxy" }
  }

  spec {
    replicas = 2
    selector { match_labels = { app = "oauth2-proxy" } }

    template {
      metadata { labels = { app = "oauth2-proxy" } }
      spec {
        container {
          name  = "oauth2-proxy"
          image = "quay.io/oauth2-proxy/oauth2-proxy:v7.7.1"
          args = [
            "--http-address=0.0.0.0:4180",
            "--provider=oidc",
            "--oidc-issuer-url=https://authentik.viktorbarzin.me/application/o/k8s-dashboard/",
            "--redirect-url=https://k8s.viktorbarzin.me/oauth2/callback",
            "--upstream=${local.oauth2_proxy_upstream}",
            "--ssl-upstream-insecure-skip-verify=true",
            "--scope=openid email profile offline_access k8s-dashboard-audience",
            "--oidc-extra-audience=kubernetes",
            "--pass-authorization-header=true",
            "--set-authorization-header=true",
            "--pass-access-token=true",
            "--email-domain=*",
            "--insecure-oidc-allow-unverified-email=true",
            "--cookie-secure=true",
            "--cookie-domain=k8s.viktorbarzin.me",
            "--whitelist-domain=k8s.viktorbarzin.me",
            "--cookie-refresh=30m",
            "--cookie-expire=168h",
            "--code-challenge-method=S256",
            "--reverse-proxy=true",
            "--skip-provider-button=true",
          ]
          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "oauth2-proxy"
                key  = "client-id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "oauth2-proxy"
                key  = "client-secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = "oauth2-proxy"
                key  = "cookie-secret"
              }
            }
          }
          port { container_port = 4180 }
          readiness_probe {
            http_get {
              path = "/ping"
              port = 4180
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
  spec {
    selector = { app = "oauth2-proxy" }
    port {
      port        = 4180
      target_port = 4180
    }
  }
}
