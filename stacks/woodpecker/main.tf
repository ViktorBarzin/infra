variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "woodpecker_forgejo_url" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "woodpecker"
}

locals {
  # Viktor alone. Until 2026-11-15 every namespace-owner was a Woodpecker admin
  # too, which reads every repo's secrets and runs any pipeline; a repo owner
  # needs no admin to run their own repo's pipelines.
  woodpecker_admins = "ViktorBarzin"
}

resource "kubernetes_namespace" "woodpecker" {
  metadata {
    name = "woodpecker"
    labels = {
      "resource-governance/custom-quota" = "true"
      tier                               = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_resource_quota" "woodpecker" {
  metadata {
    name      = "tier-quota"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "32Gi"
      pods              = "60"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.woodpecker.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "woodpecker-secrets"
      namespace = "woodpecker"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "woodpecker-secrets"
      }
      dataFrom = [{
        extract = {
          key = "woodpecker"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.woodpecker]
}

# DB credentials from Vault database engine (rotated every 7 days — static
# role pg-woodpecker, rotation_period 604800 in stacks/vault). ExternalSecret
# provides WOODPECKER_DATABASE_DATASOURCE injected via
# server.extraSecretNamesForEnvFrom. envFrom does NOT hot-reload a running pod,
# so the target secret carries reloader.stakater.com/match="true" and the
# server sets reloader.stakater.com/search="true" (values.yaml); together they
# make Stakater Reloader restart the server when the rotated password lands —
# without it the pod kept using the revoked password until an unrelated restart
# (latent weekly rotation outage, fixed 2026-06-05).
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "woodpecker-db-creds"
      namespace = "woodpecker"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "woodpecker-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            WOODPECKER_DATABASE_DATASOURCE = "postgres://woodpecker:{{ .password }}@${var.postgresql_host}:5432/woodpecker?sslmode=disable"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-woodpecker"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.woodpecker]
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }

  data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

# Database init job - REMOVED: database and user already exist.
# The job used -U root which doesn't work with CNPG (superuser is 'postgres').
# Vault DB engine manages the woodpecker credentials via rotation.

# Woodpecker server data is on local-path (node-local storage), NOT NFS.
# The old NFS PV was unused — PVC was already bound to local-path PV.
# No PV management needed here.

# Helm release for Woodpecker CI
# Database datasource is now injected from ExternalSecret via envFrom
resource "helm_release" "woodpecker" {
  name       = "woodpecker"
  namespace  = kubernetes_namespace.woodpecker.metadata[0].name
  repository = "oci://ghcr.io/woodpecker-ci/helm"
  chart      = "woodpecker"
  # 3.5.1 -> 3.7.5 (server/agent v3.19.0) on 2026-10-12. Apply this stack from
  # the main checkout, never from CI: the apply restarts the agent running the
  # pipeline, which kills it and leaves the release in pending-upgrade.
  version = "3.7.5"

  values = [
    templatefile("${path.module}/values.yaml", {
      github_client_id      = data.vault_kv_secret_v2.secrets.data["github_client_id"]
      github_client_secret  = data.vault_kv_secret_v2.secrets.data["github_client_secret"]
      agent_secret          = data.vault_kv_secret_v2.secrets.data["agent_secret"]
      forgejo_client_id     = data.vault_kv_secret_v2.secrets.data["forgejo_client_id"]
      forgejo_client_secret = data.vault_kv_secret_v2.secrets.data["forgejo_client_secret"]
      forgejo_url           = var.woodpecker_forgejo_url
      woodpecker_admins     = local.woodpecker_admins
    })
  ]

  # 1200, not 600: longer than the server's 15-minute startupProbe budget for
  # DB migrations (woodpecker_server_host_alias below), so a slow migration is
  # not cut short by an atomic rollback to the old image against an already
  # migrated database.
  timeout         = 1200
  atomic          = true
  cleanup_on_fail = true
  depends_on      = [kubernetes_manifest.db_external_secret]
}

# Patch hostAliases onto the woodpecker-server StatefulSet — the chart (3.5.1,
# still true in 3.7.5) does NOT expose this field, so we have to do it after the helm release.
# Keeps the OAuth/forge-API path off the WAN gateway (forgejo.viktorbarzin.me
# resolves to the public IP via DNS, which round-trips through Cloudflare
# and routinely tripped 30s context-deadline timeouts when fetching pipeline
# config). We pin forgejo.viktorbarzin.me to the in-cluster Traefik Service
# ClusterIP (read dynamically below); Traefik serves the *.viktorbarzin.me
# wildcard so SNI verification still passes. ClusterIP (not the LB IP) avoids
# two traps: (1) the Traefik LB IP is ETP=Local and not reliably hairpin-
# reachable from an arbitrary pod's node; (2) a hard-coded LB IP rots on every
# Traefik renumber — this previously pinned 10.0.20.200, which went dead when
# Traefik moved to its dedicated .203 (2026-05-30), the same failure class the
# cloudflared origin hit (also fixed by targeting the in-cluster Service).
data "kubernetes_service" "traefik" {
  metadata {
    name      = "traefik"
    namespace = "traefik"
  }
}

# The same patch adds a startupProbe to the server container, which chart 3.7.5
# also does not expose. Migrations run before the HTTP listener starts, so a
# long one (the 3.18 log_entries migration walks ~4.5M rows here) needs more
# than liveness's 3 x 10s. The startupProbe allows 90 x 10s = 15 min, under the
# helm_release timeout of 1200s, and liveness only starts once it has passed.
# Fields the chart does not render survive Helm's three-way merge, as
# hostAliases has.
locals {
  woodpecker_server_patch = jsonencode({
    spec = {
      template = {
        spec = {
          hostAliases = [{
            ip        = data.kubernetes_service.traefik.spec[0].cluster_ip
            hostnames = ["forgejo.viktorbarzin.me"]
          }]
          containers = [{
            name = "server"
            startupProbe = {
              httpGet          = { path = "/healthz", port = 8000, scheme = "HTTP" }
              periodSeconds    = 10
              timeoutSeconds   = 10
              failureThreshold = 90
            }
          }]
        }
      }
    }
  })
}

resource "null_resource" "woodpecker_server_host_alias" {
  triggers = {
    # Re-run on helm version/values change, and when the patch itself changes
    # (including the Traefik ClusterIP, e.g. the Service is recreated) so the
    # alias and the startupProbe self-heal.
    helm_version = helm_release.woodpecker.version
    helm_values  = sha256(join("", helm_release.woodpecker.values))
    patch        = sha256(local.woodpecker_server_patch)
  }

  provisioner "local-exec" {
    command     = <<-BASH
      set -euo pipefail
      kubectl -n woodpecker patch statefulset/woodpecker-server --type=strategic --patch '${local.woodpecker_server_patch}'
      kubectl -n woodpecker rollout status statefulset/woodpecker-server --timeout=120s
    BASH
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [helm_release.woodpecker]
}

# The agent and the step pods held cluster-admin through the woodpecker and
# woodpecker-default ClusterRoleBindings until 2026-11-15. The agent needs only
# the chart's Role in this namespace (pods, logs, PVCs, services, secrets), and
# step pods now run as their repo's account (repo-accounts.tf).

# --- Vault → Woodpecker Secret Sync ---
# Copies keys of Vault KV secret/ci/global into Woodpecker as REPO secrets,
# each into only the repos that use it. Runs every 6 hours.
#
# Until 2026-11-15 every key went in as a GLOBAL secret, which any pipeline in
# any repo could read, and the keys included Viktor's Forgejo admin token and
# the sops age key. The pipelines then used three of the fourteen. A key not
# listed below stays in Vault and reaches no pipeline; the infra pipelines
# read Vault directly with their own token. The sync deletes the old global
# copies.
locals {
  # Vault key -> Woodpecker repo ids that may read it (from_secret uses in
  # every repo's .woodpecker, counted 2026-11-15).
  ci_repo_secrets = {
    "slack_webhook"     = ["1", "82"]            # ViktorBarzin/infra, viktor/infra
    "slack-webhook-url" = ["2", "6", "87", "88"] # Website, webhook-handler, audiobook-search, insta2spotify
    "dockerhub-token"   = ["77"]                 # viktor/claude-memory
  }
  ci_repo_secret_lines = join("\n", flatten([
    for key, repos in local.ci_repo_secrets : [for r in repos : "${key} ${r}"]
  ]))
}

resource "kubernetes_service_account" "vault_woodpecker_sync" {
  metadata {
    name      = "woodpecker-sync"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
}

resource "kubernetes_config_map" "vault_woodpecker_sync" {
  metadata {
    name      = "vault-woodpecker-sync"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }

  data = {
    "secrets.txt" = local.ci_repo_secret_lines
    "sync.sh"     = <<-SCRIPT
      #!/bin/sh
      set -e
      VAULT_ADDR="http://vault-active.vault.svc.cluster.local:8200"
      WP_API="http://woodpecker-server.woodpecker.svc.cluster.local/api"
      EVENTS='["cron","deployment","manual","push","tag"]'

      # Authenticate to Vault as the woodpecker-sync ServiceAccount
      SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
      VAULT_TOKEN=$(curl -sf -X POST "$VAULT_ADDR/v1/auth/kubernetes/login" \
        -d "{\"role\":\"woodpecker-sync\",\"jwt\":\"$SA_TOKEN\"}" | jq -r .auth.client_token)
      if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
        echo "ERROR: Failed to authenticate to Vault"
        exit 1
      fi

      CIG=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/secret/data/ci/global")
      WP_TOKEN=$(echo "$CIG" | jq -r '.data.data.woodpecker_api_token // empty')
      if [ -z "$WP_TOKEN" ]; then
        echo "ERROR: No woodpecker_api_token in secret/ci/global"
        exit 1
      fi
      wp() { curl -sf -H "Authorization: Bearer $WP_TOKEN" -H "Content-Type: application/json" "$@"; }

      # Repo secrets: create, or update when present.
      synced=0
      while read -r NAME REPO; do
        [ -n "$NAME" ] || continue
        BODY=$(echo "$CIG" | jq -c --arg n "$NAME" --argjson e "$EVENTS" \
          '{name: $n, value: .data.data[$n], events: $e} | select(.value != null)')
        if [ -z "$BODY" ]; then echo "WARN: $NAME is not in secret/ci/global"; continue; fi
        wp -o /dev/null -X PATCH "$WP_API/repos/$REPO/secrets/$NAME" -d "$BODY" 2>/dev/null \
          || wp -o /dev/null -X POST "$WP_API/repos/$REPO/secrets" -d "$BODY"
        synced=$((synced + 1))
      done < /scripts/secrets.txt
      echo "Synced $synced repo secrets from Vault to Woodpecker"

      # Global secrets reach every repo, so none is kept.
      for NAME in $(wp "$WP_API/secrets" | jq -r '.[].name'); do
        wp -o /dev/null -X DELETE "$WP_API/secrets/$NAME" && echo "Deleted global secret $NAME"
      done
    SCRIPT
  }
}

resource "kubernetes_cron_job_v1" "vault_secret_sync" {
  metadata {
    name      = "vault-woodpecker-sync"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.vault_woodpecker_sync.metadata[0].name
            container {
              name    = "sync"
              image   = "alpine"
              command = ["/bin/sh", "-c", "apk add --no-cache curl jq && /bin/sh /scripts/sync.sh"]
              volume_mount {
                name       = "sync-script"
                mount_path = "/scripts"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
            volume {
              name = "sync-script"
              config_map {
                name = kubernetes_config_map.vault_woodpecker_sync.metadata[0].name
              }
            }
            restart_policy = "OnFailure"
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

# Per-route ServersTransport: give woodpecker-server more than 30s to send its
# first response header (infra#109).
#
# WHY. Creating a manual/deployment pipeline (`POST /api/repos/1/pipelines`)
# makes woodpecker-server load the pipeline config from the forge synchronously
# BEFORE it answers the HTTP call. Repo 1 is ViktorBarzin/infra on the GitHub
# forge, so that fetch goes to api.github.com over the WAN — the one forge path
# the in-cluster `forgejo.viktorbarzin.me` hostAlias (see null_resource above)
# cannot shortcut. The config loader makes 4-6 sequential forge calls, each with
# a 30s per-call deadline (WOODPECKER_FORGE_TIMEOUT, values.yaml), so when GitHub
# is slow (not down) the cumulative wall-clock climbs past 30s. Traefik's global
# serversTransport responseHeaderTimeout is ALSO 30s (stacks/traefik .../main.tf),
# so it fired first and returned 504 — rendered by the error-pages middleware —
# even in cases woodpecker would have answered 200 a few seconds later. That was
# the 2026-10-03 symptom: two terminal-lobby release triggers 504'd at exactly
# Duration ~30012ms during a GitHub API brownout.
#
# This raises the header timeout for the woodpecker route alone to 180s (6 × the
# 30s forge-call deadline), so a slow-but-successful config load returns the real
# 200 instead of a masked 504. It does NOT help a full GitHub outage (repeated
# 503s fail fast); that needs a retry on the one-shot trigger curl in the
# terminal-lobby release workflow, which lives in another repo (see infra#109).
# Same pattern as stacks/terminal (330s long-poll) and stacks/reverse-proxy.
resource "kubernetes_manifest" "forge_slowfetch_transport" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = "forge-slowfetch"
      namespace = kubernetes_namespace.woodpecker.metadata[0].name
    }
    spec = {
      forwardingTimeouts = {
        responseHeaderTimeout = "180s"
      }
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Forgejo webhooks + webhook_handler POSTs hit ci.viktorbarzin.me to trigger
  # pipelines; the Woodpecker API + OAuth flows also live here. Forward-auth
  # would block every machine-driven call. Woodpecker has its own OAuth login.
  # auth = "none": Forgejo webhooks + API calls trigger pipelines; Woodpecker OAuth handles login; forward-auth blocks webhook deliveries.
  auth            = "none"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.woodpecker.metadata[0].name
  name            = "ci"
  service_name    = "woodpecker-server"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Woodpecker CI"
    "gethomepage.dev/description"  = "CI/CD pipelines"
    "gethomepage.dev/icon"         = "woodpecker-ci.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
    # infra#109: 180s header timeout for slow GitHub-forge config loads (see
    # kubernetes_manifest.forge_slowfetch_transport above). Ref format is
    # <namespace>-<name>@kubernetescrd.
    "traefik.ingress.kubernetes.io/service.serverstransport" = "woodpecker-forge-slowfetch@kubernetescrd"
  }
  depends_on = [kubernetes_manifest.forge_slowfetch_transport]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# ── Rotation-window force-sync (infra#45) ────────────────────────────────────
# The woodpecker-rotation-sync CronJob that lived here was replaced on
# 2026-10-30 by the db-rotation-watcher in stacks/vault, which force-syncs
# woodpecker-db-creds (and every other database ExternalSecret) seconds after
# Vault rotates the role. Runbook: docs/runbooks/db-credential-rotation.md.

# ---------------------------------------------------------------------------
# Workspace-PVC reaper.
#
# WHY THIS EXISTS. Woodpecker's kubernetes backend creates one PVC per pipeline
# ("a temporary PVC is created for the lifetime of the pipeline") and deletes it
# in DestroyWorkflow. That cleanup is best-effort and leaks on two paths, both
# observed here:
#
#   1. DestroyWorkflow deletes every step pod BEFORE the volume, and returns on
#      the first pod error:
#
#          for _, stage := range conf.Stages {
#              for _, step := range stage.Steps {
#                  err := stopPod(ctx, e, step, ...)
#                  if err != nil { return err }   // <- never reaches stopVolume
#              }
#          }
#          ...
#          err = stopVolume(ctx, e, conf.Volume, ...)
#
#      stopPod suppresses only 404. Any apiserver timeout, conflict or 500
#      propagates and the PVC survives.
#
#   2. If the agent process dies while holding the task, DestroyWorkflow never
#      runs at all. The DB shows 23 workflows stuck `running` with finished=0
#      out of 7,556, plus 433 `killed` (Woodpecker cancels on the next push).
#      Workflow 6860 started 2026-08-16 00:38:27 and its PVC was created
#      00:38:28 — one second apart, still present 31 days later.
#
# NO WOODPECKER SETTING FIXES THIS. All 20 documented WOODPECKER_BACKEND_K8S_*
# vars were checked; none controls volume lifecycle, TTL, retention or reuse.
# The three touching storage are VOLUME_SIZE, STORAGE_CLASS and STORAGE_RWX.
#
# AND KUBERNETES GC CANNOT HELP. mkPersistentVolumeClaim sets only Name and
# Namespace in ObjectMeta — no ownerReferences and no labels — so there is no
# edge for the garbage collector to follow, and a reaper cannot use a label
# selector either. Hence the `wp-` name prefix below.
#
# WHAT IT ACTUALLY COSTS. Not much disk: measured with du on each node the seven
# orphans held ~130 MB total (node2 66M, node5 34M, node4 27M, node3 28K),
# because local-path enforces no quota and the 10G VOLUME_SIZE is a claim figure
# only. The real cost is that a leaked PVC on the WaitForFirstConsumer binding
# mode stays Pending forever with no consumer ever arriving, which fires
# PVCStuckPending permanently — two of them had been firing for 10 days.
resource "kubernetes_service_account" "pvc_reaper" {
  metadata {
    name      = "woodpecker-pvc-reaper"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
}

resource "kubernetes_role" "pvc_reaper" {
  metadata {
    name      = "woodpecker-pvc-reaper"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  # Namespaced deliberately. The sibling pod reaper in infra-maintenance uses a
  # ClusterRole because it sweeps -A; this one must never reach outside
  # woodpecker. No PV verbs are needed: local-path is reclaimPolicy=Delete, so
  # deleting the PVC cascades to the PV and the provisioner's teardown pod
  # removes /opt/local-path-provisioner/<pv>_woodpecker_<pvc>.
  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["list", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding" "pvc_reaper" {
  metadata {
    name      = "woodpecker-pvc-reaper"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.pvc_reaper.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.pvc_reaper.metadata[0].name
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "pvc_reaper" {
  metadata {
    name      = "woodpecker-pvc-reaper"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    # Daily is plenty — a leak costs ~20 MB and a permanently-firing alert, not
    # an outage. Offset minute is the house convention so reapers do not all
    # land on the same tick.
    schedule                      = "37 4 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"
    job_template {
      metadata {
        name = "woodpecker-pvc-reaper"
      }
      spec {
        ttl_seconds_after_finished = 600
        # Same reasoning as cleanup-failed-pods (infra-maintenance, commit
        # 22ba5c67): with concurrency_policy Forbid, a run that never finishes
        # silently cancels every later schedule, so the deadline is what keeps
        # the cadence. That job wedged for real when the apiserver restarted
        # mid-run.
        active_deadline_seconds = 300
        template {
          metadata {
            name = "woodpecker-pvc-reaper"
          }
          spec {
            service_account_name = kubernetes_service_account.pvc_reaper.metadata[0].name
            container {
              name  = "reap"
              image = "bitnami/kubectl:latest"
              command = ["/bin/sh", "-c", <<-EOT
                set -u

                # Every PVC referenced by any pod in the namespace, in ANY phase.
                # Phase matters: a pipeline mid-run has a Running pod holding its
                # claim, and a pod that is Pending because its node is busy still
                # owns one. Filtering by phase here would delete a live workspace.
                kubectl -n woodpecker get pods \
                  -o go-template='{{range .items}}{{range .spec.volumes}}{{if .persistentVolumeClaim}}{{.persistentVolumeClaim.claimName}}{{"\n"}}{{end}}{{end}}{{end}}' \
                  | sort -u > /tmp/inuse

                now=$(date +%s)

                # Only wp-* claims. Woodpecker names them wp-<workflow-ulid>-N-<volume>,
                # and nothing else in this namespace uses that prefix. There are no
                # labels to select on, which is the upstream gap this works around.
                kubectl -n woodpecker get pvc \
                  -o go-template='{{range .items}}{{.metadata.name}} {{.metadata.creationTimestamp}}{{"\n"}}{{end}}' \
                  | while read -r name created; do
                      case "$name" in wp-*) ;; *) continue ;; esac
                      [ -n "$created" ] || continue

                      # Never touch a claim a pod still references.
                      if grep -qxF "$name" /tmp/inuse; then continue; fi

                      # Age gate. A pipeline can outlive its own pods briefly
                      # between steps, so a claim is only orphaned if it has been
                      # unreferenced AND is older than any plausible pipeline. The
                      # longest observed infra pipeline is well under an hour; 24h
                      # is deliberately far past it, because deleting a live
                      # workspace fails a build and reclaiming 20 MB a day later
                      # costs nothing.
                      age_start=$(date -d "$created" +%s 2>/dev/null) || continue
                      [ $((now - age_start)) -gt 86400 ] || continue

                      echo "reaping orphaned workspace PVC $name (created $created)"
                      kubectl -n woodpecker delete pvc "$name" --ignore-not-found
                    done
              EOT
              ]
            }
            restart_policy = "Never"
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
