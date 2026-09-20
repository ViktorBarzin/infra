# browser-bridge — drive the Chrome a human is actually signed in to.
#
# An agent's CLI (`homelab browser bridge`) posts an action here; this server
# hands it to a Chrome extension over SSE; the extension runs it over the
# DevTools Protocol and posts the result back. Sibling of `homelab browser run`,
# which drives a headless Chrome in the cluster with nobody's session attached.
#
# Wire protocol, route table and credential kinds: browser-bridge/docs/protocol.md.
# What this stack runs, and the runbook: ./README.md.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# The shared secret Traefik stamps onto every forward-auth'd route as
# X-BB-Ingress. The server refuses to believe an X-authentik-username header
# without it, which is what stops a pod inside the cluster reaching the Service
# directly with a forged identity (protocol.md section 2.1). It has to be read
# at plan time because Traefik's headers middleware takes a literal string, so
# this is the one value the ESO-only pattern cannot carry. Same shape as
# stacks/ac. FIRST APPLY NEEDS THE VAULT PATH TO EXIST — see README step 1.
data "vault_kv_secret_v2" "browser_bridge" {
  mount = "secret"
  name  = "browser-bridge"

  # Name the missing field instead of letting the index below blow up. A
  # Terraform map indexed with a key it does not hold fails with "the given
  # key does not identify an element in this collection value", which says
  # nothing about which key, which path, or what to put there. The secret
  # exists for the CRX signing key too, so "the path is missing" and "the
  # field is missing" are different problems with the same symptom.
  lifecycle {
    postcondition {
      condition     = length(try(self.data["ingress_secret"], "")) >= 16
      error_message = <<-EOT
        secret/browser-bridge has no usable ingress_secret. The server refuses
        to start without it and Traefik's headers middleware takes a literal
        string, so it is read at plan time. At least 16 characters:
          vault kv patch secret/browser-bridge \
            ingress_secret="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-43)"
      EOT
    }
  }
}

locals {
  namespace = "browser-bridge"
  image     = "ghcr.io/viktorbarzin/browser-bridge"
  image_tag = "latest"
  host      = "browser-bridge"
  labels = {
    app = "browser-bridge"
  }
  # The public listener. The probe listener is 8081 and is deliberately absent
  # from the Service, so no ingress path can reach it.
  port       = 8080
  admin_port = 8081
}

