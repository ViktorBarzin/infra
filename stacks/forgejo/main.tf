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
      # Opt out of the auto-generated tier-3-edge ResourceQuota (caps
      # requests.memory at 4Gi). Forgejo's own pod requests 4Gi (the
      # git + OCI-registry backbone, Guaranteed QoS), which pegged that
      # tier quota at 100% and fired KubeQuotaAlmostFull. The
      # forgejo-specific quota below gives headroom. Same pattern as dbaas.
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Custom ResourceQuota — replaces the tier-3-edge auto quota (opted out via the
# resource-governance/custom-quota label above). requests.memory is 8Gi so the
# 4Gi Forgejo pod sits at ~50% (clears KubeQuotaAlmostFull + the healthcheck
# resourcequota check) with room for a transient migration/sidecar pod. To
# raise Forgejo's memory limit past 4Gi later, bump requests.memory here too.
resource "kubernetes_resource_quota" "forgejo" {
  metadata {
    name      = "forgejo-quota"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "8Gi"
      "limits.memory"   = "32Gi"
      pods              = "30"
    }
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
      # Roll the pod when the signup secrets (forgejo-email password from Vault,
      # forgejo-turnstile secret) change — env vars are read at boot, not
      # hot-reloaded. Stakater Reloader watches all referenced secrets/CMs.
      "reloader.stakater.com/auto" = "true"
    }
  }
  # The forgejo-email Secret is materialised by the External Secrets operator
  # from the forgejo-email ExternalSecret (email-secret.tf); ensure the CR
  # exists before this deployment references it on a from-scratch apply.
  depends_on = [kubernetes_manifest.forgejo_email_secret]
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
          # Open self-service registration. Native local sign-up is allowed
          # (ALLOW_ONLY_EXTERNAL_REGISTRATION=false) alongside the existing
          # Authentik OAuth2 login. Bot abuse is gated by Cloudflare Turnstile
          # (ENABLE_CAPTCHA below) + mandatory email confirmation
          # (REGISTER_EMAIL_CONFIRM below). To re-close signups: set
          # DISABLE_REGISTRATION=true, or flip ALLOW_ONLY_EXTERNAL_REGISTRATION
          # back to "true" for OAuth-only. Runbook:
          # docs/runbooks/forgejo-open-signups.md
          env {
            name  = "FORGEJO__service__DISABLE_REGISTRATION"
            value = "false"
          }
          env {
            name  = "FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION"
            value = "false"
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
          # --- Mirror / git-op resilience (2026-06-19 incident). The tripit
          # push-mirror to GitHub silently stopped: `git cat-file --batch-all-objects`
          # over the NFS-backed repo blew the default git-op deadline (~360s) once
          # loose objects piled up (~4500). Forgejo's git_gc_repos cron only runs
          # `gc --auto`, whose 6700-loose threshold hadn't fired, so the repo stayed
          # unpacked and enumeration kept slowing until the mirror aborted with
          # "context deadline exceeded". Two-part durable fix:
          #   1) raise git-op timeouts so a slow enumeration never aborts a
          #      mirror/gc ([git.timeout], seconds);
          #   2) lower gc.auto so post-push autogc + the cron keep repos PACKED —
          #      the real fix ([git.config] gc.auto).
          # Dotted section/key names use the _0X2E_ env-to-ini escape.
          env {
            name  = "FORGEJO__git_0X2E_timeout__DEFAULT"
            value = "3600"
          }
          env {
            name  = "FORGEJO__git_0X2E_timeout__MIRROR"
            value = "3600"
          }
          env {
            name  = "FORGEJO__git_0X2E_timeout__GC"
            value = "1800"
          }
          env {
            name  = "FORGEJO__git_0X2E_config__gc_0X2E_auto"
            value = "1000"
          }
          # --- Open-signup bot prevention + mailer (appended so the diff vs the
          # pre-signup deployment stays purely additive). ---
          # Cloudflare Turnstile captcha on the registration form (widget
          # managed in turnstile.tf). Sitekey is public (rendered in the page);
          # the secret is injected from the forgejo-turnstile Secret. Guards
          # registration only — not every login (REQUIRE_CAPTCHA_FOR_LOGIN left
          # at the default false).
          env {
            name  = "FORGEJO__service__ENABLE_CAPTCHA"
            value = "true"
          }
          env {
            name  = "FORGEJO__service__CAPTCHA_TYPE"
            value = "cfturnstile"
          }
          env {
            name  = "FORGEJO__service__CF_TURNSTILE_SITEKEY"
            value = cloudflare_turnstile_widget.forgejo_signup.id
          }
          env {
            name = "FORGEJO__service__CF_TURNSTILE_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.forgejo_turnstile.metadata[0].name
                key  = "cf-turnstile-secret"
              }
            }
          }
          # Mandatory email confirmation: new accounts stay inactive until the
          # user clicks an emailed activation link (kills throwaway-email bots).
          env {
            name  = "FORGEJO__service__REGISTER_EMAIL_CONFIRM"
            value = "true"
          }
          # Mailer: reuse the noreply@viktorbarzin.me mailserver SASL account
          # (same as Authentik). MUST use the public host mail.viktorbarzin.me,
          # NOT mailserver.mailserver.svc — the mailserver serves the
          # *.viktorbarzin.me wildcard cert which does not cover the svc DNS
          # name, so STARTTLS verification would fail. mail.viktorbarzin.me
          # resolves in-cluster (10.0.20.1) and matches the cert. Password from
          # the forgejo-email ESO Secret (Vault secret/authentik ->
          # smtp_password; see email-secret.tf).
          env {
            name  = "FORGEJO__mailer__ENABLED"
            value = "true"
          }
          env {
            name  = "FORGEJO__mailer__PROTOCOL"
            value = "smtp+starttls"
          }
          env {
            name  = "FORGEJO__mailer__SMTP_ADDR"
            value = "mail.viktorbarzin.me"
          }
          env {
            name  = "FORGEJO__mailer__SMTP_PORT"
            value = "587"
          }
          env {
            name  = "FORGEJO__mailer__FROM"
            value = "Forgejo <noreply@viktorbarzin.me>"
          }
          env {
            name  = "FORGEJO__mailer__USER"
            value = "noreply@viktorbarzin.me"
          }
          env {
            name = "FORGEJO__mailer__PASSWD"
            value_from {
              secret_key_ref {
                name = "forgejo-email"
                key  = "PASSWD"
              }
            }
          }
          # Zero-click sign-up for GitHub (OAuth2): auto-create the local
          # account on first login (GitHub's username claim is valid). This is a
          # GLOBAL [oauth2_client] setting, so the Authentik OAuth2 source is kept
          # DISABLED (login_source.is_active=0, set out-of-band — sources are
          # DB-managed, not TF): Authentik's preferred_username is the user's email,
          # an invalid Forgejo username that 500'd auto-create. Re-enable Authentik
          # only after fixing its username claim. docs/runbooks/forgejo-open-signups.md
          env {
            name  = "FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION"
            value = "true"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # Bumped 1Gi -> 3Gi 2026-06-09, then 3Gi -> 4Gi 2026-06-13.
          # OOMKilled again (exit 137) at the 3Gi cap on 2026-06-13 (2
          # restarts; briefly took the git remote + OCI registry down and
          # spiked ingress TTFB/4xx). Steady-state ~2.2Gi but it spiked past
          # the 3Gi cap. 4Gi is the CEILING here: the forgejo namespace
          # tier-quota caps requests.memory at 4Gi and Guaranteed QoS means
          # request == limit, so a pod can request at most 4Gi. A first
          # attempt at 6Gi was REJECTED (FailedCreate: exceeded quota) and
          # left forgejo with 0 pods until reverted -- do NOT raise memory
          # past 4Gi without ALSO raising the tier-quota. The 6/9 OOM driver
          # (tripit buildkit registry pushes) is gone now that the Forgejo
          # registry was frozen + emptied 2026-06-13 (ADR-0002, ghcr), so the
          # remaining spike is git ops / integrity-probe catalog walk / a
          # possible leak; 4Gi should suffice. If it still OOMs, raise the
          # tier-quota and this limit together.
          # requests=limits (Guaranteed QoS) per the repo memory convention.
          resources {
            requests = {
              cpu    = "15m"
              memory = "4Gi"
            }
            limits = {
              memory = "4Gi"
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
