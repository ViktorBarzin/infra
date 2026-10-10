variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "actualbudget-secrets"
      namespace = "actualbudget"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "actualbudget-secrets"
      }
      dataFrom = [{
        extract = {
          key = "actualbudget"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.actualbudget]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "actualbudget-secrets"
    namespace = kubernetes_namespace.actualbudget.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["credentials"])
}


# To create a new deployment:
/**
  1. Create a subdirectory for {name} under /srv/nfs on the Proxmox host (192.168.1.127)
  2. Add {name} as proxied cloudflare route (tfvars)
  3. Add module here
*/

resource "kubernetes_namespace" "actualbudget" {
  metadata {
    name = "actualbudget"
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
  namespace       = kubernetes_namespace.actualbudget.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# Versions: Renovate bumps the two pins below (ADR-0030); before 2026-10-10
# Keel tracked them live with keel.sh/policy=minor. Each instance's server
# and http-api read these locals, so one Renovate commit moves every instance.
# ACCEPTED RISK (Viktor, 2026-07-25): actual-server and actual-http-api are
# separately released images that BOTH migrate the same budget file, so an
# independent bump can leave the web client "too old" (or bank-sync stale)
# until the other catches up. The bank-sync side is caught by BankSyncStale;
# the web side is user-visible.
#
# THE PINS MUST NOT LAG THE LIVE VERSION. Both budget files carry migrations
# that first ship in v26.7.0 (1780099200000, 1780327681000, 1780606215000,
# 1780606215001), so a deployment started at 26.6.0 would open a file newer
# than itself and reproduce the "client too old" break below.
# History: 2026-07-25 server was stuck at 26.4.0 while http-api reached 26.5.2 → Anca's web
# UI broke ("client too old", even in incognito) since the file was already migrated to 26.5.x.
# 2026-08-16: the seeds had drifted to 3 minors behind live (26.6.0 vs 26.8.1) and the
# http-api image was a hardcoded `latest`; both fixed. NOTE the nightly re-import loop found
# the same day was NOT caused by these upgrades — root cause was a budget-data rule with a
# `set account` action, see docs/runbooks/actualbudget-bank-sync.md.
locals {
  # renovate: datasource=docker depName=actualbudget/actual-server
  actual_server_tag = "26.8.1"
  # renovate: datasource=docker depName=jhonderson/actual-http-api
  actual_http_api_tag = "26.8.1"
}

# https://budget-viktor.viktorbarzin.me/
module "viktor" {
  source                     = "./factory"
  name                       = "viktor"
  tag                        = local.actual_server_tag
  http_api_tag               = local.actual_http_api_tag
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  enable_http_api            = true
  enable_bank_sync           = true
  storage_size               = "4Gi"
  budget_encryption_password = lookup(local.credentials["viktor"], "password", null)
  sync_id                    = lookup(local.credentials["viktor"], "sync_id", null)
  homepage_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Budget Viktor"
    "gethomepage.dev/description"  = "Personal budget"
    "gethomepage.dev/icon"         = "actual-budget.png"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://budget-anca.viktorbarzin.me/
module "anca" {
  source                     = "./factory"
  name                       = "anca"
  tag                        = local.actual_server_tag
  http_api_tag               = local.actual_http_api_tag
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  enable_http_api            = true
  enable_bank_sync           = true
  budget_encryption_password = lookup(local.credentials["anca"], "password", null)
  sync_id                    = lookup(local.credentials["anca"], "sync_id", null)
  homepage_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Budget Anca"
    "gethomepage.dev/description"  = "Personal budget"
    "gethomepage.dev/icon"         = "actual-budget.png"
    "gethomepage.dev/group"        = "Finance & Personal"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://budget-emo.viktorbarzin.me/
# Disabled 2026-05-13: Emo isn't using this instance. PVC is preserved so
# we can flip enabled back to true to bring the instance back as-was.
# The empty accounts list (vs. anca/viktor) was causing the daily bank-sync
# CronJob to fail and trigger BankSyncStale.
module "emo" {
  source                     = "./factory"
  name                       = "emo"
  tag                        = local.actual_server_tag
  http_api_tag               = local.actual_http_api_tag
  tls_secret_name            = var.tls_secret_name
  nfs_server                 = var.nfs_server
  depends_on                 = [kubernetes_namespace.actualbudget]
  tier                       = local.tiers.edge
  enabled                    = false
  enable_http_api            = false
  enable_bank_sync           = false
  budget_encryption_password = lookup(local.credentials["emo"], "password", null)
  sync_id                    = lookup(local.credentials["emo"], "sync_id", null)
  homepage_annotations       = {}
}