# --- Namespace ---
#
# tier 4-aux takes the generated tier-defaults LimitRange (4Gi per container)
# and tier-quota ResourceQuota (2 CPU / 3Gi requests, 20 pods). NEITHER OPT-OUT
# LABEL IS SET: one small Go binary at 256Mi sits far inside both ceilings, and
# the container below carries explicit resources so the LimitRange defaults
# never apply to it.
#
# keel.sh/enrolled is also deliberately absent. Kyverno's default keel policy is
# `patch`, which only follows semver image tags, and CI publishes :<sha8> and
# :latest here. Woodpecker's `kubectl set image` is the real deploy path, so the
# label would buy nothing and cost four ignore_changes entries.
resource "kubernetes_namespace" "browser_bridge" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- Secrets ---
#
# Named keys rather than a whole-secret extract, so the Kubernetes key is
# exactly the environment variable the server reads and a typo in Vault shows up
# as a sync error instead of a missing variable.
#
# extension_id is not a secret. It lives here because it is not known until the
# extension is packed and its signing key derives the id, and this way setting
# it is `vault kv patch` plus a Reloader-driven restart rather than a Terraform
# change.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "browser-bridge-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "browser-bridge-secrets"
      }
      data = [
        {
          secretKey = "BB_INGRESS_SECRET"
          remoteRef = {
            key      = "browser-bridge"
            property = "ingress_secret"
          }
        },
        {
          secretKey = "BB_EXTENSION_ID"
          remoteRef = {
            key      = "browser-bridge"
            property = "extension_id"
          }
        },
        {
          # The one bearer that mints a CLI token with no human at a
          # keyboard. t3-provision-users.sh on the devvm reads the same value
          # from Vault and calls POST /v1/provision/tokens with it, per OS
          # user on the roster. The admin route cannot serve that: it sits
          # behind forward-auth, and the Authentik outpost answers a request
          # with no SSO cookie with a 302 to a login page.
          secretKey = "BB_PROVISION_TOKEN"
          remoteRef = {
            key      = "browser-bridge"
            property = "provision_token"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.browser_bridge]
}

# --- Server ---

resource "kubernetes_deployment" "browser_bridge" {
  depends_on = [kubernetes_manifest.external_secret]

  metadata {
    name      = "browser-bridge"
    namespace = kubernetes_namespace.browser_bridge.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      # Both values are read once at boot: the ingress secret builds the
      # authenticator and a short or empty one is a boot failure, and the
      # extension id is what /crx/update.xml advertises. Rotating either in
      # Vault has to bounce the pod or the old value keeps serving.
      "secret.reloader.stakater.com/reload" = "browser-bridge-secrets"
    }
  }

  spec {
    # ONE REPLICA, AND IT IS A CONSTRAINT RATHER THAN A DEFAULT. Result blobs
    # (screenshots, page text, response bodies) live in the server process's
    # memory, because the protocol rules out carrying them over SSE or through
    # Redis. A second replica would hand the CLI a blob id the other pod cannot
    # serve. Blobs in object storage, or a sticky route, come first.
    # protocol.md section 17, open question 4.
    replicas = 1

    strategy {
      # Recreate, not RollingUpdate: two pods alive at once means the SSE
      # stream and the blobs it produced can land on different replicas for
      # the length of the roll.
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
        # PRIVATE ghcr image — the secret is cloned into this namespace by the
        # Kyverno sync-ghcr-credentials allowlist policy. The matching entry in
        # stacks/kyverno/modules/kyverno/ghcr-credentials.tf lands in the same
        # change; without it the first deploy sits in ImagePullBackOff.
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        container {
          name = "server"
          # CI (GHA -> ghcr) overwrites this to :<sha8> via `kubectl set image`,
          # and the tag is in ignore_changes below so the SHA survives the next
          # apply. Placeholder until the deploy pipeline has run once.
          image = "${local.image}:${local.image_tag}"

          port {
            name           = "http"
            container_port = local.port
          }
          port {
            name           = "admin"
            container_port = local.admin_port
          }

          env {
            name  = "BB_ADDR"
            value = ":${local.port}"
          }
          env {
            name  = "BB_ADMIN_ADDR"
            value = ":${local.admin_port}"
          }
          env {
            # The shared instance. No password: stacks/redis sets
            # `protected-mode no` and no `requirepass`, and a NetworkPolicy
            # allowlist is what gates it, so BB_REDIS_PASSWORD stays unset.
            # This namespace has to be on that allowlist — same change, see
            # stacks/redis/modules/redis/main.tf.
            name  = "BB_REDIS_ADDR"
            value = "redis-master.redis.svc.cluster.local:6379"
          }
          env {
            name  = "BB_BASE_URL"
            value = "https://${local.host}.viktorbarzin.me"
          }
          env {
            # Matches allowed_groups on the ingress below. This one gates
            # POST /v1/admin/tokens, which mints the per-OS-user CLI tokens.
            name  = "BB_ADMIN_GROUP"
            value = "Home Server Admins"
          }
          env {
            # X-Real-Ip, not the server's CF-Connecting-IP default. Traefik's
            # real-ip plugin trusts the pod CIDR 10.10.0.0/16, so for traffic
            # off the cloudflared tunnel it rewrites X-Real-Ip from the
            # forwarded client address, and for a caller that reaches Traefik
            # directly it writes the TCP peer. Either way the client cannot
            # choose it. CF-Connecting-IP only exists on traffic that crossed
            # the edge, and split DNS means the devvm and every WireGuard
            # client never do. All three routers below run real-ip: the main
            # and API ones inside the shared rate-limit chain, /crx explicitly.
            name  = "BB_CLIENT_IP_HEADER"
            value = "X-Real-Ip"
          }
          env {
            name = "BB_INGRESS_SECRET"
            value_from {
              secret_key_ref {
                name = "browser-bridge-secrets"
                key  = "BB_INGRESS_SECRET"
              }
            }
          }
          env {
            name = "BB_EXTENSION_ID"
            value_from {
              secret_key_ref {
                name = "browser-bridge-secrets"
                key  = "BB_EXTENSION_ID"
              }
            }
          }
          env {
            # Turns POST /v1/provision/tokens on. Empty would turn it off
            # rather than leave it open, and the server refuses a token
            # shorter than 32 characters at boot.
            name = "BB_PROVISION_TOKEN"
            value_from {
              secret_key_ref {
                name = "browser-bridge-secrets"
                key  = "BB_PROVISION_TOKEN"
              }
            }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.admin_port
            }
            initial_delay_seconds = 5
            period_seconds        = 20
            timeout_seconds       = 3
          }

          readiness_probe {
            # /readyz reports the Redis round trip. A Redis that is down keeps
            # the pod out of the Service rather than killing it, which is why
            # this is not also the liveness path.
            http_get {
              path = "/readyz"
              port = local.admin_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 3
          }

          resources {
            # requests = limits per the repo memory rule; no CPU limit (CFS
            # throttling). 256Mi rather than the 128Mi a Go SSE fan-out would
            # otherwise want: result blobs are held in process memory and the
            # protocol caps one screenshot at 16MB, so a handful in flight is
            # the sizing case. Right-size with krr once there is a week of
            # Prometheus data.
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # CI pipeline owns the image tag (kubectl set image from GHA/Woodpecker).
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      # RELOADER_LIFECYCLE_V1: Reloader stamps this on every secret-triggered restart.
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
}

resource "kubernetes_service" "browser_bridge" {
  metadata {
    name      = "browser-bridge"
    namespace = kubernetes_namespace.browser_bridge.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = local.port
      target_port = local.port
      protocol    = "TCP"
    }
    # 8081 is absent on purpose. The probes are dialled by kubelet straight at
    # the pod, so the admin listener needs no Service, and leaving it out means
    # no ingress path can be pointed at it by accident.
  }
}

# --- Traefik middlewares owned by this stack ---

# Proof that a request came through the ingress. customRequestHeaders SETS the
# header, overwriting any client copy, so a caller cannot supply their own.
# Attached ONLY to the forward-auth'd routers: on a router with no forward-auth
# this header would let a client pair a forged X-authentik-username with a valid
# ingress proof, which is the exact hole it exists to close.
resource "kubernetes_manifest" "ingress_secret_header" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ingress-secret"
      namespace = kubernetes_namespace.browser_bridge.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-BB-Ingress" = data.vault_kv_secret_v2.browser_bridge.data["ingress_secret"]
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.browser_bridge]
}

# The /crx limiter. Chrome checks for an extension update roughly every 5 hours,
# so 6 a minute with a burst of 12 leaves room for a manual chrome://extensions
# "Update" click, a reinstall and the install one-liner, and nothing else.
# Keyed on X-Real-Ip, which traefik-real-ip writes from the TCP peer ahead of it
# in the chain; without that ordering the key is empty and every caller shares
# one bucket.
resource "kubernetes_manifest" "crx_rate_limit" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "crx-rate-limit"
      namespace = kubernetes_namespace.browser_bridge.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 6
        period  = "1m"
        burst   = 12
        sourceCriterion = {
          requestHeaderName = "X-Real-Ip"
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.browser_bridge]
}

