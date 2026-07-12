variable "tls_secret_name" {
  type = string
}
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }

resource "kubernetes_namespace" "hackmd" {
  metadata {
    name = "hackmd"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.edge
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
  namespace       = kubernetes_namespace.hackmd.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Image uploads on NFS. Migrated off proxmox-lvm-encrypted 2026-06-05 for
# LUN-cap relief — codimd is MySQL-backed; this PVC holds only pasted image
# uploads (low-sensitivity), so dropping LUKS-at-rest for NFS is accepted.
# No embedded DB. See docs/plans/2026-06-05-block-storage-harden-nfs-design.md
module "nfs_hackmd" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "hackmd-uploads-nfs"
  namespace  = kubernetes_namespace.hackmd.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/hackmd"
  storage    = "5Gi"
}

resource "kubernetes_deployment" "hackmd" {
  metadata {
    name      = "hackmd"
    namespace = kubernetes_namespace.hackmd.metadata[0].name
    labels = {
      app                             = "hackmd"
      "kubernetes.io/cluster-service" = "true"
      tier                            = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    # PARKED (2026-07-12, Viktor) — unused; WebSocket-core so it can't
    # wake-on-request (ADR-0022 ineligible). Revive: set to 1.
    replicas = 0
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "hackmd"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "hackmd"
          "kubernetes.io/cluster-service" = "true"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        # container {
        #   image             = "postgres:11.6-alpine"
        #   name              = "postgres"
        #   image_pull_policy = "IfNotPresent"
        #   env {
        #     name  = "POSTGRES_USER"
        #     value = "codimd"
        #   }
        #   env {
        #     name  = "POSTGRES_PASSWORD"
        #     value = var.hackmd_db_password
        #   }
        #   env {
        #     name  = "POSTGRES_DB"
        #     value = "codimd"
        #   }
        #   resources {
        #     limits = {
        #       cpu    = "1"
        #       memory = "1Gi"
        #     }
        #     requests = {
        #       cpu    = "1"
        #       memory = "1Gi"
        #     }
        #   }
        #   port {
        #     container_port = 80
        #   }
        # volume_mount {
        #   name       = "data"
        #   mount_path = "/var/lib/postgresql/data"
        #   sub_path   = "postgres"
        # }
        # }

        container {
          name  = "codimd"
          image = "hackmdio/hackmd"
          env {
            name = "CMD_DB_URL"
            value_from {
              secret_key_ref {
                name = "hackmd-secrets"
                key  = "CMD_DB_URL"
              }
            }
          }
          env {
            name  = "CMD_USECDN"
            value = "false"
          }
          volume_mount {
            name       = "data"
            mount_path = "/home/hackmd/app/public/uploads"
            sub_path   = "hackmd"
          }
          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        security_context {
          fs_group = "1500"
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_hackmd.claim_name
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

resource "kubernetes_service" "hackmd" {
  metadata {
    name      = "hackmd"
    namespace = kubernetes_namespace.hackmd.metadata[0].name
    labels = {
      "app" = "hackmd"
    }
  }

  spec {
    selector = {
      app = "hackmd"
    }
    port {
      port        = "80"
      target_port = "3000"
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.hackmd.metadata[0].name
  name            = "hackmd"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "HackMD"
    "gethomepage.dev/description"  = "Collaborative markdown"
    "gethomepage.dev/icon"         = "hedgedoc.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
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
      name      = "hackmd-secrets"
      namespace = "hackmd"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "hackmd-secrets"
        template = {
          data = {
            CMD_DB_URL = "mysql://codimd:{{ .db_password }}@mysql.dbaas.svc.cluster.local/codimd"
          }
        }
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-codimd"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.hackmd]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
