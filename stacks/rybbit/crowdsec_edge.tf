# =============================================================================
# CrowdSec edge enforcement for Cloudflare-PROXIED hosts — control plane
# =============================================================================
# Proxied hosts terminate at the Cloudflare edge, so the in-cluster CrowdSec
# bouncer (which keys on the real client IP seen by Traefik) never gets to
# decide on them. To enforce CrowdSec bans/captchas on proxied traffic we push
# the decision INTO the Cloudflare edge as a SINGLE account-level IP List + one
# zone-scoped WAF custom rule:
#
#   * ONE account IP List — `crowdsec_ban` — holds BOTH the banned AND captcha'd
#     source IPs (empty in TF; populated at runtime). The CF account hard-limits
#     to ONE Rules List, so captcha decisions are downgraded to block at the
#     edge and folded into this same list (block-only enforcement).
#   * A zone-scoped WAF ruleset in the http_request_firewall_custom phase
#     blocks `(ip.src in $crowdsec_ban)`. Because it's a ZONE rule it enforces
#     across ALL proxied hosts in the zone (~135), not just the handful a
#     Worker would route. (The previous Worker+KV design only covered the ~27
#     hosts the rybbit Worker routed; the analytics Worker in worker/ is
#     unrelated and stays.)
#
# This file is the CONTROL PLANE that keeps that list in sync with LAPI:
#   1. the single empty IP List (list ITEMS are owned by the CronJob at runtime,
#      NOT by Terraform — see the lifecycle ignore_changes on `item`),
#   2. a LEAST-PRIVILEGE Cloudflare API token (account Filter-Lists edit only,
#      scoped to this account) the sync job authenticates with,
#   3. a CronJob running lapi_kv_sync.py every 2 min to full-reconcile LAPI
#      decisions (ban + captcha) into the one list (mirrors
#      monitoring/alert_digest.tf: stock python:3.12-alpine + pure-stdlib script
#      from a ConfigMap, no pip/apk at runtime).
#
# Cloudflare provider is pinned v4.52.7 (~> 4) — v4 schema is used throughout
# (v5 differs greatly: policy is a block here not a `policies = [...]` list;
# resources is a map not a jsonencode'd string; ruleset `rules` is a repeatable
# block; list items use `item { value { ip = ... } }`; permission groups are
# looked up via data.cloudflare_api_token_permission_groups, not a v5 *_list
# data source). context7 only indexes v5, so the v4 arguments below were
# verified against the v4.52.7 provider docs (github tag v4.52.7) — items
# FLAGGED ### VERIFY for tg-plan are noted inline.
# =============================================================================

data "cloudflare_accounts" "main" {}

locals {
  cf_account_id = data.cloudflare_accounts.main.accounts[0].id
}

# -----------------------------------------------------------------------------
# IP List — empty shell. The CronJob owns the items at runtime via the CF
# Rules-Lists API; TF must NOT manage items or every 2-min sync would fight the
# next `terragrunt apply` (apply would try to delete the runtime items).
#
# ### VERIFY (v4.52.7): cloudflare_list args account_id/name/kind/description;
#     kind="ip" is one of {ip, redirect, hostname, asn}. The optional items
#     block is named `item` (singular, Block Set) with `item { value { ip=... }
#     comment=... }`. We declare NO `item` blocks (empty list) and
#     ignore_changes=[item] so runtime items don't show as drift.
#     NOTE: list `name` must match /^[a-zA-Z0-9_]+$/ (underscores ok, no dashes)
#     — hence crowdsec_ban (underscore, not dash).
# -----------------------------------------------------------------------------
resource "cloudflare_list" "crowdsec_ban" {
  account_id  = local.cf_account_id
  name        = "crowdsec_ban"
  kind        = "ip"
  description = "CrowdSec ban decisions (synced from LAPI)"

  lifecycle {
    # The crowdsec-cf-sync CronJob adds/removes items at runtime; TF owns only
    # the empty list shell. Without this, every apply would delete live bans.
    ignore_changes = [item]
  }
}

