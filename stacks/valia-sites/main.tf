# Valia sites (ADR-0018): small static sites authored by Valia in Google Drive,
# served OFF-INFRA on Cloudflare Pages, mirrored by the in-cluster CronJob below
# every 10 minutes. Registering a new site = one entry in local.sites (plus
# Valia sharing the folder with vbarzin@gmail.com). Full runbook:
# docs/runbooks/valia-sites.md
#
# Per site this stack fans out:
#   - cloudflare_pages_project + custom domain <name>.viktorbarzin.me
#   - public proxied CNAME <name> -> <project>.pages.dev   (manage_dns gate)
#   - internal split-horizon CNAME via ConfigMap valia-sites-dns consumed by
#     the technitium-ingress-dns-sync script (declarative: add/update/REMOVE)
#   - a slot in the shared sync CronJob (rclone mirror -> wrangler deploy)

locals {
  cloudflare_account_id = "02e035473cfc4834fb10c5d35470d8b4" # vbarzin@gmail.com's account (not a secret)

  # THE site registry. Keys are the public subdomain (English, Viktor picks —
  # CONTEXT.md "Valia site"). folder_id = the Drive folder Valia shared (the
  # Content folder); src_path = subfolder holding servable files ("" = root);
  # entry_file = what / must serve (staged as index.html at deploy time).
  # manage_dns = false parks a site's public CNAME + internal record while the
  # name is still owned elsewhere (used for the stem95su ingress cutover).
  sites = {
    bridge = {
      folder_id  = "1YWwAtSTsJD9HOzckGRIFXigWqCgYSGEa" # "мост" — ОбУ „Отец Паисий“
      src_path   = ""
      entry_file = "index.html"
      manage_dns = true
    }
    stem95su = {
      folder_id  = "1cmOI2jRyBJdnrVPgbr4kx2cx_4DY6pm_" # "claude" — 95. СУ STEM board
      src_path   = "stem claude/files"
      entry_file = "stem_board.html"
      manage_dns = false # flipped true in the cutover commit (record still owned by stacks/stem95su ingress_factory)
    }
  }

  dns_managed_sites = { for k, v in local.sites : k => v if v.manage_dns }
}

# ---------------------------------------------------------------------------
# Cloudflare Pages: project + custom domain per site
# ---------------------------------------------------------------------------

resource "cloudflare_pages_project" "site" {
  for_each          = local.sites
  account_id        = local.cloudflare_account_id
  name              = each.key
  production_branch = "main"
}

# bridge was created by hand (wrangler) on 2026-07-03 — adopt, don't recreate.
import {
  to = cloudflare_pages_project.site["bridge"]
  id = "02e035473cfc4834fb10c5d35470d8b4/bridge"
}

resource "cloudflare_pages_domain" "site" {
  for_each     = local.sites
  account_id   = local.cloudflare_account_id
  project_name = cloudflare_pages_project.site[each.key].name
  domain       = "${each.key}.viktorbarzin.me"
}

import {
  to = cloudflare_pages_domain.site["bridge"]
  id = "02e035473cfc4834fb10c5d35470d8b4/bridge/bridge.viktorbarzin.me"
}

# Public proxied CNAME. Gated on manage_dns: a site whose name is still served
# by an in-cluster ingress keeps its ingress_factory record until cutover
# (two records can't share one name).
resource "cloudflare_record" "site" {
  for_each = local.dns_managed_sites
  zone_id  = var.cloudflare_zone_id
  name     = each.key
  content  = cloudflare_pages_project.site[each.key].subdomain
  type     = "CNAME"
  proxied  = true
  ttl      = 1
}

# bridge's record predates this stack (created 2026-07-03 in stacks/cloudflared,
# handed off via removed{} there) — adopt by id.
import {
  to = cloudflare_record.site["bridge"]
  id = "fd2c5dd4efe8fe38958944e74d0ced6d/ff4fb6f4900744d4b22de50d3fdd219b"
}

