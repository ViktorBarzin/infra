variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "linkwarden"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "linkwarden" {
  metadata {
    name = "linkwarden"
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

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "linkwarden-secrets"
      namespace = "linkwarden"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "linkwarden-secrets"
      }
      dataFrom = [{
        extract = {
          key = "linkwarden"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.linkwarden]
}

# DB credentials from Vault database engine (rotated every 24h)
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "linkwarden-db-creds"
      namespace = "linkwarden"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "linkwarden-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DATABASE_URL = "postgresql://linkwarden:{{ .password }}@${var.postgresql_host}:5432/linkwarden"
            DB_PASSWORD  = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-linkwarden"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.linkwarden]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "secret" {
  length           = 32
  special          = true
  override_special = "/@£$"
}

# Page archives (PDF / screenshot / readable JSON / single-file HTML).
# Linkwarden keeps only the *path* to each artifact in Postgres and writes the
# bytes to STORAGE_FOLDER, so without a volume every archive lived on the
# container's ephemeral overlay and was lost on each pod restart while the app
# kept re-generating them.
# Encrypted class: saved bookmarks + their full page contents are personal
# browsing history (sensitive data -> proxmox-lvm-encrypted per the storage
# decision rule in .claude/CLAUDE.md).
# NO backup CronJob deliberately: archives are DERIVED data, regenerable from
# the URLs in Postgres (which the nightly per-db pg_dump already covers). Same
# rationale as the regenerable stores excluded from nfs-mirror.
resource "kubernetes_persistent_volume_claim" "archives" {
  wait_until_bound = false
  metadata {
    name      = "linkwarden-archives-encrypted"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and PVCs
    # can't shrink; without this every apply tries to revert the size.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    labels = {
      app  = "linkwarden"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      # RWO archive volume — a rolling update would deadlock on the new pod
      # waiting for a volume the old pod still holds.
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "linkwarden"
      }
    }
    template {
      metadata {
        labels = {
          app = "linkwarden"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^v?\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        container {
          image = "ghcr.io/linkwarden/linkwarden:v2.14.0"
          name  = "linkwarden"

          port {
            container_port = 3000
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "linkwarden-db-creds"
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name  = "NEXT_PUBLIC_AUTHENTIK_ENABLED"
            value = "true"
          }
          # Absolute path so archives land on the PVC below rather than the
          # app's working directory. Linkwarden resolves this with path.join(),
          # which preserves an absolute value; its default is the RELATIVE
          # "data", i.e. /data/data inside the image's source tree.
          env {
            name  = "STORAGE_FOLDER"
            value = "/storage"
          }
          env {
            name  = "NEXTAUTH_SECRET"
            value = random_string.secret.result
          }
          env {
            name  = "NEXTAUTH_URL"
            value = "https://linkwarden.viktorbarzin.me/api/v1/auth"
          }
          env {
            name  = "AUTHENTIK_ISSUER"
            value = "https://authentik.viktorbarzin.me/application/o/linkwarden"
          }
          env {
            name = "AUTHENTIK_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "linkwarden-secrets"
                key  = "authentik_client_id"
              }
            }
          }
          env {
            name = "AUTHENTIK_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "linkwarden-secrets"
                key  = "authentik_client_secret"
              }
            }
          }
          volume_mount {
            name       = "archives"
            mount_path = "/storage"
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "1Gi"
            }
            limits = {
              memory = "1280Mi"
            }
          }
        }
        volume {
          name = "archives"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.archives.metadata[0].name
          }
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
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}
resource "kubernetes_service" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    labels = {
      app = "linkwarden"
    }
  }

  spec {
    selector = {
      app = "linkwarden"
    }
    port {
      name        = "linkwarden"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": Linkwarden uses NextAuth (NEXTAUTH_SECRET/URL set above)
  # and exposes /api/* for its mobile clients. Authentik forward-auth would
  # 302 those callers; app-level NextAuth gates users.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  name            = "linkwarden"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Linkwarden"
    "gethomepage.dev/description"  = "Bookmark manager"
    "gethomepage.dev/icon"         = "linkwarden.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "linkwarden"
    "gethomepage.dev/widget.url"   = "http://linkwarden.linkwarden.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.homepage_credentials["linkwarden"]["api_key"]
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