# --- Ingress ---
#
# THREE ROUTER GROUPS ON ONE HOST, because the three kinds of client carry three
# different credentials and Authentik can only vouch for one of them.
#
#   /, /v1/enrol, /v1/ui, /v1/admin   forward-auth + X-BB-Ingress   a human
#   /v1                               the server's own credential   CLI, extension
#   /crx, /install                    none                          Chrome's updater
#
# Traefik picks the longest matching prefix, so /v1/enrol reaches the human
# group while /v1/actions falls through to the API group.
#
# The brief asked for forward-auth on everything except the two /crx artifacts.
# That is not reachable as written: the Authentik outpost answers a request with
# no session with a 302 to the login page, so the CLI's bearer token and the
# extension's browser key would both be redirected into HTML. The split above
# keeps forward-auth on every route that reads a human identity, and leaves the
# routes whose credentials are already bearer-grade to the server. The four
# operations the web UI performs moved to /v1/ui to land on the right side of
# it, which cost this stack nothing. See README, "The routes that moved".

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"

  auth           = "required"
  allowed_groups = ["Home Server Admins"]
  dns_type       = "proxied"

  namespace       = kubernetes_namespace.browser_bridge.metadata[0].name
  name            = "browser-bridge"
  service_name    = kubernetes_service.browser_bridge.metadata[0].name
  port            = local.port
  tls_secret_name = var.tls_secret_name

  # / is the dashboard, the enrolment page and the settings page. The three /v1
  # prefixes are the API calls those pages make with the human's SSO cookie, so
  # they need the same forward-auth hop to turn that cookie into a header.
  ingress_path = ["/", "/v1/enrol", "/v1/ui", "/v1/admin"]

  # Stamp the ingress proof. extra_middlewares are appended last, so this runs
  # after forward-auth has written the identity header it vouches for.
  extra_middlewares = [
    "browser-bridge-ingress-secret@kubernetescrd",
  ]

  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Browser Bridge"
    "gethomepage.dev/description" = "Drive the browser a human is signed in to"
    "gethomepage.dev/icon"        = "chromium.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}

