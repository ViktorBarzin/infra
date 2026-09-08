# === pages-publish — pages.viktorbarzin.me publishing API ===
#
# Lets any devvm user publish markdown to pages.viktorbarzin.me from a locked
# account. The client POSTs raw markdown + a bearer token; the service resolves
# the publishing user FROM THE TOKEN ONLY (never the request body), renders it
# via the monorepo's render.py into pages/<user>/ (or pages/shared/), and
# commits + pushes to the monorepo. The learn pod git-syncs and serves the page
# ~30s later. Bearer-token API → auth = "none" (Authentik would break clients).
#
# App source + image: pages-publish/ → ghcr.io/viktorbarzin/pages-publish:latest
# (GHA, ADR-0002). Keel polls the :latest digest and rolls this deployment.
#
# Vault secret/pages-publish carries:
#   - api_keys   : JSON {user: token} map → env PAGES_API_KEYS. The user KEYS
#                  MUST match the learn Caddyfile's per-user dir names
#                  (pages/wizard, pages/emo) — i.e. {"wizard": "...", "emo": "..."}
#                  — NOT the Authentik usernames, or served pages 404.
#   - deploy_key : SSH private key with READ+WRITE on ViktorBarzin/monorepo,
#                  mounted 0400 at /etc/pages-deploy/id_ed25519 (never env).
#
# NOTE (team lead): this stack dir also needs the standard sibling scaffolding
# copied in — tiers.tf, providers.tf, backend.tf, cloudflare_provider.tf — and a
# terragrunt.hcl (include "root" + deps platform, vault, external-secrets;
# mirror stacks/claude-agent-service/terragrunt.hcl).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "pages-publish"
  image     = "ghcr.io/viktorbarzin/pages-publish"
  image_tag = "latest"
  labels    = { app = "pages-publish" }
}

# --- Namespace ---

