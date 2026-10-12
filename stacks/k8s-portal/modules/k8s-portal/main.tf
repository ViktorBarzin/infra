variable "tls_secret_name" {}
variable "tier" { type = string }
variable "k8s_ca_cert" {
  type    = string
  default = ""
}

resource "kubernetes_namespace" "k8s_portal" {
  metadata {
    name = "k8s-portal"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "k8s_portal_config" {
  metadata {
    name      = "k8s-portal-config"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  data = {
    "ca.crt" = var.k8s_ca_cert
  }
}

resource "kubernetes_deployment" "k8s_portal" {
  metadata {
    name      = "k8s-portal"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
    # ADR-0002 / no-local-builds: image GHA-built -> ghcr
    # (.github/workflows/build-k8s-portal.yml), whose last step runs
    # .woodpecker/first-party-deploy.yml to set the :<sha> tag here.
    labels = {
      app  = "k8s-portal"
      tier = var.tier
    }
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    revision_history_limit = 3
    selector {
      match_labels = {
        app = "k8s-portal"
      }
    }

    template {
      metadata {
        labels = {
          app = "k8s-portal"
        }
      }

      spec {
        # GHCR pull secret: the ghcr-credentials Secret in this namespace is
        # cloned in by the kyverno stack's sync-ghcr-credentials ClusterPolicy
        # (allowlisted private-ghcr namespaces only — ADR-0002). Source of
        # truth: stacks/kyverno/modules/kyverno/ghcr-credentials.tf.
        image_pull_secrets {
          name = "ghcr-credentials"
        }
        container {
          name = "portal"
          # Set by CI (CI_SETS_IMAGE below); this value, the build running on
          # 2026-10-12, is used only on a recreate.
          image = "ghcr.io/viktorbarzin/k8s-portal:d6bd9486e3a53a5cce92d2b9a9dd68bdb0c38e25"
          port {
            container_port = 3000
          }

          volume_mount {
            name       = "config"
            mount_path = "/config/ca.crt"
            sub_path   = "ca.crt"
            read_only  = true
          }
          volume_mount {
            name       = "user-roles"
            mount_path = "/config/users.json"
            sub_path   = "users.json"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.k8s_portal_config.metadata[0].name
          }
        }
        volume {
          name = "user-roles"
          config_map {
            name = "k8s-user-roles"
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
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # CI_SETS_IMAGE: first-party image, deployed by its own CI
    ]
  }
}

resource "kubernetes_service" "k8s_portal" {
  metadata {
    name      = "k8s-portal"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  spec {
    selector = {
      app = "k8s-portal"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # ADR-0026 / code-6m20: auth-grey host, no recorded reason for the direct
  # path. Small admin UI behind Authentik forward-auth. Proxied rides the
  # zone-wide wildcard CNAME (ADR-0021) and creates no A/AAAA record.
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  name            = "k8s-portal"
  tls_secret_name = var.tls_secret_name
  auth            = "required" # Require Authentik login
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "K8s Portal"
    "gethomepage.dev/description"  = "Kubernetes portal"
    "gethomepage.dev/icon"         = "kubernetes.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Unprotected ingress for the setup script and agent endpoint (needs to be
# curl-able without auth). `auth = "public"` would 302+cookie-dance on
# first visit, breaking automation that doesn't preserve cookies.
module "ingress_setup_script" {
  source    = "../../../../modules/kubernetes/ingress_factory"
  namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  name      = "k8s-portal-setup"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  host             = "k8s-portal"
  service_name     = "k8s-portal"
  ingress_path     = ["/setup/script", "/agent"]
  tls_secret_name  = var.tls_secret_name
  # auth = "none": Setup script + agent endpoint must be curl-able without auth (no cookies preserved in automation).
  auth = "none"
}
