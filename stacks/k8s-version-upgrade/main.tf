# k8s-version-upgrade — Automated K8s component (kubeadm/kubelet/kubectl) upgrade
#
# Detects new patch/minor versions via a weekly CronJob, then dispatches the
# `k8s-version-upgrade` agent (infra/.claude/agents/k8s-version-upgrade.md)
# through claude-agent-service for the actual rolling upgrade.
#
# Reuse points:
#   - claude-agent-service.claude-agent.svc:8080 — agent job runner
#   - Vault secret/k8s-upgrade/* — operator populates ssh_key + slack_webhook
#   - Prometheus + Pushgateway + Upgrade Gates alert group (in monitoring stack)
#   - update_k8s.sh — library script the agent shells into nodes with
#
# Notes:
#   - Schedule is Sun 12:00 UTC — well outside the kured Mon-Fri 02:00-06:00
#     London window so OS reboots and K8s version rollouts can't overlap.
#   - Patch detection uses `apt-cache madison kubeadm` on master via SSH.
#     Minor detection probes the next-minor apt repo URL with HEAD.

variable "schedule" {
  type    = string
  default = "0 12 * * 0" # Sunday 12:00 UTC
}

# Toggle to suspend the detection CronJob without dropping the stack.
variable "enabled" {
  type    = bool
  default = true
}

# Mirrors `local.image_tag` in stacks/claude-agent-service/main.tf — keep in
# sync when the claude-agent-service image is rebuilt. Reused here because the
# detection CronJob only needs kubectl, ssh-client, curl, jq — all of which
# the claude-agent-service image already ships.
variable "claude_agent_service_image_tag" {
  type    = string
  default = "2fd7670d"
}

# If true, the CronJob runs the detection sequence but does NOT POST to
# claude-agent-service. Used for Test 1 to confirm detection works without
# firing a real upgrade.
variable "detection_dry_run" {
  type    = bool
  default = false
}

locals {
  namespace = "k8s-upgrade"
  ca_image  = "forgejo.viktorbarzin.me/viktor/claude-agent-service:${var.claude_agent_service_image_tag}"
  labels = {
    app = "k8s-version-check"
  }
}

# --- Namespace ---

resource "kubernetes_namespace" "k8s_upgrade" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- ExternalSecret: ssh_key + slack_webhook + agent-service bearer ---
#
# Operator populates Vault `secret/k8s-upgrade/` with:
#   - ssh_key         (PEM-encoded ed25519 private key)
#   - ssh_key_pub     (the matching public key — distributed to nodes' authorized_keys)
#   - slack_webhook   (Slack incoming-webhook URL, separate channel from kured for clean alerting)
#
# The claude-agent-service bearer token comes from secret/claude-agent-service
# (reused — no parallel token needed).

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
        {
          secretKey = "api_bearer_token"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
      ]
    }
  }
}

# --- ServiceAccount + RBAC for the detection CronJob ---

