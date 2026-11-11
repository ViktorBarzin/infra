variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "meshcentral" {
  metadata {
    name = "meshcentral"
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
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Vault secret/meshcentral: session_key, MeshCentral's settings.sessionKey,
# and backup_zip_password, the AES password for the nightly autobackup zips.
# The fix-config init container writes both into config.json. Until
# 2026-11-11 the session key existed only in config.json on the volume and in
# a stray copy in a devvm home; until 2026-11-12 the zips were unencrypted on
# the host's NFS export. The match annotation lets Reloader restart the pod
# when the key changes in Vault (the Deployment carries reloader search).
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "meshcentral-secrets"
      namespace = kubernetes_namespace.meshcentral.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "meshcentral-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [{
        secretKey = "session_key"
        remoteRef = {
          key      = "meshcentral"
          property = "session_key"
        }
        }, {
        secretKey = "backup_zip_password"
        remoteRef = {
          key      = "meshcentral"
          property = "backup_zip_password"
        }
      }]
    }
  }
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "meshcentral-data-encrypted"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
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

module "nfs_backups_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "meshcentral-backups-host"
  namespace          = kubernetes_namespace.meshcentral.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/meshcentral/meshcentral-backups"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "meshcentral" {
  # The init container reads SESSION_KEY from the Secret this creates.
  depends_on = [kubernetes_manifest.external_secret]
  metadata {
    name      = "meshcentral"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    labels = {
      app  = "meshcentral"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "meshcentral.enable"           = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "meshcentral"
      }
    }
    template {
      metadata {
        labels = {
          app = "meshcentral"
        }
      }
      spec {

        init_container {
          name              = "fix-config"
          image             = "alpine:3.24.4"
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh"]
          # The script, with its reasons, is files/fix-config.sh (test:
          # files/fix-config_test.sh).
          args = ["-c", file("${path.module}/files/fix-config.sh")]
          env {
            name = "SESSION_KEY"
            value_from {
              secret_key_ref {
                name = "meshcentral-secrets"
                key  = "session_key"
              }
            }
          }
          env {
            name = "BACKUP_ZIP_PASSWORD"
            value_from {
              secret_key_ref {
                name = "meshcentral-secrets"
                key  = "backup_zip_password"
              }
            }
          }
          # Changing this label makes fix-config drop the login-cookie,
          # invitation-link and AMT keys from meshcentral.db once, so
          # MeshCentral generates new ones on start. 2026-11-11: the old keys
          # sat in a world-readable copy of this volume on the devvm and in
          # its backups, and the login-cookie key let anyone holding it open
          # an admin /control.ashx session.
          env {
            name  = "DB_KEY_GENERATION"
            value = "2026-11-11"
          }
          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-data"
          }
        }

        container {
          # Upstream's official image. typhonragewind/meshcentral stopped at
          # 1.1.53 (Oct 2025), so Renovate had no newer tag to offer while
          # upstream shipped security releases (1.3.1 fixed an actively
          # exploited hole). Switched 2026-10-24.
          image = "ghcr.io/ylianst/meshcentral:1.3.1"
          name  = "meshcentral"
          port {
            name           = "http"
            container_port = 443
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          # config.json is owned by the fix-config init container. With
          # DYNAMIC_CONFIG on, the entrypoint would rewrite it from env vars
          # (HOSTNAME, REVERSE_PROXY, ...) on every start.
          env {
            name  = "DYNAMIC_CONFIG"
            value = "false"
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-data"
          }
          # User files live in the meshcentral-files subfolder of the data
          # volume since 2026-11-09. They had their own volume, which used a
          # proxmox-csi slot for 296 KB of empty folders
          # (docs/research/2026-11-09-block-volume-db-consolidation.md).
          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-files"
            sub_path   = "meshcentral-files"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "512Mi"
            }
            limits = {
              # 1.1.53 sat at 247Mi of a 256Mi limit; 1.3.x runs on Node 24
              # and caches the default agents at startup.
              memory = "512Mi"
            }
          }
          volume_mount {
            name       = "backups"
            mount_path = "/opt/meshcentral/meshcentral-backups"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
        volume {
          name = "backups"
          persistent_volume_claim {
            claim_name = module.nfs_backups_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}


resource "kubernetes_service" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    labels = {
      "app" = "meshcentral"
    }
  }

  spec {
    selector = {
      app = "meshcentral"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 443
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.meshcentral.metadata[0].name
  name             = "meshcentral"
  tls_secret_name  = var.tls_secret_name
  port             = 80
  auth             = "required"
  anti_ai_scraping = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "MeshCentral"
    "gethomepage.dev/description"  = "Remote management"
    "gethomepage.dev/icon"         = "meshcentral.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Path-level carve-out for MeshCentral's agent/relay/native-client endpoints.
# The main ingress above gates the ENTIRE site (path "/") behind Authentik
# forward-auth — which 302-bounces these endpoints to the SSO login. Mesh
# agents are native WebSocket/HTTP clients that authenticate with their own
# mesh certificate (TLS server-cert pinning + binary handshake on
# /agent.ashx); they cannot follow the Authentik 302 → OAuth → cookie dance,
# so every agent went OFFLINE. This second ingress points the agent paths at
# the same meshcentral Service with NO Authentik middleware. Traefik routes
# by rule length, so these path-scoped routers out-prioritise the "/"
# catch-all (same mechanism as blog's /net-diag.sh carve-out). The human web
# UI ("/") stays Authentik-gated via the module above.
module "ingress_agent" {
  source       = "../../modules/kubernetes/ingress_factory"
  namespace    = kubernetes_namespace.meshcentral.metadata[0].name
  name         = "meshcentral-agent"
  service_name = kubernetes_service.meshcentral.metadata[0].name
  port         = 80
  # auth = "none": MeshCentral agent/relay endpoints - native clients (mesh cert auth), cannot do Authentik SSO
  auth = "none"
  ingress_path = [
    "/agent.ashx",         # agent <-> server control channel (WebSocket)
    "/control.ashx",       # management WebSocket (also used by agent tunnels)
    "/meshrelay.ashx",     # relay/peer WebSocket for desktop/terminal/files
    "/meshagents",         # agent binary download (install + self-update)
    "/devicefile.ashx",    # file transfer to/from device
    "/agentdownload.ashx", # agent installer download
    "/meshsettings.ashx",  # agent .msh settings blob (server URL + mesh id)
    "/amtevents.ashx",     # Intel AMT/CIRA event ingest
  ]
  full_host        = "meshcentral.viktorbarzin.me"
  dns_type         = "none" # DNS already owned by the main meshcentral ingress.
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # Native-client endpoints; bot-block forwardAuth would break the agent handshake.
  homepage_enabled = false # Homepage tile belongs to the main UI ingress.
  external_monitor = false # The main ingress already carries the external monitor.
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