# -----------------------------------------------------------------------------
# Zone-scoped WAF custom ruleset — the actual enforcement. One ruleset, one
# block rule, applied to EVERY proxied host in the zone.
#
# ### VERIFY (v4.52.7): cloudflare_ruleset with zone_id + kind="zone" +
#     phase="http_request_firewall_custom"; `rules` is a repeatable block with
#     action/expression/description/enabled. action "block" is valid. List
#     references in WAF expressions use the list NAME with a `$` prefix (NOT the
#     list id): ($crowdsec_ban). Both ban and captcha decisions land in this one
#     list (the CF account allows only one Rules List), so a single block rule
#     covers everything — captcha is enforced as block at the edge.
#
# zone_id is the viktorbarzin.me zone — the single zone id used repo-wide
# (default of var.cloudflare_zone_id in modules/kubernetes/ingress_factory and
# hardcoded the same in stacks/kms/main.tf; source of truth is the git-crypt'd
# config.tfvars). Hardcoded here (with the conventional marker comment) because
# the rybbit stack does not import the ingress_factory module.
# -----------------------------------------------------------------------------
# Cloudflare allows only ONE entrypoint ruleset per zone+phase, and the zone
# already has the stock `default` http_request_firewall_custom ruleset (created
# out-of-band, id 106a1342bc88454ea59c47ad3431fe0e). Creating a second one fails
# the singleton constraint, so we IMPORT the existing ruleset and manage all of
# its rules here: our CrowdSec ban/captcha rules FIRST, and the pre-existing
# (currently disabled) skip rule preserved verbatim below it.
import {
  to = cloudflare_ruleset.crowdsec
  id = "zone/fd2c5dd4efe8fe38958944e74d0ced6d/106a1342bc88454ea59c47ad3431fe0e"
}

resource "cloudflare_ruleset" "crowdsec" {
  zone_id = "fd2c5dd4efe8fe38958944e74d0ced6d" # cloudflare_zone_id (viktorbarzin.me)
  name    = "default"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  # The WAF rule references the IP list by name ($crowdsec_ban), so the list
  # must exist before this ruleset is created/updated.
  depends_on = [cloudflare_list.crowdsec_ban]

  # CrowdSec ban — block every IP in the single edge list, EXCEPT on the
  # Authentik auth hosts. The sync (lapi_kv_sync.py) now writes ONLY "ban"
  # decisions into crowdsec_ban — captcha is no longer downgraded to a hard
  # block. The auth-host carve-out guarantees a CrowdSec hit can never wall a
  # user out of the login / WebAuthn flow they authenticate through: without it,
  # a false-positive ban would 403 the passkey ceremony + session-refresh XHRs
  # on every proxied host, auth included. 2026-06-20.
  #
  # HOME-EGRESS CARVE-OUT (2026-08-18). 137.220.71.46 is our own London WAN
  # egress IP. On 2026-08-16 it was hand-banned via `cscli decisions add` for
  # 363 days: a Linkwarden /api/v1/search 401 retry loop was traced to it, and
  # its reverse DNS (71.220.137.46.bcube.co.uk) read as an unrelated third
  # party rather than as our own ISP's PTR domain. The traffic was our own Mac
  # (Nextcloud desktop client + browser).
  #
  # The LAPI decision is deleted, so the sync WANTS to drop the IP from the
  # edge list — but Cloudflare answers every Lists write with HTTP 429 / code
  # 10040 and the list has taken exactly ONE successful write in 10 days
  # (2026-08-18 05:45 UTC — the one that pushed this ban to the edge). Until
  # that quota recovers the list cannot be corrected, so the carve-out is
  # expressed in the RULE, which is not subject to the Lists limiter.
  #
  # Remove this clause once `crowdsec_ban` no longer contains the IP. It is a
  # dynamic address, so it also stops being meaningful if the WAN IP changes.
  rules {
    action      = "block"
    expression  = "(ip.src in $crowdsec_ban) and not (http.host in {\"authentik.viktorbarzin.me\" \"public-auth.viktorbarzin.me\"}) and ip.src ne 137.220.71.46"
    description = "CrowdSec: block banned IPs (auth hosts carved out)"
    enabled     = true
  }
  # Pre-existing rule, imported and preserved verbatim (currently disabled).
  # NOTE: Cloudflare auto-attaches logging{enabled=true} to skip rules. It must
  # be declared here to match live, otherwise editing the OTHER rule re-sends
  # this one too and the v4 provider errors "Provider produced inconsistent
  # result after apply: .rules[1].logging block count changed from 0 to 1"
  # (hit 2026-06-20 when adding the auth-host carve-out above).
  rules {
    action      = "skip"
    expression  = "(http.host contains \"viktorbarzin.me\")"
    description = "skip"
    enabled     = false
    action_parameters {
      phases   = ["http_ratelimit", "http_request_firewall_managed", "http_request_sbfm"]
      products = ["uaBlock", "bic", "hot", "securityLevel", "rateLimit", "waf", "zoneLockdown"]
      ruleset  = "current"
    }
    logging {
      enabled = true
    }
  }
}

