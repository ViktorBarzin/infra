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
      tier               = local.tiers.aux
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
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  tls_secret_name = var.tls_secret_name
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

resource "kubernetes_persistent_volume_claim" "files_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "meshcentral-files-encrypted"
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
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "meshcentral-backups-host"
  namespace  = kubernetes_namespace.meshcentral.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/meshcentral/meshcentral-backups"
}

resource "kubernetes_deployment" "meshcentral" {
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$,latest"
        }
      }
      spec {

        init_container {
          name              = "fix-config"
          image             = "alpine:latest"
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh"]
          args = ["-c", <<-EOT
CONFIG=/opt/meshcentral/meshcentral-data/config.json
if [ -f "$CONFIG" ]; then
  # Disable certUrl when using Traefik reverse proxy with TLS offload
  sed -i 's/"certUrl":/"_certUrl":/g' "$CONFIG"

  # Fix WebRTC value from string to boolean
  sed -i 's/"WebRTC": "[^"]*"/"WebRTC": false/g' "$CONFIG"

  # Ensure TLSOffload is enabled (Traefik terminates TLS, MeshCentral serves HTTP on 443)
  sed -i 's/"_TLSOffload":/"TLSOffload":/g' "$CONFIG"
  sed -i 's/"TLSOffload": "[^"]*"/"TLSOffload": true/g' "$CONFIG"
  sed -i 's/"TLSOffload": false/"TLSOffload": true/g' "$CONFIG"

  # ignoreAgentHashCheck: stop pinning the OUTER (Traefik) TLS cert hash on the
  # agent handshake. With TLS offload, the agent sees Traefik's Let's Encrypt
  # cert (which also differs between the internal .203 LB and the external
  # Cloudflare path, and rotates ~monthly), not MeshCentral's own webserver
  # cert — so the default cert-pin fails with "Agent bad web cert hash" and
  # holds EVERY agent connection (the whole fleet went offline). With this set,
  # MeshCentral echoes back whatever cert hash the agent reports, so the
  # pin succeeds on any path/cert. The agent's separate mesh-certificate
  # handshake (ServerID) still authenticates the server — this only drops the
  # redundant outer-TLS pin, which is safe behind our trusted-network Traefik.
  # Insert the key right after TLSOffload (guaranteed present post-patch) if not
  # already there. MeshCentral lowercases settings keys, so casing is flexible.
  if ! grep -qi '"ignoreAgentHashCheck"' "$CONFIG"; then
    sed -i 's/"TLSOffload": true/"TLSOffload": true,\n    "ignoreAgentHashCheck": true/' "$CONFIG"
  fi
else
  # First run: create config from template before startup.sh runs, so REVERSE_PROXY
  # env var doesn't generate a bad certUrl. Pre-seed with correct values.
  cat > "$CONFIG" <<'CONF'
{
  "$schema": "http://info.meshcentral.com/downloads/meshcentral-config-schema.json",
  "settings": {
    "cert": "meshcentral.viktorbarzin.me",
    "_WANonly": true,
    "_LANonly": true,
    "port": 443,
    "redirPort": 80,
    "AgentPong": 300,
    "TLSOffload": true,
    "ignoreAgentHashCheck": true,
    "SelfUpdate": false,
    "AllowFraming": false,
    "WebRTC": false
  },
  "domains": {
    "": {
      "NewAccounts": false
    }
  }
}
CONF
fi
EOT
          ]
          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-data"
          }
        }

        container {
          image = "typhonragewind/meshcentral:latest"
          name  = "meshcentral"
          port {
            name           = "http"
            container_port = 443
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "HOSTNAME"
            value = "meshcentral.viktorbarzin.me"
          }
          env {
            name  = "REVERSE_PROXY"
            value = "false"
          }
          env {
            name  = "ALLOW_NEW_ACCOUNTS"
            value = "false"
          }
          env {
            name  = "WEBRTC"
            value = "false"
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-data"
          }
          volume_mount {
            name       = "files"
            mount_path = "/opt/meshcentral/meshcentral-files"
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
          name = "files"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.files_encrypted.metadata[0].name
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
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      spec[0].template[0].spec[0].init_container[0].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
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