resource "kubernetes_service_account" "k8s_version_check" {
  metadata {
    name      = "k8s-version-check"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
}

# Cluster-wide read on nodes (for kubeletVersion comparison)
resource "kubernetes_cluster_role" "k8s_version_check" {
  metadata {
    name = "k8s-version-check"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "k8s_version_check" {
  metadata {
    name = "k8s-version-check"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.k8s_version_check.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.k8s_version_check.metadata[0].name
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
}

# Namespace-scoped: detection CronJob reads its own creds Secret.
resource "kubernetes_role" "k8s_version_check_secrets" {
  metadata {
    name      = "k8s-version-check-secrets"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["k8s-upgrade-creds"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding" "k8s_version_check_secrets" {
  metadata {
    name      = "k8s-version-check-secrets"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.k8s_version_check_secrets.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.k8s_version_check.metadata[0].name
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
}

# --- Cross-namespace RBAC: claude-agent SA reads k8s-upgrade-creds + annotates ns ---
#
# The k8s-version-upgrade agent runs inside the claude-agent-service pod (SA
# `claude-agent` in `claude-agent` ns). It needs:
#   - GET on this namespace's k8s-upgrade-creds Secret (to fetch ssh_key + slack)
#   - PATCH on the k8s-upgrade Namespace annotations (in-flight marker)

resource "kubernetes_role" "claude_agent_reads_creds" {
  metadata {
    name      = "claude-agent-reads-creds"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["k8s-upgrade-creds"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding" "claude_agent_reads_creds" {
  metadata {
    name      = "claude-agent-reads-creds"
    namespace = kubernetes_namespace.k8s_upgrade.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.claude_agent_reads_creds.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "claude-agent"
    namespace = "claude-agent"
  }
}

# The base claude-agent ClusterRole grants get/list/watch on most resources
# but not the mutating verbs the upgrade agent needs. Rather than fork the
# upstream stack, we add a sibling ClusterRole here scoped to exactly the
# verbs+resources required:
#   - patch on namespace k8s-upgrade (in-flight annotation)
#   - create on batch/jobs (trigger etcd snapshot Job from cronjob/backup-etcd)
#   - patch on nodes (cordon/uncordon — drain needs this)
#   - create on pods/eviction (drain evicts pods)
resource "kubernetes_cluster_role" "claude_agent_upgrade_ops" {
  metadata {
    name = "claude-agent-upgrade-ops"
  }
  # Annotate the k8s-upgrade namespace
  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = ["k8s-upgrade"]
    verbs          = ["patch", "update"]
  }
  # Trigger etcd snapshot Jobs (from cronjob/backup-etcd in default ns).
  # Cluster-scoped because we may also create test Jobs in k8s-upgrade ns.
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "delete"]
  }
  # Cordon / uncordon nodes
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["patch", "update"]
  }
  # Drain (evict pods)
  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }
  # Delete pods stuck during drain (sometimes evict isn't enough)
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["delete"]
  }
}

resource "kubernetes_cluster_role_binding" "claude_agent_upgrade_ops" {
  metadata {
    name = "claude-agent-upgrade-ops"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.claude_agent_upgrade_ops.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "claude-agent"
    namespace = "claude-agent"
  }
}

# --- Detection CronJob ---
#
# Weekly: compares running cluster version against latest available patch
# (apt-cache madison kubeadm on master) and latest available minor (HEAD on
# next-minor pkgs.k8s.io repo). When a target is detected, POSTs to
# claude-agent-service to kick the upgrade agent.

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
            service_account_name = kubernetes_service_account.k8s_version_check.metadata[0].name
            restart_policy       = "Never"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "version-check"
              image = local.ca_image
              command = ["/bin/bash", "-c", <<-EOT
                set -euo pipefail
                echo "==> k8s-version-check ($(date -u +%FT%TZ))"

                # 1. Load SSH key from K8s Secret
                mkdir -p /tmp
                /usr/local/bin/kubectl get secret k8s-upgrade-creds \
                  -o jsonpath='{.data.ssh_key}' | base64 -d > /tmp/k8s-upgrade-ssh-key
                chmod 400 /tmp/k8s-upgrade-ssh-key

                SLACK=$(/usr/local/bin/kubectl get secret k8s-upgrade-creds \
                  -o jsonpath='{.data.slack_webhook}' | base64 -d)

                AGENT_TOKEN=$(/usr/local/bin/kubectl get secret k8s-upgrade-creds \
                  -o jsonpath='{.data.api_bearer_token}' | base64 -d)

                SSH="ssh -i /tmp/k8s-upgrade-ssh-key \
                  -o StrictHostKeyChecking=accept-new \
                  -o UserKnownHostsFile=/tmp/known_hosts"

                slack() {
                  curl -sS -X POST -H 'Content-Type: application/json' \
                    --data "$(jq -nc --arg t "[k8s-version-check] $1" '{text: $t}')" \
                    "$SLACK" || true
                }

                # 2. Detect running version
                RUNNING=$(/usr/local/bin/kubectl get nodes \
                  -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' \
                  | tr -d v)
                RUNNING_MINOR=$(echo "$RUNNING" | awk -F. '{print $1"."$2}')
                echo "Running version: v$RUNNING (minor $RUNNING_MINOR)"

                # 3. Detect highest available patch within the running minor track.
                # Refresh the local apt cache first — without this, a newly-published
                # patch won't show up via `apt-cache madison` until something else
                # triggers an `apt-get update`.
                LATEST_PATCH=$($SSH wizard@k8s-master \
                  "sudo apt-get update -qq -o Dir::Etc::sourcelist='sources.list.d/kubernetes.list' -o Dir::Etc::sourceparts='-' -o APT::Get::List-Cleanup='0' >/dev/null 2>&1 ; \
                   apt-cache madison kubeadm 2>/dev/null \
                    | awk '{print \$3}' \
                    | sed 's/-.*//' \
                    | grep '^$RUNNING_MINOR\\.' \
                    | sort -V | tail -1" || echo "")
                echo "Latest patch (apt): v$LATEST_PATCH"

                # 4. Detect next available minor by probing the apt repo URL.
                NEXT_MINOR_NUM=$(( $(echo "$RUNNING_MINOR" | cut -d. -f2) + 1 ))
                NEXT_MINOR="1.$NEXT_MINOR_NUM"
                NEXT_MINOR_AVAILABLE="no"
                if curl -sIo /dev/null -w '%%{http_code}' \
                    "https://pkgs.k8s.io/core:/stable:/v$NEXT_MINOR/deb/Release" \
                    | grep -q '^200$'; then
                  NEXT_MINOR_AVAILABLE="yes"
                fi
                echo "Next minor v$NEXT_MINOR available: $NEXT_MINOR_AVAILABLE"

                # 5. Decide what to do
                TARGET=""
                KIND=""
                if [ -n "$LATEST_PATCH" ] && [ "$LATEST_PATCH" != "$RUNNING" ]; then
                  TARGET="$LATEST_PATCH"
                  KIND="patch"
                elif [ "$NEXT_MINOR_AVAILABLE" = "yes" ]; then
                  # Probe the minor track to get its latest patch.
                  NEXT_MINOR_PATCH=$($SSH wizard@k8s-master \
                    "curl -sf 'https://pkgs.k8s.io/core:/stable:/v$NEXT_MINOR/deb/Packages' \
                      | grep -oE 'Version: [0-9.-]+' \
                      | awk '{print \$2}' | sed 's/-.*//' \
                      | sort -V | tail -1" || echo "")
                  if [ -n "$NEXT_MINOR_PATCH" ]; then
                    TARGET="$NEXT_MINOR_PATCH"
                    KIND="minor"
                  fi
                fi

                # 6. Push the discovery metric to Pushgateway
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

                # 7. Decide whether to dispatch
                if [ -z "$TARGET" ]; then
                  echo "No upgrade needed (running=$RUNNING, latest_patch=$LATEST_PATCH, next_minor_available=$NEXT_MINOR_AVAILABLE)"
                  exit 0
                fi

                slack "K8s upgrade available: v$RUNNING → v$TARGET ($KIND)"

                # DRY_RUN_OVERRIDE wins over DRY_RUN — but a Job copied from
                # this CronJob can't add new env vars (spec is immutable). The
                # operator path for "trigger detection without dispatch" is
                # toggling the CronJob's `var.detection_dry_run` then applying.
                # Documented in the runbook.
                EFFECTIVE_DRY_RUN="$${DRY_RUN_OVERRIDE:-$DRY_RUN}"
                if [ "$EFFECTIVE_DRY_RUN" = "true" ]; then
                  echo "dry_run=true — not POSTing to claude-agent-service"
                  slack "DRY_RUN — skipping agent dispatch"
                  exit 0
                fi

                # 8. POST to claude-agent-service
                PAYLOAD=$(jq -nc \
                  --arg target "$TARGET" \
                  --arg kind "$KIND" \
                  '{
                    prompt: ("Run the k8s-version-upgrade agent. Inputs: " + ({target_version: $target, kind: $kind, dry_run: false, stages: "all"} | tostring)),
                    agent: ".claude/agents/k8s-version-upgrade",
                    max_budget_usd: 30
                  }')

                echo "Dispatching agent: $PAYLOAD"
                RESP=$(curl -sS -w '\n%%{http_code}' -X POST \
                  -H "Authorization: Bearer $AGENT_TOKEN" \
                  -H 'Content-Type: application/json' \
                  -d "$PAYLOAD" \
                  http://claude-agent-service.claude-agent.svc.cluster.local:8080/execute)
                CODE=$(printf '%s' "$RESP" | tail -n1)
                BODY=$(printf '%s' "$RESP" | sed '$d')

                if [ "$CODE" = "200" ] || [ "$CODE" = "202" ]; then
                  JOB_ID=$(printf '%s' "$BODY" | jq -r '.job_id // .id // "unknown"')
                  slack "Agent dispatched: job=$JOB_ID (target=v$TARGET kind=$KIND)"
                  echo "OK — job=$JOB_ID"
                else
                  slack "ERROR dispatching agent: HTTP $CODE — $BODY"
                  echo "dispatch failed: HTTP $CODE — $BODY" >&2
                  exit 1
                fi
              EOT
              ]
              env {
                name  = "DRY_RUN"
                value = tostring(var.detection_dry_run)
              }
              env {
                name  = "HOME"
                value = "/tmp"
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