# -----------------------------------------------------------------------------
# Least-privilege API token for the sync job: account-level Filter-Lists edit
# ONLY, scoped to this single account (no zone/DNS/Workers access). The token
# value is sensitive and lands in TF state (Tier-1 PG, encrypted at rest) and
# in the rybbit Secret below — same trust level as the CF Global API Key
# already in state.
#
# ### VERIFY (v4.52.7): cloudflare_api_token with a repeatable `policy` block
#     (effect / permission_groups = Set of String / resources = Map of String);
#     token secret is exposed as `.value` (sensitive).
#
# ### VERIFY — PERMISSION GROUP NAME (highest-risk item). v4.52.7 deprecates
#     the flat `.permissions[...]` map ("some permissions overlap resource
#     scope"); the non-deprecated lookup is the scoped `.account[...]` map.
#     Cloudflare's current permissions reference calls the account list-edit
#     group "Account Filter Lists Edit" (and read "Account Filter Lists Read").
#     An OLDER community gist instead shows "Account Rule Lists Read/Write" —
#     Cloudflare has renamed this group over time. If `tg plan` errors with a
#     missing key, try (in order): .account["Account Filter Lists Edit"] ->
#     .account["Account Rule Lists Write"], or enumerate the live names with:
#       terraform console
#       > data.cloudflare_api_token_permission_groups.all.account
#     Read is not strictly required for edit (Edit = full CRUDL) but the sync
#     job GETs items, so we include Read too to be safe.
# -----------------------------------------------------------------------------
data "cloudflare_api_token_permission_groups" "all" {}

resource "cloudflare_api_token" "list_sync" {
  name = "rybbit-crowdsec-list-sync"

  policy {
    effect = "allow"
    permission_groups = [
      data.cloudflare_api_token_permission_groups.all.account["Account Rule Lists Write"],
      data.cloudflare_api_token_permission_groups.all.account["Account Rule Lists Read"],
    ]
    resources = {
      "com.cloudflare.api.account.${local.cf_account_id}" = "*"
    }
  }
}

# -----------------------------------------------------------------------------
# Pure-stdlib sync script, mounted into the CronJob from a ConfigMap (the
# alert_digest pattern — no per-run package installs).
# -----------------------------------------------------------------------------
resource "kubernetes_config_map" "crowdsec_cf_sync_script" {
  metadata {
    name      = "crowdsec-cf-sync-script"
    namespace = "rybbit"
  }
  data = {
    "lapi_kv_sync.py" = file("${path.module}/lapi_kv_sync.py")
  }
}

# Secrets consumed by the sync job: the LAPI bouncer key (registered in LAPI,
# stored in Vault secret/platform -> kvsync_bouncer_key) and the minted CF
# token value. Account id and list ids are NOT secret and are passed as plain
# env values on the CronJob.
resource "kubernetes_secret" "crowdsec_cf_sync" {
  metadata {
    name      = "crowdsec-cf-sync"
    namespace = "rybbit"
  }
  type = "Opaque"
  data = {
    LAPI_KEY     = data.vault_kv_secret_v2.cf_platform.data["kvsync_bouncer_key"]
    CF_API_TOKEN = cloudflare_api_token.list_sync.value
  }
}

