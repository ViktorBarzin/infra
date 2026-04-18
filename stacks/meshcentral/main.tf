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

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "meshcentral-data-encrypted"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
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
}

resource "kubernetes_persistent_volume_claim" "files_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "meshcentral-files-encrypted"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  name            = "meshcentral"
  tls_secret_name = var.tls_secret_name
  port            = 80
  protected         = true
  anti_ai_scraping  = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "MeshCentral"
    "gethomepage.dev/description"  = "Remote management"
    "gethomepage.dev/icon"         = "meshcentral.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
