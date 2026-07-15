variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# App lives in its own repo (viktor/vpn-portal, spec infra#76). The first image
# was built + pushed manually to bootstrap the deploy; ongoing builds move to
# the GHA→ghcr fleet pattern (offinfra-onboard). imagePullPolicy=Always + the
# KEEL_IGNORE_IMAGE lifecycle below keep the running tag outside Terraform.
variable "image_tag" {
  type    = string
  default = "latest"
}

resource "kubernetes_namespace" "vpn_portal" {
  metadata {
    name = "vpn-portal"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Dedicated SA — the Vault kubernetes-auth role `vpn-portal` binds
# system:serviceaccount:vpn-portal:vpn-portal (read+write secret/data/vpn-portal).
resource "kubernetes_service_account" "vpn_portal" {
  metadata {
    name      = "vpn-portal"
    namespace = kubernetes_namespace.vpn_portal.metadata[0].name
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.vpn_portal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "vpn_portal" {
  metadata {
    name      = "vpn-portal"
    namespace = kubernetes_namespace.vpn_portal.metadata[0].name
    labels = {
      app  = "vpn-portal"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "vpn-portal"
      }
    }
    template {
      metadata {
        labels = {
          app = "vpn-portal"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.vpn_portal.metadata[0].name
        container {
          name              = "vpn-portal"
          image             = "ghcr.io/viktorbarzin/vpn-portal:${var.image_tag}"
          image_pull_policy = "Always"
          port {
            container_port = 3000
          }
          # Vault kubernetes-auth: the app logs in with its SA token at runtime
          # and reads/writes secret/vpn-portal (server config + wg peer list).
          env {
            name  = "VAULT_ADDR"
            value = "http://vault-active.vault.svc.cluster.local:8200"
          }
          env {
            name  = "VAULT_K8S_ROLE"
            value = "vpn-portal"
          }
          env {
            name  = "VAULT_KV_MOUNT"
            value = "secret"
          }
          env {
            name  = "VAULT_PORTAL_PATH"
            value = "vpn-portal"
          }
          env {
            name  = "PORT"
            value = "3000"
          }
          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }
        }
        image_pull_secrets {
          name = "ghcr-credentials" # Kyverno-synced (ghcr-credentials.tf allowlist)
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel/CI manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "vpn_portal" {
  metadata {
    name      = "vpn-portal"
    namespace = kubernetes_namespace.vpn_portal.metadata[0].name
    labels = {
      app = "vpn-portal"
    }
  }
  spec {
    selector = {
      app = "vpn-portal"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}

# UI + /api/* — Authentik forward-auth gates the human surface. The
# vpn.viktorbarzin.me A record already exists (config.tfvars
# cloudflare_non_proxied_names), so dns_type="none" avoids a duplicate record;
# the explicit non-proxied A shadows the wildcard and NATs :443 → Traefik, which
# routes by Host to this ingress.
module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  auth             = "required"
  dns_type         = "none"
  external_monitor = false
  namespace        = kubernetes_namespace.vpn_portal.metadata[0].name
  name             = "vpn-portal"
  full_host        = "vpn.viktorbarzin.me"
  service_name     = kubernetes_service.vpn_portal.metadata[0].name
  port             = 80
  tls_secret_name  = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/icon"  = "wireguard.png"
    "gethomepage.dev/name"  = "VPN Portal"
    "gethomepage.dev/group" = "Identity & Security"
  }
}

# /sub/<token> — machine subscription endpoint. VPN clients (Hiddify/v2rayN)
# poll it with a per-user token and cannot complete an Authentik OIDC login, so
# it is unauthenticated at the edge and validates the token in-app.
module "ingress_sub" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": token-authed subscription API for VPN client apps (no OIDC possible); token checked in-app.
  auth             = "none"
  dns_type         = "none"
  external_monitor = false
  anti_ai_scraping = false
  namespace        = kubernetes_namespace.vpn_portal.metadata[0].name
  name             = "vpn-portal-sub"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  full_host        = "vpn.viktorbarzin.me"
  ingress_path     = ["/sub"]
  service_name     = kubernetes_service.vpn_portal.metadata[0].name
  port             = 80
  tls_secret_name  = var.tls_secret_name
  # Strip any client-supplied X-authentik-* on this unauthenticated path so a
  # spoofed identity header can never reach the app (memory #6831 class).
  extra_middlewares = ["traefik-strip-auth-headers@kubernetescrd"]
}