module "ingress_api" {
  source = "../../modules/kubernetes/ingress_factory"

  # auth = "app": every /v1 route here carries its own bearer-grade credential,
  # checked against a stored hash in constant time — a CLI token, the
  # extension's browserId plus browserKey, or a one-time pair code. Authentik
  # cannot gate them: the outpost 302s a request that has no SSO cookie, which
  # is every request an agent or the extension makes. strip-auth-headers below
  # removes any client-injected X-authentik-*, and the server ignores identity
  # headers entirely unless the request also carries the ingress secret, which
  # this router does not stamp.
  auth = "app"

  # Machine API. ai-bot-block is a forwardAuth hop to bot-block-proxy and
  # anti-ai-headers is for crawlable content; neither belongs in front of an
  # agent's action queue or the extension's SSE stream.
  anti_ai_scraping = false

  dns_type         = "none" # module.ingress owns the DNS record for this host
  homepage_enabled = false  # path carve-out, not a second dashboard tile

  namespace       = kubernetes_namespace.browser_bridge.metadata[0].name
  name            = "browser-bridge-api"
  host            = local.host
  service_name    = kubernetes_service.browser_bridge.metadata[0].name
  port            = local.port
  tls_secret_name = var.tls_secret_name
  ingress_path    = ["/v1"]

  # Keeps the shared traefik-rate-limit chain (real-ip then 10/s, 50 burst, per
  # client address). An agent driving a browser is one action at a time behind a
  # queue, and the SSE stream is a single long-lived request, so the shared
  # ceiling is the right starting point. Raise it here first if agents see 429s.
  extra_middlewares = [
    "traefik-strip-auth-headers@kubernetescrd",
  ]
}

module "ingress_crx" {
  source = "../../modules/kubernetes/ingress_factory"

  # auth = "none": Chrome's extension updater sends no cookie and cannot run an
  # OIDC flow, and `curl -fsSL .../install | sh` cannot either, so forward-auth
  # would break both installing and updating. Four static artifacts are served
  # here and no user data: the update manifest, the signed CRX, the installer
  # script, and a 302 from /install into that prefix. No handler under this
  # prefix reads an identity, and strip-auth-headers below removes any inbound
  # X-authentik-* so a future one cannot start.
  auth = "none"

  # Two static files and a redirect. ai-bot-block would put a forwardAuth hop in
  # front of the one path that must answer Chrome's updater unconditionally.
  anti_ai_scraping = false

  dns_type         = "none" # module.ingress owns the DNS record for this host
  homepage_enabled = false  # path carve-out, not a second dashboard tile

  namespace       = kubernetes_namespace.browser_bridge.metadata[0].name
  name            = "browser-bridge-crx"
  host            = local.host
  service_name    = kubernetes_service.browser_bridge.metadata[0].name
  port            = local.port
  tls_secret_name = var.tls_secret_name
  ingress_path    = ["/crx", "/install"]

  # real-ip FIRST so the limiter keys on an address the caller cannot choose,
  # then strip-auth-headers, then the tight per-path limiter. extra_middlewares
  # are appended in order and last, which is what keeps real-ip ahead.
  skip_default_rate_limit = true
  extra_middlewares = [
    "traefik-real-ip@kubernetescrd",
    "traefik-strip-auth-headers@kubernetescrd",
    "browser-bridge-crx-rate-limit@kubernetescrd",
  ]
}

# --- Cloudflare ---
#
# No cloudflare_ruleset here, and that is a decision rather than an omission.
#
# The bot skip the brief asks for cannot be built on this plan. Cloudflare's own
# documentation: "You cannot bypass or skip Bot Fight Mode using WAF custom
# rules or Page Rules." Exceptions need Super Bot Fight Mode, which starts at
# Pro. This already cost the repo one revert (infra#91, Bot Fight Mode 403ing a
# Forgejo package upload from a GitHub Actions runner).
#
# The rate limit lives in Traefik instead, above. Cloudflare's free plan allows
# ONE rate limiting rule for the whole zone, and spending it here would buy less
# than the Traefik limiter does: split DNS means the devvm and every WireGuard
# client reach Traefik without a Cloudflare hop, so an edge-only limit would
# never see them.
#
# Both calls, the measurement behind them and the paste-ready HCL if the trade
# ever changes: ./README.md, "Cloudflare".