resource "kubernetes_cron_job_v1" "crowdsec_cf_sync" {
  metadata {
    name      = "crowdsec-cf-sync"
    namespace = "rybbit"
    labels = {
      app  = "crowdsec-cf-sync"
      tier = local.tiers.aux
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    # */15 since 2026-08-16 (was */2 all day, then 0 */12 for a few hours).
    #
    # The cadence was never the whole story, and the 12h reading of it was
    # wrong. What the logs actually show, over 30 days:
    #
    #   * Thousands of runs succeed. They log "[ok] block: +0 / -0" — the edge
    #     list already matched LAPI, so the run issued NO write at all. A
    #     no-write run cannot be throttled: Cloudflare does not rate-limit the
    #     GETs, only changes.
    #   * The 429s begin the moment a decision appears or expires, i.e. on the
    #     first run that has something to WRITE — and then continue unbroken
    #     for hours or days. Three such stretches in nine days: 08-07 -> 08-10
    #     (2.4 days), 08-12 (8h), 08-15 -> 08-16 (1.6 days and counting).
    #
    # So a slower cadence does not help by itself. Direct measurement on
    # 2026-08-16 pinned it down further: with the CronJob quiet, a single
    # one-item POST still returned 429 code 10040 while the response's own
    # rate-limit headers read `r=1199` remaining of `q=1200;w=300`. Retries
    # after 75s, 180s and 300s of complete silence failed identically, and PUT
    # behaved exactly like POST. The limiter rejecting us is not the one it
    # advertises, and it is not counting requests per five minutes — it is
    # counting list CHANGES over a much longer window.
    #
    # That makes a fixed retry cadence the wrong shape entirely: it presents
    # the same change over and over, and if attempts count toward the budget
    # they hold it open. The fix is in lapi_kv_sync.py — an exponential write
    # backoff (30m/1h/2h/4h/6h, reset on success) persisted through Pushgateway
    # — so a throttled stretch costs a handful of attempts a day rather than
    # one per run. The script also now expresses a reconciliation as ONE PUT of
    # the full desired set instead of a POST plus a DELETE, halving the changes
    # per sync.
    #
    # With writes gated, frequent runs are cheap again and buy back freshness:
    # a new ban reaches the edge within ~15 min when the API is healthy,
    # instead of waiting up to 12h. That window matters only for
    # Cloudflare-PROXIED hosts — the nftables bouncer cannot cover those (it
    # sees the tunnel, not the client) but still drops banned IPs in-kernel on
    # direct hosts within seconds.
    #
    # The silence is the part that actually hurt: crowdsec_cf_list_sync_success
    # has been pushed correctly as 0 the whole time and nothing was watching
    # it. Alerts on that metric, and on the new drift gauge, landed with this
    # change.
    schedule = "*/15 * * * *"
    # Sized for the cadence: a missed start is worth catching up on, but not
    # hours later. (Was 110s at */2, then 3600s at 12h.)
    starting_deadline_seconds = 300
    job_template {
      metadata {}
      spec {
        # 0 retries: backoff_limit=2 made k8s re-run a failing pod up to 3x
        # within seconds, hammering Cloudflare's Lists-API write limit inside one
        # 60s window and escalating the throttle until it stopped clearing
        # (2026-06-27 outage). One attempt per cycle + the 429-soft-skip in
        # lapi_kv_sync.py keeps the sync gentle/self-healing.
        backoff_limit              = 0
        ttl_seconds_after_finished = 3600
        # concurrencyPolicy=Forbid with no deadline is a known wedge here: if a
        # run hangs, every later run is SKIPPED and the job goes quiet rather
        # than failing — webterminal-probe sat like that for 16.8h once and
        # 3d19h another time, and phpipam-pfsense-import for 4 days, both on a
        # black-holed socket that no timeout covered. Every network call in
        # lapi_kv_sync.py has an explicit timeout now (including the bare
        # TimeoutError that used to escape urllib's URLError handler), so a
        # hang should not happen; this is the backstop if one does. Sized well
        # above a normal run: LAPI fetch + list GET + one PUT + up to 25s of
        # bulk-op polling, each with a 20s ceiling.
        active_deadline_seconds = 300
        template {
          metadata {
            labels = {
              app = "crowdsec-cf-sync"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "crowdsec-cf-sync"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/lapi_kv_sync.py"]
              env {
                name = "LAPI_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.crowdsec_cf_sync.metadata[0].name
                    key  = "LAPI_KEY"
                  }
                }
              }
              env {
                name = "CF_API_TOKEN"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.crowdsec_cf_sync.metadata[0].name
                    key  = "CF_API_TOKEN"
                  }
                }
              }
              env {
                name  = "CF_ACCOUNT_ID"
                value = local.cf_account_id
              }
              env {
                name  = "CF_BAN_LIST_ID"
                value = cloudflare_list.crowdsec_ban.id
              }
              env {
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "48Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.crowdsec_cf_sync_script.metadata[0].name
              }
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
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
}
