# k8s-version-upgrade — Automated K8s component (kubeadm/kubelet/kubectl) upgrade
#
# Architecture: detection CronJob → chain of small Jobs, one per phase. Each
# Job's pod runs on a node that is NOT its drain target — eliminates the
# self-preemption bug that killed the agent-based v1 (2026-05-11 incident).
#
# Chain (dynamic length — one worker Job per worker node, enumerated live):
#   preflight  (pinned: first worker)
#   master     (pinned: first worker; drains k8s-master)
#   worker     (pinned: k8s-master + control-plane toleration; drains each worker)
#              ↳ repeats for EVERY worker still off-target (kubectl-derived, so
#                new nodes like node5/node6 are included automatically)
#   postflight (no pinning)
#
# Each phase Job's container runs scripts/upgrade-step.sh which:
#   - dispatches on $PHASE
#   - spawns the next Job via envsubst on job-template.yaml
#   - uses deterministic naming (k8s-upgrade-${phase}-${target_version}[-${node}])
#     so re-running on failure reconciles to a single Job per run.
#
# Reuse points:
#   - claude-agent-service image (kubectl + ssh + jq + curl + envsubst)
#   - Vault secret/k8s-upgrade/* (ssh_key, slack_webhook)
#   - Prometheus + Pushgateway + Upgrade Gates alerts
#   - default/backup-etcd CronJob (snapshot trigger)
#   - infra/scripts/update_k8s.sh (per-node upgrade body)

variable "schedule" {
  type = string
  # Daily 12:00 UTC — outside kured window (kured runs 02:00-06:00
  # London). Was weekly Sunday until 2026-05-18; daily picks up upstream
  # patch releases the same day they land. Concurrency is bounded by the
  # CronJob's Forbid policy + Job-name idempotency (the detection job
  # skips spawning a preflight Job if one already exists).
  default = "0 12 * * *"
}

variable "enabled" {
  type    = bool
  default = true
}

# Mirrors `local.image_tag` in stacks/claude-agent-service/main.tf — bump
# in lockstep with claude-agent-service rebuilds. The image ships kubectl,
# ssh-client, curl, jq, envsubst — everything the upgrade Jobs need.
variable "image_tag" {
  type    = string
  default = "latest"
}

# When true, detection runs but does NOT spawn the preflight Job.
variable "detection_dry_run" {
  type    = bool
  default = false
}

locals {
  namespace = "k8s-upgrade"
  image     = "ghcr.io/viktorbarzin/claude-agent-service:${var.image_tag}"
  labels = {
    app = "k8s-version-upgrade"
  }
}

# --- Namespace ---

resource "kubernetes_namespace" "k8s_upgrade" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.cluster
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- ExternalSecret: SSH key + Slack webhook ---
#
# Operator populates Vault `secret/k8s-upgrade/` with:
#   - ssh_key       (ed25519 PRIVATE key, used to SSH wizard@<node> from Jobs)
#   - ssh_key_pub   (matching public key, deployed to nodes' authorized_keys)
#   - slack_webhook (incoming-webhook URL)
#
# No claude-agent bearer needed — the chain no longer POSTs to that service.
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "k8s-upgrade-creds"
      namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "k8s-upgrade-creds"
      }
      data = [
        {
          secretKey = "ssh_key"
          remoteRef = {
            key      = "k8s-upgrade"
            property = "ssh_key"
          }
        },
        {
          secretKey = "slack_webhook"
          remoteRef = {
            key      = "k8s-upgrade"
            property = "slack_webhook"
          }
        },
      ]
    }
  }
}

# --- Unified ServiceAccount + RBAC ---
#
# One SA serves BOTH the detection CronJob and every phase Job:
#   - detection CronJob: needs nodes:get/list + secrets:get + jobs:create
#     (to spawn Job 0 = preflight)
#   - phase Jobs: same + pods/eviction:create + pods:delete + namespaces:patch
#
# Cluster-scoped because the chain spans the whole cluster (drain works on
# any node, and the preflight Job creates a Job in `default` ns from
# `cronjob/backup-etcd`).

