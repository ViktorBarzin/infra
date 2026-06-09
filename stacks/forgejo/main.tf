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
  namespace       = kubernetes_namespace.forgejo.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "forgejo-data-encrypted"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
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
    annotations = {
      # Keel disabled here — its `force` policy rewrote the image tag
      # from 11.0.14 → 1.18 on 2026-05-24 (same bug as memory id=1933).
      # TF owns the tag now; bump it manually here when upgrading.
      "keel.sh/policy" = "never"
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
          name = "forgejo"
          # Pinned to 11.0.14 (latest 11.x as of 2026-05-12) — was on
          # floating `:11`. On 2026-05-24T15:35:37Z Keel force-policy
          # rewrote the tag from `11.0.14 → 1.18` (Gitea-era Forgejo
          # v1.18), exact replay of the 2026-05-16 force-policy
          # tag-rewriting incident (memory id=1933). The pod crashlooped
          # because the DB had already been migrated to schema 305 by
          # 11.0.14 and v1.18 only knows up to migration 231.
          image = "codeberg.org/forgejo/forgejo:11.0.14"
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
          # Disable source archive ZIP/TAR generation. Bots crawling
          # /<owner>/<repo>/archive/<sha>.zip on dot_files (and similar
          # vim-plugin trees) caused 9.9s 500s and chewed ~440m sustained
          # CPU. Git clone / OCI registry / API are unaffected — only
          # /archive/* URLs return 404 now. Toggle back to "false" if a
          # legitimate consumer needs source ZIPs.
          env {
            name  = "FORGEJO__repository__DISABLE_DOWNLOAD_SOURCE_ARCHIVES"
            value = "true"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # Bumped 1Gi -> 3Gi 2026-06-09: Forgejo was OOMKilled (exit 137)
          # under registry-push load from in-cluster CI builds (tripit
          # buildkit pushes large layers into the OCI registry). VPA
          # upperBound reads ~1.5Gi, but that's suppressed by the 1Gi cap it
          # kept OOMing against — size for the push spike, not steady-state.
          # requests=limits (Guaranteed QoS) per the repo memory convention.
          resources {
            requests = {
              cpu    = "15m"
              memory = "3Gi"
            }
            limits = {
              memory = "3Gi"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # KEEL_IGNORE_IMAGE removed 2026-05-24 — Keel is disabled for this
      # workload now (keel.sh/policy=never annotation above), so TF owns
      # the image tag. Restore this ignore_changes line if you flip
      # keel.sh/policy back to `force` later.
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].spec[0].container[0].image,  # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],
    ]
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
  source = "../../modules/kubernetes/ingress_factory"
  # Git + OCI registry (/v2/) — native clients (git, docker/podman) use HTTP
  # basic-auth / bearer tokens, NOT browser sessions. Forward-auth would 302
  # them into a redirect they can't follow.
  # auth = "none": Git + OCI registry clients use HTTP Basic auth / bearer tokens; native CLI tools cannot follow forward-auth redirects.
  auth            = "none"
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
