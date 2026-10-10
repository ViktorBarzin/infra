variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "novelapp-secrets"
      namespace = "novelapp"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "novelapp-secrets"
      }
      dataFrom = [{
        extract = {
          key = "novelapp"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.novelapp]
}

resource "kubernetes_namespace" "novelapp" {
  metadata {
    name = "novelapp"
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
  namespace       = kubernetes_namespace.novelapp.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "novelapp-data" {
  metadata {
    name      = "novelapp-data-proxmox"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "novelapp" {
  metadata {
    name      = "novelapp"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
    labels = {
      # Deliberately NOT sablier-enrolled (un-enrolled 2026-07-14, Viktor):
      # shared with Gheorghe — cold starts hurt him; keep always-on
      # at 640Mi (see resources note re the 320Mi OOM loop). Do not re-enroll.
      app  = "novelapp"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      metadata[0].annotations["kubernetes.io/change-cause"],                                   # rollout tooling writes this (Keel did until 2026-10)
      metadata[0].annotations["deployment.kubernetes.io/revision"],                            # K8s increments this on every rollout
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],                      # LEGACY_TEMPLATE_ANNOTATIONS
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "novelapp"
      }
    }
    template {
      metadata {
        labels = {
          app = "novelapp"
        }
      }
      spec {
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.novelapp-data.metadata[0].name
          }
        }
        container {
          image = "mghee/novelapp:v1.1.6"
          name  = "novelapp"
          # Viktor wants novelapp on Gheorghe's newest release (majors
          # included). Renovate bumps this semver tag; a new tag always pulls
          # fresh, so IfNotPresent is enough. Upstream also has malformed
          # `v.1.x.x`, SHA and `test` tags; the 2026-10-10 Renovate dry run
          # still picked v1.1.6 correctly.
          image_pull_policy = "IfNotPresent"
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "DB_PATH"
            value = "/app/data/novelapp.db"
          }
          env {
            name  = "DISABLE_BROWSER_SCRAPING"
            value = "true"
          }
          env {
            name  = "PORT"
            value = "3000"
          }
          env {
            name  = "AUTH_URL"
            value = "https://novelapp.viktorbarzin.me"
          }
          env {
            name = "AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = "novelapp-secrets"
                key  = "auth_secret"
              }
            }
          }
          env {
            name  = "AUTH_TRUST_HOST"
            value = "true"
          }
          env {
            name = "GOOGLE_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "novelapp-secrets"
                key  = "google_client_id"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "novelapp-secrets"
                key  = "google_client_secret"
              }
            }
          }
          env {
            name  = "ALLOWED_ORIGIN"
            value = "https://novelapp.viktorbarzin.me"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
          port {
            container_port = 3000
          }
          resources {
            # 640Mi (reverted from the 2026-07-14 320Mi right-size). The 320Mi
            # was sized from the IDLE working set (~156Mi, 2x) with no headroom
            # for request-time spikes; under real traffic novelapp (public Next.js,
            # SSR) briefly spikes past 320Mi and the cgroup OOM-killer killed it
            # ~10x/23h once it was restored to always-on (steady WS ~200Mi but
            # the spikes are sub-scrape so metrics never showed >211Mi). 640Mi is
            # the proven pre-right-size value. Do not re-trim from idle metrics.
            requests = {
              memory = "640Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "640Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "novelapp" {
  metadata {
    name      = "novelapp"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
    labels = {
      "app" = "novelapp"
    }
  }

  spec {
    selector = {
      app = "novelapp"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": novelapp handles its own auth via NextAuth + Google OAuth
  # (AUTH_URL/AUTH_SECRET/GOOGLE_CLIENT_{ID,SECRET} env vars above). Putting
  # Authentik forward-auth in front double-gates the app and breaks iOS/Android
  # webview clients that can't complete the Authentik 302/cookie dance.
  auth = "app"
  # ADR-0026 / code-6m20: grey because forward-auth broke the NextAuth /
  # Google OAuth flow and the mobile webviews. That is a Traefik concern,
  # not a Cloudflare one. Proxied rides the zone-wide wildcard CNAME
  # (ADR-0021) and creates no A/AAAA record.
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.novelapp.metadata[0].name
  name            = "novelapp"
  tls_secret_name = var.tls_secret_name

  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "NovelApp"
    "gethomepage.dev/description"  = "Web novel tracker"
    "gethomepage.dev/icon"         = "mdi-book-open-page-variant"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# RBAC — grant vabbit81 (Gheorghe) admin access to novelapp namespace.
# Two subjects: the OIDC User (for kubectl/kubelogin, once apiserver OIDC works)
# AND his dashboard ServiceAccount (the web dashboard injects this SA's token —
# see stacks/k8s-dashboard/dashboard_injector.tf — so it needs the grant too,
# since the apiserver sees the SA, not the email, as the subject).
resource "kubernetes_role_binding" "novelapp_owner_vabbit81" {
  metadata {
    name      = "novelapp-owner-vabbit81"
    namespace = kubernetes_namespace.novelapp.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = "vabbit81@gmail.com"
  }
  subject {
    api_group = ""
    kind      = "ServiceAccount"
    name      = "dashboard-vabbit81"
    namespace = "vabbit81"
  }
}

# Sealed Secrets — encrypted secrets safe to commit to git
resource "kubernetes_manifest" "sealed_secrets" {
  for_each = fileset(path.module, "sealed-*.yaml")
  manifest = yamldecode(file("${path.module}/${each.value}"))
}