resource "kubernetes_service_account" "k8s_upgrade_job" {
  metadata {
    name      = "k8s-upgrade-job"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "k8s_upgrade_job" {
  metadata {
    name = "k8s-upgrade-job"
  }
  # Read nodes (version comparison + readiness check)
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "patch", "update"]
  }
  # Drain — evict pods
  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }
  # Drain fallback — direct delete (predrain_unstick bypasses PDBs)
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "delete"]
  }
  # Read the etcd-snapshot Job's pod logs — preflight verifies the snapshot
  # size by parsing the backup Job's log (`kubectl logs job/...`). `pods/log`
  # is a SEPARATE subresource not covered by the `pods` rule above. Missing
  # this grant aborts preflight step 6 with a Forbidden on pods/log in the
  # `default` ns (2026-06-17 — surfaced after a stale out-of-band grant was
  # reconciled away by `terragrunt apply`).
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
  # Read PDBs to find drain-blocking pods
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list"]
  }
  # Read DaemonSets/StatefulSets/ReplicaSets/Deployments so `kubectl drain
  # --ignore-daemonsets` can classify each pod's owner. Without daemonsets
  # GET permission, drain bails with "cannot delete daemonsets ... is
  # forbidden" for every daemonset-managed pod on the node. (2026-05-20)
  #
  # `patch` on deployments added 2026-05-23: phase_master scales tigera-operator
  # to 0 before drain (operator crashloops during apiserver static-pod swaps,
  # generates I/O storm that breaks kubeadm's 5-min watch) and back to 1
  # after master is upgraded. Until HA control plane lands (beads code-n0ow),
  # this is how we keep autonomous upgrades unblocked.
  rule {
    api_groups = ["apps"]
    resources  = ["daemonsets", "statefulsets", "replicasets", "deployments"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "deployments/scale"]
    verbs      = ["patch", "update"]
  }
  # Chain dispatch — create the next Job; reconcile via apply on retry.
  # In `default` ns to also create the etcd-snapshot Job from cronjob/backup-etcd.
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "delete", "patch", "watch"]
  }
  # Pull CronJob spec for `kubectl create job --from=cronjob/backup-etcd`
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list"]
  }
  # Annotate the k8s-upgrade namespace (in-flight marker + snapshot path)
  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = [local.namespace]
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding" "k8s_upgrade_job" {
  metadata {
    name = "k8s-upgrade-job"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.k8s_upgrade_job.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.k8s_upgrade_job.metadata[0].name
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
}

