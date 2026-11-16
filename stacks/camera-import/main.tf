# Camera import: photos from Viktor's Nikon Z5 II go straight into Immich over
# Wi-Fi, without a USB cable (USB storage is off on his laptop).
#
# The camera's built-in "Connect to FTP server" sends each new JPEG over SFTP
# to SFTPGo here, on 10.0.20.213:22. London reaches it over
# the WireGuard site-to-site tunnel. SFTPGo writes every upload to a temp path
# and renames it into the inbox only when complete (upload_mode 1, atomic), so
# an interrupted transfer leaves nothing behind. The uploader container runs
# the official Immich CLI on the inbox every 30 s with an Immich API key on
# Viktor's account that can only upload, and the CLI deletes each file once
# Immich has it. The camera keeps its own copy on the SD card.
#
# Runbook: docs/runbooks/camera-import.md.

variable "proxmox_host" { type = string }

locals {
  name      = "camera-import"
  namespace = "camera-import"
  labels    = { app = local.name }

  sftpgo_image = "ghcr.io/drakkan/sftpgo:v2.7.6-slim"
  # Same version as the Immich server (stacks/immich var.immich_version).
  cli_image = "ghcr.io/immich-app/immich-cli:3.4.1"

  data_dir = "/srv/data"
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = local.namespace
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

# Vault secret/camera-import:
#   immich_api_key   Immich key "camera-import" on Viktor's account, permissions
#                    asset.upload, user.read, apiKey.read (what `immich upload` checks)
#   sftp_password    the camera's SFTP password, typed on the camera once
#   host_key_*       SFTPGo's SSH host keys, fixed so a pod restart does not
#                    present the camera with a new server identity
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.name}-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "${local.name}-secrets"
        template = {
          engineVersion = "v2"
          data = {
            # SFTPGo's memory data provider loads its one user from this dump
            # at startup. Uploads land in the inbox; nothing else is reachable.
            # The password goes in through the ESO template (toJson quotes it).
            "users.json" = replace(jsonencode({
              version = 16
              folders = []
              admins  = []
              users = [{
                username    = "camera"
                password    = "@@PASSWORD@@"
                status      = 1
                home_dir    = "${local.data_dir}/incoming"
                permissions = { "/" = ["*"] }
              }]
            }), "\"@@PASSWORD@@\"", "{{ .sftp_password | toJson }}")
            IMMICH_API_KEY = "{{ .immich_api_key }}"
            id_rsa         = "{{ .host_key_rsa }}"
            id_ecdsa       = "{{ .host_key_ecdsa }}"
            id_ed25519     = "{{ .host_key_ed25519 }}"
          }
        }
      }
      dataFrom = [{
        extract = {
          key = local.name
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.this]
}

module "nfs_data" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "camera-import-data-host"
  namespace          = kubernetes_namespace.this.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs/camera-import" # incoming/ and .tmp/, owned by uid 1000
  storage_class_name = "nfs-pve"
  storage            = "20Gi"
}

resource "kubernetes_config_map" "uploader" {
  metadata {
    name      = "${local.name}-uploader"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    "uploader.sh" = file("${path.module}/uploader.sh")
  }
}

