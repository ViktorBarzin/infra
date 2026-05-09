variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "forgejo" {
  metadata {
    name = "forgejo"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.forgejo.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "forgejo-data-encrypted"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "50Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "30Gi"
      }
    }
  }
  lifecycle {
    # pvc-autoresizer expands this PVC up to storage_limit; ignore drift on
    # requests.storage. To bump the floor manually: temporarily remove this
    # block, apply the new size, re-add the block, apply again.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "forgejo" {
  metadata {
    name      = "forgejo"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
    labels = {
      app  = "forgejo"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "forgejo"
      }
    }
    template {
      metadata {
        labels = {
          app = "forgejo"
        }
      }
      spec {
        # fsGroup chowns the mounted PVC to GID 1000 (the forgejo user) on
        # mount. Without this, /data is owned by root and the
        # `[packages].CHUNKED_UPLOAD_PATH` default at /data/tmp is not
        # writable, crashlooping the pod when packages is enabled. Pre-23-day
        # Forgejo ran without packages on so this never surfaced.
        security_context {
          fs_group = 1000
        }
        container {
          name  = "forgejo"
          image = "codeberg.org/forgejo/forgejo:11"
          env {
            name  = "USER_UID"
            value = 1000
          }
          env {
            name  = "USER_GID"
            value = 1000
          }
          # Root URL for OAuth2 redirect callbacks
          env {
            name  = "FORGEJO__server__ROOT_URL"
            value = "https://forgejo.viktorbarzin.me"
          }
          # Disable local registration — only allow OAuth2 (Authentik)
          env {
            name  = "FORGEJO__service__DISABLE_REGISTRATION"
            value = "false"
          }
          env {
            name  = "FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION"
            value = "true"
          }
          env {
            name  = "FORGEJO__openid__ENABLE_OPENID_SIGNIN"
            value = "false"
          }
          # Allow webhook delivery to internal k8s services AND to the public
          # ingress hostnames Forgejo's own webhooks point to (ci.viktorbarzin.me
          # for Woodpecker pipelines).
          env {
            name  = "FORGEJO__webhook__ALLOWED_HOST_LIST"
            value = "*.svc.cluster.local,ci.viktorbarzin.me,*.viktorbarzin.me"
          }
          # Default DELIVER_TIMEOUT is 5s — too tight for the Cloudflare-tunnel
          # round-trip on first request after pod restart (cold TLS handshake
          # can hit 6-8s). 30s comfortably covers retries.
          env {
            name  = "FORGEJO__webhook__DELIVER_TIMEOUT"
            value = "30"
          }
          # OCI registry (container packages). Default-on in Forgejo v11 but
          # explicit so it can't be silently disabled by an upstream config
          # change. CHUNKED_UPLOAD_PATH defaults to `data/tmp/package-upload`
          # under Forgejo's AppDataPath (resolves to a writable subdir of
          # /data/gitea/) — overriding to /data/tmp directly hits a perms
          # issue because /data is the volume mount root and is not chowned
          # to the forgejo user.
          env {
            name  = "FORGEJO__packages__ENABLED"
            value = "true"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "forgejo" {
  metadata {
    name      = "forgejo"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
    labels = {
      "app" = "forgejo"
    }
  }

  spec {
    selector = {
      app = "forgejo"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.forgejo.metadata[0].name
  name            = "forgejo"
  tls_secret_name = var.tls_secret_name
  # OCI registry pushes ship full image layer blobs in one request; default
  # Traefik buffering chokes on anything past a few hundred MB.
  max_body_size = "5g"
  extra_annotations = {
    "gethomepage.dev/enabled"                      = "true"
    "gethomepage.dev/name"                         = "Forgejo"
    "gethomepage.dev/description"                  = "Git hosting"
    "gethomepage.dev/icon"                         = "forgejo.png"
    "gethomepage.dev/group"                        = "Development & CI"
    "gethomepage.dev/pod-selector"                 = ""
    "uptime.viktorbarzin.me/external-monitor-path" = "/api/healthz"
  }
}
