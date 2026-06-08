variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "matrix" {
  metadata {
    name = "matrix"
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

# Registration token from Vault KV (secret/matrix). Token-gated registration:
# enabled transiently to register the admin account, then allow_registration is
# flipped to false. The token stays in Vault so registration can be re-opened
# later (e.g. to add family) without regenerating it.
resource "kubernetes_manifest" "secrets_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "matrix-secrets"
      namespace = "matrix"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "matrix-secrets"
      }
      dataFrom = [{
        extract = {
          key = "matrix"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.matrix]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# RocksDB lives here. proxmox-lvm-encrypted (local SSD, LUKS2) suits the
# homeserver DB's many small writes; NFS would be the wrong backend.
resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "matrix-data-encrypted"
    namespace = kubernetes_namespace.matrix.metadata[0].name
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

resource "kubernetes_deployment" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      app  = "matrix"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "matrix"
      }
    }
    template {
      metadata {
        labels = {
          app = "matrix"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        # tuwunel runs as an unprivileged static binary; fsGroup makes the
        # encrypted RocksDB volume group-writable so uid 1000 can write it
        # (avoids the init-chown/fsGroup mismatch that parked hermes-agent).
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }
        container {
          image = "ghcr.io/matrix-construct/tuwunel:v1.7.1"
          name  = "matrix"
          port {
            container_port = 8008
          }
          env {
            name  = "TUWUNEL_SERVER_NAME"
            value = "matrix.viktorbarzin.me"
          }
          env {
            name  = "TUWUNEL_DATABASE_PATH"
            value = "/var/lib/tuwunel"
          }
          env {
            name  = "TUWUNEL_PORT"
            value = "8008"
          }
          env {
            name  = "TUWUNEL_ADDRESS"
            value = "0.0.0.0"
          }
          env {
            name  = "TUWUNEL_ALLOW_FEDERATION"
            value = "true"
          }
          env {
            name  = "TUWUNEL_TRUSTED_SERVERS"
            value = jsonencode(["matrix.org"])
          }
          # Registration disabled. To add a user later: set "true", apply,
          # register with the Vault token (secret/matrix), then set back to "false".
          env {
            name  = "TUWUNEL_ALLOW_REGISTRATION"
            value = "false"
          }
          env {
            name = "TUWUNEL_REGISTRATION_TOKEN"
            value_from {
              secret_key_ref {
                name = "matrix-secrets"
                key  = "registration_token"
              }
            }
          }
          # 50 MiB — kept under Cloudflare's 100 MB proxied-request ceiling.
          env {
            name  = "TUWUNEL_MAX_REQUEST_SIZE"
            value = "52428800"
          }
          # tuwunel serves its own .well-known so federation resolves to 443
          # (Cloudflare-proxied) without a separate 8448 / SRV record.
          env {
            name  = "TUWUNEL_WELL_KNOWN__CLIENT"
            value = "https://matrix.viktorbarzin.me"
          }
          env {
            name  = "TUWUNEL_WELL_KNOWN__SERVER"
            value = "matrix.viktorbarzin.me:443"
          }
          # Real client IP for rate-limiting: behind Cloudflare's CF-Connecting-IP.
          env {
            name  = "TUWUNEL_IP_SOURCE"
            value = "cf_connecting_ip"
          }
          env {
            name  = "TUWUNEL_LOG"
            value = "warn,tuwunel=info"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/tuwunel"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
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

resource "kubernetes_service" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      "app" = "matrix"
    }
  }

  spec {
    selector = {
      app = "matrix"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8008"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Matrix homeserver — both client-server (/_matrix/client) and
  # server-server (/_matrix/federation) APIs use bearer tokens / signed
  # requests, not browser sessions. Forward-auth would break federation
  # and all native Matrix clients.
  # auth = "none": Matrix client-server + federation APIs use bearer tokens / signed requests; forward-auth incompatible with native clients.
  auth            = "none"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  name            = "matrix"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Matrix"
    "gethomepage.dev/description"  = "Secure messaging (tuwunel)"
    "gethomepage.dev/icon"         = "matrix.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
