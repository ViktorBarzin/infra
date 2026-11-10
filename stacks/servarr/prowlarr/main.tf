variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}


module "nfs_downloads_host" {
  source             = "../../../modules/kubernetes/nfs_volume"
  name               = "servarr-prowlarr-downloads-host"
  namespace          = "servarr"
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/servarr/downloads"
  storage_class_name = "nfs-pve"
}

# Prowlarr keeps its indexers, apps and history in the shared Postgres since
# 2026-11-10: databases prowlarr (main) and prowlarr_log, both owned by the
# prowlarr role, whose password the Vault static role pg-prowlarr rotates
# (Tuesday 10:13). Prowlarr reads Prowlarr:Postgres:* from the environment
# (src/NzbDrone.Core/Datastore/PostgresOptions.cs). Reloader restarts it when
# the Secret changes.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "prowlarr-db-creds"
      namespace = "servarr"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "prowlarr-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            password = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-prowlarr"
          property = "password"
        }
      }]
    }
  }
}

# /config after the move to Postgres: config.xml (API key, auth), asp/
# DataProtection keys, indexer Definitions, Backups and text logs. No SQLite is
# opened any more, so NFS is safe (Servarr wants /config on local disk only
# because of SQLite). Moved off the block PVC servarr-prowlarr-data-proxmox on
# 2026-11-10 to free a proxmox-csi slot.
module "nfs_config_host" {
  source             = "../../../modules/kubernetes/nfs_volume"
  name               = "servarr-prowlarr-config-host"
  namespace          = "servarr"
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/servarr/prowlarr-config"
  storage            = "2Gi"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = "servarr"
    labels = {
      app  = "prowlarr"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "prowlarr"
      }
    }
    template {
      metadata {
        labels = {
          app = "prowlarr"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/prowlarr:2.7.0"
          name  = "prowlarr"

          resources {
            requests = {
              cpu    = "10m"
              memory = "192Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
          port {
            container_port = 9696
          }
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "TZ"
            value = "Etc/UTC"
          }
          env {
            name  = "Prowlarr__Postgres__Host"
            value = var.postgresql_host
          }
          env {
            name  = "Prowlarr__Postgres__Port"
            value = "5432"
          }
          env {
            name  = "Prowlarr__Postgres__User"
            value = "prowlarr"
          }
          env {
            name = "Prowlarr__Postgres__Password"
            value_from {
              secret_key_ref {
                name = "prowlarr-db-creds"
                key  = "password"
              }
            }
          }
          env {
            name  = "Prowlarr__Postgres__MainDb"
            value = "prowlarr"
          }
          env {
            name  = "Prowlarr__Postgres__LogDb"
            value = "prowlarr_log"
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "data"
            mount_path = "/books"
          }
          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_config_host.claim_name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_downloads_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "prowlarr" {
  metadata {
    name      = "prowlarr"
    namespace = "servarr"
    labels = {
      app = "prowlarr"
    }
  }

  spec {
    selector = {
      app = "prowlarr"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 9696
    }
  }
}


module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "servarr"
  name            = "prowlarr"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Prowlarr"
    "gethomepage.dev/description"  = "Indexer manager"
    "gethomepage.dev/icon"         = "prowlarr.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "prowlarr"
    "gethomepage.dev/widget.url"   = "http://prowlarr.servarr.svc.cluster.local"
    "gethomepage.dev/widget.key"   = var.homepage_credentials["prowlarr"]["api_key"]
  }
}