resource "kubernetes_deployment" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.aux })
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # one writer on the inbox
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "checksum/uploader" = sha256(file("${path.module}/uploader.sh"))
        }
      }
      spec {
        security_context {
          run_as_user     = 1000
          run_as_group    = 1000
          run_as_non_root = true
          # Group-readable Secret files for uid 1000. The NFS root is already
          # group 1000, so OnRootMismatch never walks the inbox.
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
        }

        container {
          name  = "sftpgo"
          image = local.sftpgo_image
          env {
            name  = "SFTPGO_DATA_PROVIDER__DRIVER"
            value = "memory"
          }
          env {
            name  = "SFTPGO_DATA_PROVIDER__NAME"
            value = "/etc/sftpgo-secrets/users.json"
          }
          env {
            name  = "SFTPGO_SFTPD__HOST_KEYS"
            value = "/etc/sftpgo-secrets/id_rsa,/etc/sftpgo-secrets/id_ecdsa,/etc/sftpgo-secrets/id_ed25519"
          }
          env {
            name  = "SFTPGO_COMMON__UPLOAD_MODE"
            value = "1" # atomic: temp file, renamed into the inbox when complete
          }
          env {
            # Outside the inbox so the uploader never sees a partial file;
            # same NFS mount so the final rename is a rename, not a copy.
            name  = "SFTPGO_COMMON__TEMP_PATH"
            value = "${local.data_dir}/.tmp"
          }
          env {
            name  = "SFTPGO_HTTPD__BINDINGS__0__PORT"
            value = "0" # no web admin or REST API
          }
          env {
            name  = "SFTPGO_TELEMETRY__BIND_ADDRESS"
            value = "0.0.0.0"
          }
          env {
            name  = "SFTPGO_TELEMETRY__BIND_PORT"
            value = "10000"
          }
          env {
            name  = "SFTPGO_LOG_LEVEL"
            value = "info"
          }
          port {
            name           = "sftp"
            container_port = 2022
          }
          port {
            name           = "http"
            container_port = 10000
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 10000
            }
            period_seconds = 10
          }
          liveness_probe {
            tcp_socket {
              port = 2022
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          volume_mount {
            name       = "data"
            mount_path = local.data_dir
          }
          volume_mount {
            name       = "secrets"
            mount_path = "/etc/sftpgo-secrets"
            read_only  = true
          }
          volume_mount {
            name       = "sftpgo-home"
            mount_path = "/var/lib/sftpgo"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        container {
          name    = "uploader"
          image   = local.cli_image
          command = ["sh", "/opt/uploader/uploader.sh"]
          env {
            name  = "IMMICH_INSTANCE_URL"
            value = "http://immich-server.immich.svc.cluster.local:2283/api"
          }
          env {
            name = "IMMICH_API_KEY"
            value_from {
              secret_key_ref {
                name = "${local.name}-secrets"
                key  = "IMMICH_API_KEY"
              }
            }
          }
          env {
            name  = "INCOMING"
            value = "${local.data_dir}/incoming"
          }
          env {
            name  = "PUSH_URL"
            value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/camera-import"
          }
          env {
            name  = "HOME"
            value = "/tmp" # the CLI keeps its config dir here
          }
          volume_mount {
            name       = "data"
            mount_path = local.data_dir
          }
          volume_mount {
            name       = "uploader"
            mount_path = "/opt/uploader"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        volume {
          name = "secrets"
          secret {
            secret_name  = "${local.name}-secrets"
            default_mode = "0440"
            items {
              key  = "users.json"
              path = "users.json"
            }
            items {
              key  = "id_rsa"
              path = "id_rsa"
            }
            items {
              key  = "id_ecdsa"
              path = "id_ecdsa"
            }
            items {
              key  = "id_ed25519"
              path = "id_ed25519"
            }
          }
        }
        volume {
          name = "uploader"
          config_map {
            name = kubernetes_config_map.uploader.metadata[0].name
          }
        }
        volume {
          name = "sftpgo-home"
          empty_dir {}
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [kubernetes_manifest.external_secret]
}

# SFTP for the camera, on its own IP so it can use the default port 22 (the
# camera's setup wizard connects before it asks for a port, and port 22 on the
# shared 10.0.20.200 is Forgejo's). LAN and tunnel only, no WAN forward.
resource "kubernetes_service" "sftp" {
  metadata {
    name      = "${local.name}-sftp"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.213"
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector                = local.labels
    port {
      name        = "sftp"
      port        = 22
      target_port = 2022
      protocol    = "TCP"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]] # METALLB_LIFECYCLE_V1
  }
}

# SFTPGo's health endpoint, for Uptime Kuma: internal-monitor-sync creates
# `[Internal] camera-import` from these annotations.
resource "kubernetes_service" "health" {
  metadata {
    name      = "${local.name}-health"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
    annotations = {
      "uptime.viktorbarzin.me/internal-monitor"      = "true"
      "uptime.viktorbarzin.me/internal-monitor-name" = "camera-import"
      "uptime.viktorbarzin.me/internal-monitor-path" = "/healthz"
    }
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 10000
      target_port = 10000
    }
  }
}