resource "kubernetes_namespace" "pages_publish" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- Secrets: PAGES_API_KEYS (env) + deploy key (mounted 0400 file) ---

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "pages-publish-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "pages-publish-secrets"
      }
      data = [
        {
          secretKey = "PAGES_API_KEYS"
          remoteRef = {
            key      = "pages-publish"
            property = "api_keys"
          }
        },
        {
          # SSH deploy key (read+write ViktorBarzin/monorepo). Projected as a
          # FILE at /etc/pages-deploy/id_ed25519 (mode 0400) below — deliberately
          # NOT surfaced via env_from, so the private key never lands in the
          # process environment (/proc/<pid>/environ).
          secretKey = "deploy_key"
          remoteRef = {
            key      = "pages-publish"
            property = "deploy_key"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.pages_publish]
}

# --- Deployment ---

resource "kubernetes_deployment" "pages_publish" {
  metadata {
    name      = "pages-publish"
    namespace = local.namespace
    labels    = local.labels
    # Own single-tag :latest image (ADR-0002) — Keel polls the digest and rolls
    # the deployment. force+poll is safe here: this is our own single-tag repo,
    # not the multi-tag-upstream hazard the CLAUDE.md force-policy warning is about.
    #
    # `match-tag` is REQUIRED for that to actually happen, and its absence is why
    # this deployment silently stopped auto-deploying (found 2026-08-17: ghcr
    # :latest had moved to a new digest and the pod still ran the old one across
    # ~3 poll windows). Without it Keel registers only a "watch repository tags"
    # job — it scans for NEW TAGS, which never appear in a repo that only ever
    # publishes `:latest` + a commit SHA — and logs `digest=` empty. With it Keel
    # registers a "watch tag digest" job and rolls on a digest change under the
    # same tag string. `k8s-portal` and `interview-prep-app` declare it for
    # exactly this reason; they roll, this did not.
    #
    # It is stripped fleet-wide by the Kyverno add-keel-annotations rule after
    # the 2026-06-01 incident (post-mortems/2026-06-01-keel-match-tag-image-swap.md),
    # where `force + match-tag` cross-assigned container images and took the blog
    # down ~6 days. That hazard needs a MULTI-IMAGE pod sharing a floating tag —
    # this pod runs one container, so there is no sibling image to swap with.
    # Verified with `kubectl annotate --dry-run=server` that admission keeps it.
    #
    # Deliberately NOT in lifecycle.ignore_changes below: if a recreate ever loses
    # it to admission, an apply must put it back and the nightly drift report must
    # be able to see it missing. Silent loss here means silent no-deploys.
    annotations = {
      "keel.sh/policy"       = "force"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = "@every 5m"
      "keel.sh/match-tag"    = "true"
    }
  }

  spec {
    replicas = 1
    # Single writer: /repo is a per-pod emptyDir clone, so one replica avoids
    # concurrent clone/push races across pods. In-process lock serializes
    # publishes within the pod.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        # Non-root. fsGroup 10001 makes the emptyDir /repo writable and the
        # 0400 deploy-key secret group-readable by this uid; the key stays
        # root-owned so OpenSSH doesn't reject it as "too open".
        security_context {
          run_as_user  = 10001
          run_as_group = 10001
          fs_group     = 10001
        }

        # Private ghcr image → pull via the Kyverno-synced ghcr-credentials.
        # This ALSO lets Keel read these creds to poll the private :latest digest
        # and roll new builds — without it Keel logs an empty digest and never
        # rolls (and the pod would depend on fragile node-level ghcr creds).
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        container {
          name  = "pages-publish"
          image = "${local.image}:${local.image_tag}"

          port {
            container_port = 8080
          }

          # PAGES_API_KEYS by secret_key_ref (not env_from) so ONLY the api-keys
          # value becomes an env var — the deploy key is a file mount, not env.
          env {
            name = "PAGES_API_KEYS"
            value_from {
              secret_key_ref {
                name = "pages-publish-secrets"
                key  = "PAGES_API_KEYS"
              }
            }
          }
          env {
            name  = "REPO_DIR"
            value = "/repo"
          }
          env {
            name  = "DEPLOY_KEY_PATH"
            value = "/etc/pages-deploy/id_ed25519"
          }
          # If the plans/->pages/ renderer migration is not yet live at deploy,
          # uncomment these to target the current on-disk renderer:
          # env {
          #   name  = "RENDER_SCRIPT"
          #   value = "/repo/plans/tools/render.py"
          # }
          # env {
          #   name  = "RENDER_DIR_FLAG"
          #   value = "--plans-dir"
          # }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "repo"
            mount_path = "/repo"
          }
          volume_mount {
            name       = "deploy-key"
            mount_path = "/etc/pages-deploy"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "repo"
          empty_dir {}
        }
        volume {
          name = "deploy-key"
          secret {
            secret_name = "pages-publish-secrets"
            # Project ONLY the deploy_key value → id_ed25519; PAGES_API_KEYS is
            # not mounted (it's an env var). 0400 so ssh accepts the key.
            items {
              key  = "deploy_key"
              path = "id_ed25519"
            }
            default_mode = "0400"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages the :latest digest
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      metadata[0].labels["tier"],                                         # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }

  depends_on = [kubernetes_manifest.external_secret]
}

# --- Service ---

resource "kubernetes_service" "pages_publish" {
  metadata {
    name      = "pages-publish"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# --- Ingress: pages-publish.viktorbarzin.me ---

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": bearer-token API, Authentik would break programmatic clients
  auth      = "none"
  dns_type  = "proxied"
  namespace = local.namespace
  name      = "pages-publish"
  # Route to the Service's 8080 (svc-builder put it on 8080, not the
  # ingress_factory default 80) — otherwise Traefik can't resolve the backend
  # port and POST /publish returns a stray 405 while GET falls through.
  port            = 8080
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/description" = "Publishing API behind pages.viktorbarzin.me"
  }
}