# Namespaced: read the credentials Secret in k8s-upgrade (SSH key + Slack URL)
# + read the kill-switch ConfigMap (one-touch emergency-stop for the chain).
resource "kubernetes_role" "k8s_upgrade_job_ns" {
  metadata {
    name      = "k8s-upgrade-job-ns"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["k8s-upgrade-creds"]
    verbs          = ["get"]
  }
  # Kill-switch ConfigMap. Existence halts the chain (any phase) — see the
  # "Kill-switch" block at the top of scripts/upgrade-step.sh.
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["k8s-upgrade-killswitch"]
    verbs          = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "k8s_upgrade_job_ns" {
  metadata {
    name      = "k8s-upgrade-job-ns"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.k8s_upgrade_job_ns.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.k8s_upgrade_job.metadata[0].name
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
}

# --- ConfigMaps: scripts + Job template ---

resource "kubernetes_config_map" "k8s_upgrade_scripts" {
  metadata {
    name      = "k8s-upgrade-scripts"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
    labels    = local.labels
  }
  data = {
    "upgrade-step.sh" = file("${path.module}/scripts/upgrade-step.sh")
    "update_k8s.sh"   = file("${path.module}/../../scripts/update_k8s.sh")
  }
}

resource "kubernetes_config_map" "k8s_upgrade_job_template" {
  metadata {
    name      = "k8s-upgrade-job-template"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
    labels    = local.labels
  }
  data = {
    "job-template.yaml" = file("${path.module}/job-template.yaml")
  }
}

# --- Detection CronJob ---
#
# Probes for available patch/minor targets weekly. When one is found, renders
# Job 0 (preflight) from the same job-template the chain uses. The CronJob no
# longer POSTs to claude-agent-service; the whole pipeline now runs inside the
# cluster via Job-chaining.

resource "kubernetes_cron_job_v1" "k8s_version_check" {
  metadata {
    name      = "k8s-version-check"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600
    suspend                       = !var.enabled
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 0
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = local.labels
          }
          spec {
            service_account_name = kubernetes_service_account.k8s_upgrade_job.metadata[0].name
            restart_policy       = "Never"
            image_pull_secrets {
              name = "registry-credentials"
            }
            volume {
              name = "creds"
              secret {
                secret_name = "k8s-upgrade-creds"
                # 0444 — non-root container needs read; SSH key gets re-installed
                # with mode 0400 in the inline command before any ssh call.
                default_mode = "0444"
              }
            }
            volume {
              name = "template"
              config_map {
                name = kubernetes_config_map.k8s_upgrade_job_template.metadata[0].name
              }
            }
            container {
              name  = "version-check"
              image = local.image
              command = ["/bin/bash", "-c", <<-EOT
                set -euo pipefail
                echo "==> k8s-version-check ($(date -u +%FT%TZ))"

                SLACK=$(cat /secrets/k8s-upgrade/slack_webhook)
                install -m 0400 /secrets/k8s-upgrade/ssh_key /tmp/ssh_key
                SSH="ssh -i /tmp/ssh_key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts -o ConnectTimeout=10"

                slack() {
                  curl -sS -X POST -H 'Content-Type: application/json' \
                    --data "$(jq -nc --arg t "[k8s-version-check] $1" '{text: $t}')" \
                    "$SLACK" || true
                }

                # Kill-switch — see scripts/upgrade-step.sh for full docs.
                # ConfigMap existence halts the chain (any phase).
                if /usr/local/bin/kubectl -n k8s-upgrade get configmap k8s-upgrade-killswitch >/dev/null 2>&1; then
                  reason=$(/usr/local/bin/kubectl -n k8s-upgrade get configmap k8s-upgrade-killswitch \
                    -o jsonpath='{.data.reason}' 2>/dev/null || echo "(no reason set)")
                  slack "version-check HALTED by kill-switch: $reason"
                  echo "HALTED. Resume: kubectl -n k8s-upgrade delete cm k8s-upgrade-killswitch"
                  exit 0
                fi

                # 1. Detect running version — use the OLDEST kubelet across
                # all nodes so partial chains (e.g. master upgraded but
                # workers still pending) don't trick the chain into
                # thinking the upgrade is complete. Was `.items[0]` (master
                # only) which made the chain skip when workers were behind.
                # Fixed 2026-05-23 after node4-only chain failure.
                RUNNING=$(/usr/local/bin/kubectl get nodes \
                  -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' \
                  | tr -d v | sort -V | head -1)
                RUNNING_MINOR=$(echo "$RUNNING" | awk -F. '{print $1"."$2}')
                echo "Running version (oldest kubelet): v$RUNNING (minor $RUNNING_MINOR)"

                # 2. Latest patch within current minor (refresh master's apt cache)
                LATEST_PATCH=$($SSH wizard@k8s-master.viktorbarzin.lan \
                  "sudo apt-get update -qq -o Dir::Etc::sourcelist='sources.list.d/kubernetes.list' -o Dir::Etc::sourceparts='-' -o APT::Get::List-Cleanup='0' >/dev/null 2>&1 ; \
                   apt-cache madison kubeadm 2>/dev/null \
                    | awk '{print \$3}' \
                    | sed 's/-.*//' \
                    | grep '^$RUNNING_MINOR\\.' \
                    | sort -V | tail -1" || echo "")
                echo "Latest patch: v$LATEST_PATCH"

                # 3. Next-minor probe
                NEXT_MINOR_NUM=$(( $(echo "$RUNNING_MINOR" | cut -d. -f2) + 1 ))
                NEXT_MINOR="1.$NEXT_MINOR_NUM"
                NEXT_MINOR_AVAILABLE="no"
                if curl -sIo /dev/null -w '%%{http_code}' \
                    "https://pkgs.k8s.io/core:/stable:/v$NEXT_MINOR/deb/Release" \
                    | grep -q '^200$'; then
                  NEXT_MINOR_AVAILABLE="yes"
                fi
                echo "Next minor v$NEXT_MINOR available: $NEXT_MINOR_AVAILABLE"

                # 4. Choose target
                TARGET=""
                KIND=""
                if [ -n "$LATEST_PATCH" ] && [ "$LATEST_PATCH" != "$RUNNING" ]; then
                  TARGET="$LATEST_PATCH"
                  KIND="patch"
                elif [ "$NEXT_MINOR_AVAILABLE" = "yes" ]; then
                  NEXT_MINOR_PATCH=$($SSH wizard@k8s-master.viktorbarzin.lan \
                    "curl -sf 'https://pkgs.k8s.io/core:/stable:/v$NEXT_MINOR/deb/Packages' \
                      | grep -oE 'Version: [0-9.-]+' \
                      | awk '{print \$2}' | sed 's/-.*//' \
                      | sort -V | tail -1" || echo "")
                  if [ -n "$NEXT_MINOR_PATCH" ]; then
                    TARGET="$NEXT_MINOR_PATCH"
                    KIND="minor"
                  fi
                fi

                # 5. Pushgateway discovery metric
                PG='http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/k8s-version-check'
                {
                  echo "# TYPE k8s_upgrade_available gauge"
                  if [ -n "$TARGET" ]; then
                    echo "k8s_upgrade_available{kind=\"$KIND\",running=\"$RUNNING\",target=\"$TARGET\"} 1"
                  else
                    echo "k8s_upgrade_available{kind=\"none\",running=\"$RUNNING\",target=\"$RUNNING\"} 0"
                  fi
                  echo "# TYPE k8s_version_check_last_run_timestamp gauge"
                  echo "k8s_version_check_last_run_timestamp $(date +%s)"
                } | curl -sS --data-binary @- "$PG" || echo "warn: pushgateway push failed"

                # 6. Decide whether to spawn Job 0
                if [ -z "$TARGET" ]; then
                  echo "No upgrade needed"
                  exit 0
                fi

                slack "K8s upgrade available: v$RUNNING → v$TARGET ($KIND)"

                if [ "$DRY_RUN" = "true" ]; then
                  slack "DRY_RUN — not spawning preflight Job"
                  exit 0
                fi

                # 7. Spawn Job 0 (preflight) via envsubst on the job-template
                #    Idempotency: deterministic name reconciles via `apply`.
                JOB_NAME="k8s-upgrade-preflight-$${TARGET//./-}"

                # Retry-on-failure idempotency: skip only if an existing preflight
                # Job is Active/Complete. A *Failed* preflight (aborted on a
                # transient gate, e.g. a spurious critical alert) is deleted and
                # re-spawned — otherwise its deterministic name + 7d TTL wedges
                # the entire pipeline until it ages out. (Stuck-pipeline fix
                # 2026-06-17: a transient critical alert wedged 1.34.9 for 5 days.)
                if /usr/local/bin/kubectl -n k8s-upgrade get job "$JOB_NAME" >/dev/null 2>&1; then
                  JOB_FAILED=$(/usr/local/bin/kubectl -n k8s-upgrade get job "$JOB_NAME" \
                    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
                  if [ "$JOB_FAILED" = "True" ]; then
                    slack "Preflight Job $JOB_NAME exists but FAILED — deleting and re-spawning"
                    /usr/local/bin/kubectl -n k8s-upgrade delete job "$JOB_NAME" --wait=true >/dev/null 2>&1 || true
                  else
                    slack "Preflight Job $JOB_NAME already exists (active/complete) — skipping"
                    exit 0
                  fi
                fi

                export JOB_NAME PHASE_NEXT=preflight TARGET_NODE_NEXT="" \
                       TARGET_VERSION="$TARGET" TARGET_VERSION_LABEL="$${TARGET//./-}" \
                       KIND="$KIND" IMAGE="$${IMAGE}" \
                       SCHEDULING_BLOCK=$'      nodeSelector:\n        kubernetes.io/hostname: k8s-node1'

                python3 -c 'import os,sys;sys.stdout.write(os.path.expandvars(sys.stdin.read()))' \
                  < /template/job-template.yaml \
                  | /usr/local/bin/kubectl apply -f -

                slack "Spawned $JOB_NAME (target=v$TARGET kind=$KIND)"
              EOT
              ]
              env {
                name  = "DRY_RUN"
                value = tostring(var.detection_dry_run)
              }
              env {
                name  = "IMAGE"
                value = local.image
              }
              env {
                name  = "HOME"
                value = "/tmp"
              }
              volume_mount {
                name       = "creds"
                mount_path = "/secrets/k8s-upgrade"
                read_only  = true
              }
              volume_mount {
                name       = "template"
                mount_path = "/template"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
                }
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

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z

# CI retrigger 2026-06-17 — apply D1 retry-on-failure. The two-commit landing
# of fb638cd8 left the changed-stack detection diffing against HEAD~1 (commit 2,
# monitoring-only), so this stack's changes (commit 1) were never applied; a
# fresh single commit guarantees the diff includes stacks/k8s-version-upgrade.