# ---------------------------------------------------------------------------
# Internal split-horizon DNS feed (docs/architecture/dns.md "superset rule"):
# the technitium-ingress-dns-sync script reads this CM and reconciles internal
# CNAMEs for every entry — including deleting stale *.pages.dev records when
# an entry disappears (site retired/renamed).
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "valia_sites_dns" {
  metadata {
    name      = "valia-sites-dns"
    namespace = "technitium"
    labels    = { "app.kubernetes.io/managed-by" = "valia-sites" }
  }
  data = { for k, v in local.dns_managed_sites : k => cloudflare_pages_project.site[k].subdomain }
}

# ---------------------------------------------------------------------------
# The shared sync CronJob
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "valia_sites" {
  metadata {
    name = "valia-sites"
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

# Secrets: shared drive.readonly rclone conf + the SCOPED CF Pages token
# (Pages Read/Write only — the Global API Key never enters a pod).
resource "kubernetes_manifest" "sync_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "valia-sites-sync"
      namespace = kubernetes_namespace.valia_sites.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = { name = "valia-sites-sync" }
      data = [
        {
          secretKey = "rclone.conf"
          remoteRef = { key = "valia-sites", property = "rclone_conf" }
        },
        {
          secretKey = "CLOUDFLARE_API_TOKEN"
          remoteRef = { key = "valia-sites", property = "cloudflare_pages_token" }
        },
        {
          secretKey = "CLOUDFLARE_ACCOUNT_ID"
          remoteRef = { key = "valia-sites", property = "account_id" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.valia_sites]
}

# Site registry rendered for the job (folder ids aren't secrets).
resource "kubernetes_config_map" "sync_config" {
  metadata {
    name      = "valia-sites-config"
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
  }
  data = {
    "sites.json" = jsonencode(local.sites)
  }
}

# Last-deployed manifest hash per site — written by the job (merge-patch), so
# TF must never fight it over data.
resource "kubernetes_config_map" "sync_state" {
  metadata {
    name      = "valia-sites-state"
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
  }
  data = {}
  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_service_account" "sync" {
  metadata {
    name      = "valia-sites-sync"
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
  }
}

resource "kubernetes_role" "sync_state" {
  metadata {
    name      = "valia-sites-sync-state"
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["valia-sites-state"]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "sync_state" {
  metadata {
    name      = "valia-sites-sync-state"
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.sync_state.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.sync.metadata[0].name
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "sync" {
  metadata {
    name      = "valia-sites-sync"
    namespace = kubernetes_namespace.valia_sites.metadata[0].name
    labels    = { app = "valia-sites", component = "sync" }
  }
  spec {
    schedule                      = "*/10 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 2
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata { labels = { app = "valia-sites", component = "sync" } }
          spec {
            restart_policy       = "OnFailure"
            service_account_name = kubernetes_service_account.sync.metadata[0].name
            container {
              name  = "sync"
              image = "ghcr.io/viktorbarzin/valia-sites-sync:latest"
              # Guards mirror stem95su's proven set: hard-fail on Drive
              # list/auth errors (visible as a failed Job — the chosen
              # visibility, ADR-0018), skip quietly when a folder is empty or
              # missing its entry file (never wipe a live site), capped
              # deletes. Deploy ONLY on remote-manifest change: CF Pages caps
              # monthly deployments on the free tier, so 144 no-op
              # deploys/day is not an option.
              command = ["/bin/sh", "-c", <<-EOT
                set -u
                cp /config/rclone.conf /tmp/rc.conf
                APISERVER="https://kubernetes.default.svc"
                SA=/var/run/secrets/kubernetes.io/serviceaccount
                KTOKEN=$$(cat $$SA/token); NS=$$(cat $$SA/namespace)
                STATE_URL="$$APISERVER/api/v1/namespaces/$$NS/configmaps/valia-sites-state"
                FAILED=0
                for SITE in $$(jq -r 'keys[]' /sites/sites.json); do
                  FOLDER=$$(jq -r --arg s "$$SITE" '.[$$s].folder_id' /sites/sites.json)
                  SRC_PATH=$$(jq -r --arg s "$$SITE" '.[$$s].src_path' /sites/sites.json)
                  ENTRY=$$(jq -r --arg s "$$SITE" '.[$$s].entry_file' /sites/sites.json)
                  RC="rclone --config /tmp/rc.conf --drive-root-folder-id=$$FOLDER --drive-skip-gdocs"
                  # 1. Remote manifest (path+size+hash) — metadata only, no download.
                  MANIFEST=$$($$RC lsf "gdrive:$$SRC_PATH" -R --files-only --format phs 2>/tmp/lsf.err) || {
                    echo "FATAL [$$SITE]: Drive list failed (auth/network):"; cat /tmp/lsf.err; FAILED=1; continue; }
                  N=$$(printf '%s\n' "$$MANIFEST" | grep -c . || true)
                  if [ "$$N" -lt 1 ] || ! printf '%s\n' "$$MANIFEST" | cut -d';' -f1 | grep -qx "$$ENTRY"; then
                    echo "GUARD [$$SITE]: N=$$N / $$ENTRY missing -- skipping, site untouched"; continue
                  fi
                  # Cloudflare Pages hard-caps files at 25 MB — deploying
                  # without an oversize file would silently break the pages
                  # that reference it, so skip the whole site instead (last
                  # deployed content keeps serving) and say so loudly.
                  OVERSIZE=$$(printf '%s\n' "$$MANIFEST" | awk -F';' '$$3 > 26214400 {print $$1" ("$$3" B)"}')
                  if [ -n "$$OVERSIZE" ]; then
                    echo "GUARD [$$SITE]: file(s) exceed the 25MB Pages limit -- skipping, site untouched:"; echo "$$OVERSIZE"; continue
                  fi
                  HASH=$$(printf '%s' "$$MANIFEST" | sha256sum | cut -d' ' -f1)
                  LAST=$$(curl -sf --cacert $$SA/ca.crt -H "Authorization: Bearer $$KTOKEN" "$$STATE_URL" | jq -r --arg s "$$SITE" '.data[$$s] // ""')
                  if [ "$$HASH" = "$$LAST" ]; then echo "OK [$$SITE]: unchanged"; continue; fi
                  # 2. Content changed — pull and deploy.
                  $$RC sync "gdrive:$$SRC_PATH" "/work/$$SITE" --exclude ".DS_Store" --fast-list --transfers 4 --max-delete 25 -v || {
                    echo "FATAL [$$SITE]: rclone sync failed"; FAILED=1; continue; }
                  if [ "$$ENTRY" != "index.html" ]; then
                    cp "/work/$$SITE/$$ENTRY" "/work/$$SITE/index.html"
                  fi
                  wrangler pages deploy "/work/$$SITE" --project-name="$$SITE" --branch=main --commit-dirty=true || {
                    echo "FATAL [$$SITE]: wrangler deploy failed"; FAILED=1; continue; }
                  curl -sf --cacert $$SA/ca.crt -H "Authorization: Bearer $$KTOKEN" \
                    -X PATCH -H "Content-Type: application/merge-patch+json" \
                    -d "{\"data\":{\"$$SITE\":\"$$HASH\"}}" "$$STATE_URL" > /dev/null || {
                    echo "WARN [$$SITE]: state patch failed (will redeploy next run)"; FAILED=1; }
                  echo "DEPLOYED [$$SITE]: $$HASH"
                done
                exit $$FAILED
              EOT
              ]
              env {
                name = "CLOUDFLARE_API_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "valia-sites-sync"
                    key  = "CLOUDFLARE_API_TOKEN"
                  }
                }
              }
              env {
                name = "CLOUDFLARE_ACCOUNT_ID"
                value_from {
                  secret_key_ref {
                    name = "valia-sites-sync"
                    key  = "CLOUDFLARE_ACCOUNT_ID"
                  }
                }
              }
              resources {
                requests = { cpu = "25m", memory = "128Mi" }
                limits   = { memory = "512Mi" }
              }
              volume_mount {
                name       = "rclone-config"
                mount_path = "/config"
                read_only  = true
              }
              volume_mount {
                name       = "sites-config"
                mount_path = "/sites"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
            }
            volume {
              name = "rclone-config"
              secret {
                secret_name = "valia-sites-sync"
                items {
                  key  = "rclone.conf"
                  path = "rclone.conf"
                }
              }
            }
            volume {
              name = "sites-config"
              config_map { name = kubernetes_config_map.sync_config.metadata[0].name }
            }
            volume {
              name = "work"
              empty_dir {}
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_manifest.sync_external_secret]
}
